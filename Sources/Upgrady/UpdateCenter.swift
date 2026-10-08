import AppKit
import UserNotifications
import UpgradyCore

/// The state of an update or adoption in progress.
enum OperationState: Equatable {
    case queued
    case preparing
    case downloading(Double)
    case installing
    case failed(String)
}

/// Keeps the list of apps, runs checks and performs updates.
@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    @Published private(set) var statuses: [AppStatus] = []
    @Published private(set) var adoptionCandidates: [AdoptionCandidate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var operations: [URL: OperationState] = [:]
    @Published private(set) var adoptions: [String: OperationState] = [:]
    @Published private(set) var brewLog = ""
    /// Set when brew failed because macOS blocked it from changing an app.
    @Published var needsAppManagementPermission = false

    private let preferences = Preferences.shared
    private var sparkleUpdates: [URL: SparkleUpdate] = [:]
    private var queue: [AppStatus] = []
    private var running = 0
    private let maximumParallelUpdates = 2
    private var scheduleTimer: Timer?
    private lazy var folderWatcher = FolderWatcher { [weak self] in
        Task { @MainActor in await self?.appsChanged() }
    }
    private var passwordPrompt: URL?

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Upgrady")
    }

    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Upgrady")
    }

    // MARK: - Lists

    /// Apps with an update the user wants to see.
    var updates: [AppStatus] {
        statuses.filter { status in
            status.updateAvailable && !isIgnored(status) && !isSkipped(status)
        }
    }

    var adoptable: [AdoptionCandidate] {
        guard preferences.homebrewEnabled, preferences.suggestAdoption else { return [] }
        return adoptionCandidates.filter { !preferences.dismissedAdoptions.contains($0.cask.qualifiedName) }
    }

    func isIgnored(_ status: AppStatus) -> Bool {
        preferences.ignoredApps.contains(status.app.bundleIdentifier)
    }

    func isSkipped(_ status: AppStatus) -> Bool {
        guard let available = status.available?.description else { return false }
        return preferences.skippedVersions[status.app.bundleIdentifier] == available
    }

    /// Whether Upgrady can install the update itself.
    func canUpdateInApp(_ status: AppStatus) -> Bool {
        switch status.source {
        case .homebrew, .sparkle: true
        default: false
        }
    }

    // MARK: - Checking

    /// Checks all apps. Manual and scheduled checks first refresh Homebrew (`brew update`).
    func check(refreshingHomebrew: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let homebrew = preferences.homebrew
        if refreshingHomebrew, let homebrew {
            _ = await runner(for: homebrew).run(["update"])
        }

        var folders = AppScanner.defaultFolders + preferences.extraFolders
        folders = folders.reduce(into: []) { result, folder in if !result.contains(folder) { result.append(folder) } }
        folderWatcher.watch(folders)
        let checker = UpdateChecker(options: preferences.checkOptions, folders: folders,
                                    excludedIdentifiers: [Bundle.main.bundleIdentifier ?? ""],
                                    cacheDirectory: cacheDirectory, homebrew: homebrew)
        let result = await checker.run()
        let previous = Set(updates.map(notificationKey))
        statuses = result.statuses
        adoptionCandidates = result.adoptionCandidates
        lastCheck = result.date
        UserDefaults.standard.set(result.date, forKey: "lastCheck")
        notifyAboutNewUpdates(previous: previous)
    }

    /// Runs scheduled checks according to Settings. Also checks at launch.
    func startSchedule() {
        lastCheck = UserDefaults.standard.object(forKey: "lastCheck") as? Date
        scheduleTimer?.invalidate()
        // A short timer survives sleep better than one long timer.
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await UpdateCenter.shared.checkIfDue() }
        }
        Task { await check() }
    }

    /// Apps were installed, updated or removed: refresh the list (without `brew update`).
    private func appsChanged() async {
        // During updates the list is refreshed when they are done.
        guard !isChecking, operations.isEmpty, adoptions.isEmpty else { return }
        await check(refreshingHomebrew: false)
    }

    private func checkIfDue() async {
        let interval = TimeInterval(preferences.checkInterval.rawValue)
        guard interval > 0, !isChecking, operations.isEmpty else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < interval { return }
        await check()
    }

    // MARK: - Updating

    func update(_ status: AppStatus) {
        switch status.source {
        case .appStore:
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
        case .homebrew, .sparkle:
            guard operations[status.id] == nil else { return }
            operations[status.id] = .queued
            queue.append(status)
            startNext()
        case .homebrewAvailable, .none:
            NSWorkspace.shared.openApplication(at: status.app.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func updateAll() {
        updates.filter(canUpdateInApp).forEach(update)
    }

    func cancel(_ status: AppStatus) {
        if let index = queue.firstIndex(where: { $0.id == status.id }) {
            queue.remove(at: index)
            operations[status.id] = nil
        }
        sparkleUpdates[status.id]?.cancel()
    }

    func clearFailure(_ status: AppStatus) {
        if case .failed = operations[status.id] { operations[status.id] = nil }
    }

    private func startNext() {
        while running < maximumParallelUpdates, !queue.isEmpty {
            let status = queue.removeFirst()
            running += 1
            Task {
                let failure = await perform(status)
                running -= 1
                if let failure {
                    operations[status.id] = .failed(failure)
                } else {
                    operations[status.id] = nil
                }
                startNext()
                if queue.isEmpty && running == 0 {
                    await check(refreshingHomebrew: false)
                }
            }
        }
    }

    /// Performs one update. Returns an error message, or nil on success.
    private func perform(_ status: AppStatus) async -> String? {
        operations[status.id] = .preparing
        switch status.source {
        case .sparkle(let feed):
            return await withCheckedContinuation { continuation in
                let update = SparkleUpdate(app: status.app, feed: feed) { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .preparing: self.operations[status.id] = .preparing
                    case .downloading(let fraction): self.operations[status.id] = .downloading(fraction)
                    case .installing: self.operations[status.id] = .installing
                    case .finished:
                        self.sparkleUpdates[status.id] = nil
                        continuation.resume(returning: nil)
                    case .failed(let message):
                        self.sparkleUpdates[status.id] = nil
                        continuation.resume(returning: message)
                    }
                }
                sparkleUpdates[status.id] = update
                update.start()
            }
        case .homebrew(let name):
            guard let homebrew = preferences.homebrew else { return String(localized: "Homebrew was not found.") }
            let runner = runner(for: homebrew)
            let wasRunning = quitRunningApp(status.app)
            let progress = status.cask.map { cask in
                CaskDownloadProgress(runner: runner, cask: cask) { fraction in
                    Task { @MainActor in
                        UpdateCenter.shared.operations[status.id] = fraction >= 1 ? .installing : .downloading(fraction)
                    }
                }
            }
            progress?.start()
            let output = await runner.run(["upgrade", "--cask", name]) { [weak self] text in
                Task { @MainActor in self?.brewLog += text }
            }
            progress?.stop()
            if wasRunning {
                NSWorkspace.shared.openApplication(at: status.app.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            return failureMessage(for: output)
        default:
            return nil
        }
    }

    private func failureMessage(for output: BrewRunner.Output) -> String? {
        guard !output.succeeded else { return nil }
        if output.lacksAppManagementPermission {
            needsAppManagementPermission = true
            return String(localized: "macOS did not allow Homebrew to change the app. Allow Upgrady in Privacy & Security → App Management.")
        }
        let lines = output.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors = lines.filter { $0.hasPrefix("Error") }
        let summary = (errors.isEmpty ? Array(lines.suffix(2)) : Array(errors.suffix(2))).joined(separator: "\n")
        return summary.nilIfEmptyString ?? String(localized: "Homebrew could not complete the operation.")
    }

    /// Quits the app before brew replaces it. Returns whether it was running.
    private func quitRunningApp(_ app: InstalledApp) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
        guard !running.isEmpty else { return false }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    // MARK: - Ignoring and skipping

    func setIgnored(_ ignored: Bool, _ status: AppStatus) {
        var apps = preferences.ignoredApps
        if ignored { apps.insert(status.app.bundleIdentifier) } else { apps.remove(status.app.bundleIdentifier) }
        preferences.ignoredApps = apps
        objectWillChange.send()
    }

    func skipVersion(_ status: AppStatus) {
        guard let available = status.available?.description else { return }
        preferences.skippedVersions[status.app.bundleIdentifier] = available
        objectWillChange.send()
    }

    // MARK: - Homebrew adoption

    /// Links apps to Homebrew. `reinstall` replaces the installed copy instead of adopting it.
    func adopt(_ candidates: [AdoptionCandidate], reinstall: Bool) async {
        guard let homebrew = preferences.homebrew else { return }
        let runner = runner(for: homebrew)
        candidates.forEach { adoptions[$0.id] = .queued }
        for candidate in candidates {
            if candidate.needsTrust {
                brewLog += "$ brew trust --cask \(candidate.cask.qualifiedName)\n"
                _ = await runner.run(["trust", "--cask", candidate.cask.qualifiedName])
            }
            adoptions[candidate.id] = .preparing
            let arguments = ["install", "--cask", reinstall ? "--force" : "--adopt", candidate.cask.qualifiedName]
            brewLog += "$ brew \(arguments.joined(separator: " "))\n"
            let progress = CaskDownloadProgress(runner: runner, cask: candidate.cask) { fraction in
                Task { @MainActor in
                    UpdateCenter.shared.adoptions[candidate.id] = fraction >= 1 ? .installing : .downloading(fraction)
                }
            }
            progress.start()
            let output = await runner.run(arguments) { [weak self] text in
                Task { @MainActor in self?.brewLog += text }
            }
            progress.stop()
            adoptions[candidate.id] = output.succeeded ? nil : .failed(failureMessage(for: output) ?? "")
        }
        await check(refreshingHomebrew: false)
    }

    func dismissAdoption(_ candidate: AdoptionCandidate) {
        preferences.dismissedAdoptions.insert(candidate.cask.qualifiedName)
        objectWillChange.send()
    }

    // MARK: - Helpers

    private func runner(for homebrew: HomebrewInstallation) -> BrewRunner {
        if passwordPrompt == nil {
            passwordPrompt = BrewRunner.installPasswordPrompt(
                in: supportDirectory,
                message: String(localized: "Homebrew needs your administrator password to continue."))
        }
        return BrewRunner(installation: homebrew, passwordPromptScript: passwordPrompt)
    }

    private func notificationKey(_ status: AppStatus) -> String {
        "\(status.app.bundleIdentifier) \(status.available?.description ?? "")"
    }

    private func notifyAboutNewUpdates(previous: Set<String>) {
        guard preferences.notifyAboutUpdates else { return }
        let notified = Set(UserDefaults.standard.stringArray(forKey: "notifiedUpdates") ?? [])
        let current = updates
        let fresh = current.filter { !previous.contains(notificationKey($0)) && !notified.contains(notificationKey($0)) }
        UserDefaults.standard.set(current.map(notificationKey), forKey: "notifiedUpdates")
        guard !fresh.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(current.count) updates available")
        content.body = fresh.prefix(4).map(\.app.name).joined(separator: ", ") + (fresh.count > 4 ? "…" : "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "updates", content: content, trigger: nil))
    }
}

private extension String {
    var nilIfEmptyString: String? { isEmpty ? nil : self }
}
