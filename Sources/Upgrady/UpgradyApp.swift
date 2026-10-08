import AppKit
import SwiftUI
import UserNotifications

struct UpgradyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var center = UpdateCenter.shared
    @StateObject private var preferences = Preferences.shared

    var body: some Scene {
        Window("Upgrady", id: "main") {
            MainView()
                .environmentObject(center)
                .environmentObject(preferences)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                OpenWindowButton(title: "About Upgrady", id: "about")
            }
            CommandGroup(after: .newItem) {
                Button("Check for Updates") { Task { await center.check() } }
                    .keyboardShortcut("r")
                    .disabled(center.isChecking)
                Button("Update All") { center.updateAll() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!center.updates.contains(where: center.canUpdateInApp))
            }
        }

        Window("Link Apps to Homebrew", id: "adoption") {
            AdoptionView()
                .environmentObject(center)
                .environmentObject(preferences)
        }
        .defaultSize(width: 680, height: 480)

        Window("About Upgrady", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(center)
                .environmentObject(preferences)
        }

        MenuBarExtra(isInserted: Binding(
            get: { preferences.showMenuBarIcon },
            set: { if $0 != preferences.showMenuBarIcon { preferences.showMenuBarIcon = $0 } })) {
            MenuBarPanel()
                .environmentObject(center)
                .environmentObject(preferences)
        } label: {
            Image(systemName: center.updates.isEmpty ? "arrow.up.circle" : "arrow.up.circle.fill")
            if !center.updates.isEmpty { Text(verbatim: "\(center.updates.count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

/// A menu command that opens one of the app's windows.
private struct OpenWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: LocalizedStringKey
    let id: String

    var body: some View {
        Button(title) {
            openWindow(id: id)
            Background.bringToFront()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Opened automatically at login: stay in the menu bar without showing the window.
    private lazy var startsSilently = Preferences.shared.showMenuBarIcon && LaunchDetection.wasLaunchedAtLogin

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.shared.applyTheme()
        if startsSilently { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !startsSilently { NSApp.setActivationPolicy(.regular) }
        Background.enableLaunchAtLoginOnFirstRun()
        Background.preventAppNap()

        UNUserNotificationCenter.current().delegate = self
        if Preferences.shared.notifyAboutUpdates {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
        }
        UpdateCenter.shared.startSchedule()

        if startsSilently {
            DispatchQueue.main.async { Background.hideLaunchWindows() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Background.hideLaunchWindows() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { Background.updateActivationPolicy() }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, Background.isAppWindow(window), NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logout, shutdown and other apps quit us via Apple Event: never interfere with those.
        let isUserQuit = NSAppleEventManager.shared().currentAppleEvent == nil
        // Without the menu bar icon there is nothing to keep running in.
        guard isUserQuit, !Background.quitConfirmed, Preferences.shared.showMenuBarIcon else { return .terminateNow }
        switch Preferences.shared.quitBehavior {
        case .quit:
            return .terminateNow
        case .keepInMenuBar:
            Background.keepRunningInMenuBar()
            return .terminateCancel
        case .ask:
            break
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Upgrady?")
        alert.informativeText = String(localized: "Upgrady can stay in the menu bar and keep checking for updates, like when you close its window.")
        alert.addButton(withTitle: String(localized: "Keep in the Menu Bar"))
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Remember my choice")

        let response = alert.runModal()
        let remember = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn:
            if remember { Preferences.shared.quitBehavior = .keepInMenuBar }
            Background.keepRunningInMenuBar()
            return .terminateCancel
        case .alertSecondButtonReturn:
            if remember { Preferences.shared.quitBehavior = .quit }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { Background.showMainWindow() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
