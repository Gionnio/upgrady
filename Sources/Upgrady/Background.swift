import AppKit
import ServiceManagement

/// Keeps Upgrady running in the menu bar with no windows open.
@MainActor
enum Background {

    /// Turns on launch at login once, the first time Upgrady runs.
    static func enableLaunchAtLoginOnFirstRun() {
        let key = "didEnableLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    // MARK: Dock icon

    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel) && window.className != "NSStatusBarWindow"
    }

    /// The Dock icon is shown while a window is open (or always, if the user prefers).
    static func updateActivationPolicy() {
        let hasWindows = NSApp.windows.contains { $0.isVisible && isAppWindow($0) }
        let preferences = Preferences.shared
        // Without the menu bar icon the Dock icon is the only way to reach Upgrady.
        let wanted: NSApplication.ActivationPolicy = !preferences.showMenuBarIcon || (hasWindows && preferences.showDockIconWithWindow) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// Brings the main window to the front, recreating it if it was closed.
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            // Opening our own bundle sends a "reopen" event, and SwiftUI recreates the main window.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        bringToFront(mainWindow)
    }

    /// Activates Upgrady and fronts `window`. Right after leaving menu-bar-only mode, macOS may ignore
    /// a polite activation request, so it insists for a moment.
    static func bringToFront(_ window: NSWindow? = nil) {
        func front() {
            NSApp.activate(ignoringOtherApps: true)
            let target = window ?? mainWindow ?? NSApp.windows.first { $0.isVisible && isAppWindow($0) }
            guard let target else { return }
            if target.isMiniaturized { target.deminiaturize(nil) }
            target.makeKeyAndOrderFront(nil)
            target.orderFrontRegardless()
        }
        NSApp.setActivationPolicy(.regular)
        front()
        for delay in [0.1, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !NSApp.isActive || !(NSApp.keyWindow.map(isAppWindow) ?? false) else { return }
                front()
            }
        }
    }

    /// Hides the windows SwiftUI opens at launch when Upgrady starts silently at login.
    static func hideLaunchWindows() {
        for window in NSApp.windows where isAppWindow(window) { window.orderOut(nil) }
        updateActivationPolicy()
    }

    // MARK: Quit

    /// Set by the Quit button of the panel, so the next termination request is not intercepted.
    static var quitConfirmed = false

    static func quitCompletely() {
        quitConfirmed = true
        NSApp.terminate(nil)
    }

    /// Closes all windows, like ⌘W, so Upgrady keeps running in the menu bar only.
    static func keepRunningInMenuBar() {
        for window in NSApp.windows where window.isVisible && isAppWindow(window) { window.close() }
        DispatchQueue.main.async { updateActivationPolicy() }
    }

    /// Relaunches Upgrady, e.g. after changing the language.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        quitCompletely()
    }

    // MARK: App Nap

    private static var activity: NSObjectProtocol?

    /// Without this, App Nap would delay scheduled checks while no window is visible.
    static func preventAppNap() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
            reason: "Scheduled update checks")
    }
}

/// Detects whether Upgrady was opened at login.
enum LaunchDetection {
    static var wasLaunchedAtLogin: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Login items start right after the Dock: a launch within two minutes of it counts as login.
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let dockStart = startDate(of: dock.processIdentifier),
              let ownStart = startDate(of: ProcessInfo.processInfo.processIdentifier) else { return false }
        return ownStart.timeIntervalSince(dockStart) < 120
    }

    private static func startDate(of pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
