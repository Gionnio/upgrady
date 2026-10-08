import AppKit
import Sparkle
import UpgradyCore

/// Installs the update of an app that uses Sparkle, with the app's own feed and signing keys.
///
/// Upgrady acts as the "user driver": it accepts the update and reports progress instead of showing Sparkle's windows.
@MainActor
final class SparkleUpdate: NSObject {
    enum Event {
        case preparing
        case downloading(Double)
        case installing
        case finished
        case failed(String)
    }

    private let app: InstalledApp
    private let feed: URL?
    private let onEvent: (Event) -> Void
    private var updater: SPUUpdater?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var cancelDownload: (() -> Void)?
    private var isDone = false

    init(app: InstalledApp, feed: URL?, onEvent: @escaping (Event) -> Void) {
        self.app = app
        self.feed = feed
        self.onEvent = onEvent
    }

    func start() {
        guard let bundle = Bundle(url: app.url) else {
            finish(.failed(String(localized: "The app could not be opened.")))
            return
        }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        do {
            try updater.start()
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }
        onEvent(.preparing)
        updater.checkForUpdates()
    }

    func cancel() {
        cancelDownload?()
        finish(.failed(String(localized: "Cancelled")))
    }

    private func finish(_ event: Event) {
        guard !isDone else { return }
        isDone = true
        onEvent(event)
        updater = nil
    }
}

extension SparkleUpdate: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feed?.absoluteString }
    }
}

extension SparkleUpdate: SPUUserDriver {
    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        MainActor.assumeIsolated { finish(.failed(String(localized: "The update is no longer available."))) }
    }

    nonisolated func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        let message = error.localizedDescription
        MainActor.assumeIsolated { finish(.failed(message)) }
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            cancelDownload = cancellation
            onEvent(.downloading(0))
        }
    }

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated {
            expectedLength = expectedContentLength
            receivedLength = 0
        }
    }

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated {
            receivedLength += length
            guard expectedLength > 0 else { return }
            onEvent(.downloading(min(Double(receivedLength) / Double(expectedLength), 1)))
        }
    }

    nonisolated func showDownloadDidStartExtractingUpdate() {
        MainActor.assumeIsolated { onEvent(.installing) }
    }

    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        MainActor.assumeIsolated { onEvent(.installing) }
    }

    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        MainActor.assumeIsolated { finish(.finished) }
    }

    nonisolated func showUpdateInFocus() {}

    nonisolated func dismissUpdateInstallation() {
        // Called at the end of every update cycle; only meaningful if nothing else ended it.
        MainActor.assumeIsolated {
            if !isDone { finish(.finished) }
        }
    }
}
