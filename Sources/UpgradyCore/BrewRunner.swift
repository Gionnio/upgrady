import Foundation

/// Runs brew commands for a GUI app.
public struct BrewRunner: Sendable {
    public let installation: HomebrewInstallation
    /// A script that asks for the administrator password with a dialog (`sudo -A`).
    public var passwordPromptScript: URL?

    public init(installation: HomebrewInstallation, passwordPromptScript: URL? = nil) {
        self.installation = installation
        self.passwordPromptScript = passwordPromptScript
    }

    public struct Output: Sendable {
        public let status: Int32
        public let text: String
        /// Brew stopped making progress and was stopped by the watchdog.
        public var stalled = false
        public var succeeded: Bool { status == 0 && !stalled }

        /// macOS refused to let brew change an app: the "App Management" permission is missing.
        public var lacksAppManagementPermission: Bool { text.contains("Operation not permitted") }
        /// Homebrew ignores casks from taps that are not trusted.
        public var needsTapTrust: Bool { text.localizedCaseInsensitiveContains("tap trust") && !succeeded }
    }

    /// Runs brew and waits for it. `onOutput` receives output as it arrives.
    ///
    /// With a `watchdog`, brew is stopped when it shows no sign of life (no output, no download progress)
    /// for the watchdog's timeout: a download left hanging, for example after the Mac slept, would otherwise
    /// keep the operation running for hours.
    public func run(_ arguments: [String], includeErrors: Bool = true, watchdog: BrewWatchdog? = nil,
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = installation.brewURL
            process.arguments = arguments
            process.environment = environment()
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = includeErrors ? pipe : FileHandle.nullDevice

            let collected = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                watchdog?.touch()
                collected.append(data)
                onOutput?(String(decoding: data, as: UTF8.self))
            }
            process.terminationHandler = { process in
                watchdog?.stop()
                pipe.fileHandleForReading.readabilityHandler = nil
                // After a stall a leftover child (curl) may still hold the pipe open: do not wait for it.
                let rest = watchdog?.fired == true ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty {
                    collected.append(rest)
                    onOutput?(String(decoding: rest, as: UTF8.self))
                }
                var output = Output(status: process.terminationStatus, text: collected.text)
                output.stalled = watchdog?.fired ?? false
                continuation.resume(returning: output)
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                watchdog?.start {
                    // brew runs the download in child processes: stop them too, then brew itself.
                    Self.signalChildren(of: pid, "TERM")
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                        guard process.isRunning else { return }
                        Self.signalChildren(of: pid, "KILL")
                        kill(pid, SIGKILL)
                    }
                }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Output(status: -1, text: error.localizedDescription))
            }
        }
    }

    /// Sends a signal to the children of a process (and theirs), with `pkill -P`.
    private static func signalChildren(of pid: Int32, _ signal: String) {
        let children = Process()
        children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        children.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        children.standardOutput = pipe
        children.standardError = FileHandle.nullDevice
        guard (try? children.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        children.waitUntilExit()
        for child in String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap({ Int32($0) }) {
            signalChildren(of: child, signal)
            kill(child, signal == "KILL" ? SIGKILL : SIGTERM)
        }
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bin = installation.brewURL.deletingLastPathComponent().path
        environment["PATH"] = ([bin, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["NONINTERACTIVE"] = "1"
        if let passwordPromptScript { environment["SUDO_ASKPASS"] = passwordPromptScript.path }
        return environment
    }

    /// Writes the password prompt script used by `sudo -A` and returns its location.
    public static func installPasswordPrompt(in directory: URL, message: String) -> URL? {
        let safe = message.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\\", with: "")
        let script = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'display dialog "\(safe)" with title "Upgrady" default answer "" with hidden answer with icon caution' -e 'text returned of result'
        """
        let url = directory.appendingPathComponent("password-prompt.sh")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}

/// Stops a brew command that shows no sign of life for `timeout` seconds.
public final class BrewWatchdog: @unchecked Sendable {
    public let timeout: TimeInterval
    private let lock = NSLock()
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private var didFire = false

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Brew is alive: output arrived or the download grew.
    public func touch() { lock.withLock { lastActivity = Date() } }

    /// Whether the command was stopped for inactivity.
    public var fired: Bool { lock.withLock { didFire } }

    func start(onStall: @escaping @Sendable () -> Void) {
        touch()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let tick = min(15, max(timeout / 4, 0.5))
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stalled = self.lock.withLock { () -> Bool in
                guard !self.didFire, Date().timeIntervalSince(self.lastActivity) > self.timeout else { return false }
                self.didFire = true
                return true
            }
            if stalled { onStall() }
        }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

// MARK: - Download progress

/// Follows a cask download while brew runs, by watching the partial file in brew's cache.
public final class CaskDownloadProgress: @unchecked Sendable {
    public typealias Handler = @Sendable (_ fraction: Double) -> Void

    private let runner: BrewRunner
    private let cask: Cask
    private let handler: Handler
    private let watchdog: BrewWatchdog?
    private var task: Task<Void, Never>?

    /// A growing download counts as activity for the `watchdog`.
    public init(runner: BrewRunner, cask: Cask, watchdog: BrewWatchdog? = nil, handler: @escaping Handler) {
        self.runner = runner
        self.cask = cask
        self.watchdog = watchdog
        self.handler = handler
    }

    public func start() {
        task = Task.detached { [runner, cask, handler, watchdog] in
            let cachePath = await runner.run(["--cache", "--cask", cask.qualifiedName], includeErrors: false).text
                .split(separator: "\n").last(where: { $0.hasPrefix("/") }).map(String.init)
            guard let cachePath, let total = await Self.expectedSize(of: cask), total > 0 else { return }
            let partial = cachePath + ".incomplete"
            var lastReported = -1.0
            var lastSize: Int64 = -1
            while !Task.isCancelled {
                if let size = (try? FileManager.default.attributesOfItem(atPath: partial))?[.size] as? NSNumber {
                    if size.int64Value != lastSize {
                        lastSize = size.int64Value
                        watchdog?.touch()
                    }
                    let fraction = min(Double(size.int64Value) / Double(total), 1)
                    if fraction - lastReported >= 0.005 {
                        lastReported = fraction
                        handler(fraction)
                    }
                } else if lastReported >= 0 {
                    handler(1)
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    public func stop() {
        task?.cancel()
    }

    /// The size of the cask download, asked to the server.
    static func expectedSize(of cask: Cask) async -> Int64? {
        guard var address = cask.downloadURL else { return nil }
        if let version = cask.version {
            address = address.replacingOccurrences(of: "#{version}", with: version)
        }
        guard !address.contains("#{"), let url = URL(string: address) else { return nil }
        var head = URLRequest(url: url, timeoutInterval: 15)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head), response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        var range = URLRequest(url: url, timeoutInterval: 15)
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: range),
              let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
              let total = header.split(separator: "/").last.flatMap({ Int64($0) }) else { return nil }
        return total
    }
}
