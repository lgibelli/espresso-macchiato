import Cocoa
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - App Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// MARK: - Constants
struct Constants {
    static let appName = "Espresso"
    static let activeIcon = "cup.and.saucer.fill"
    static let inactiveIcon = "cup.and.saucer"
    static let prefsKey = "EspressoPreferences"
    static let watchedAppsKey = "WatchedApps"
    static let preventDisplaySleepKey = "PreventDisplaySleep"
    static let launchAtLoginKey = "LaunchAtLogin"
    static let showTimerInBarKey = "ShowTimerInBar"
    static let defaultDurationKey = "DefaultDuration"
}

// MARK: - Duration Presets
enum Duration: Int, CaseIterable {
    case minutes5 = 300
    case minutes15 = 900
    case minutes30 = 1800
    case hour1 = 3600
    case hours2 = 7200
    case hours5 = 18000
    case indefinite = 0

    var label: String {
        switch self {
        case .minutes5:    return "5 min"
        case .minutes15:   return "15 min"
        case .minutes30:   return "30 min"
        case .hour1:       return "1 hour"
        case .hours2:      return "2 hours"
        case .hours5:      return "5 hours"
        case .indefinite:  return "Until I stop it"
        }
    }
}

// MARK: - Preferences
class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var preventDisplaySleep: Bool {
        get { defaults.bool(forKey: Constants.preventDisplaySleepKey) }
        set { defaults.set(newValue, forKey: Constants.preventDisplaySleepKey) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Constants.launchAtLoginKey) }
        set { defaults.set(newValue, forKey: Constants.launchAtLoginKey) }
    }

    var showTimerInBar: Bool {
        get {
            if defaults.object(forKey: Constants.showTimerInBarKey) == nil { return true }
            return defaults.bool(forKey: Constants.showTimerInBarKey)
        }
        set { defaults.set(newValue, forKey: Constants.showTimerInBarKey) }
    }

    var defaultDuration: Int {
        get { defaults.integer(forKey: Constants.defaultDurationKey) }
        set { defaults.set(newValue, forKey: Constants.defaultDurationKey) }
    }

    var watchedApps: [String] {
        get { defaults.stringArray(forKey: Constants.watchedAppsKey) ?? [] }
        set { defaults.set(newValue, forKey: Constants.watchedAppsKey) }
    }
}

// MARK: - Power Assertion Manager
//
// Holds IOKit power-management assertions to keep the Mac (and optionally
// the display) awake. This is what /usr/bin/caffeinate does under the hood;
// by talking to IOKit directly we avoid spawning a subprocess at all, which:
//   - works inside the App Sandbox (no `com.apple.security.temporary-exception`
//     hoops, no banned Process launches)
//   - eliminates the old terminationHandler race entirely — there's no
//     child process whose death could race the UI
//   - can't leak an orphan child if the app is killed
class PowerAssertionManager {
    /// Currently-held IOKit assertion IDs. Multiple at a time because we
    /// mirror `caffeinate -is [-d]`: two system-sleep assertions + an
    /// optional display-sleep one.
    private var assertionIDs: [IOPMAssertionID] = []

    private(set) var isActive = false
    private(set) var remainingSeconds: Int = 0
    private(set) var totalSeconds: Int = 0
    private var countdownTimer: Timer?

    var onStateChanged: (() -> Void)?
    var onTimerTick: (() -> Void)?

    func activate(duration: Int = 0, preventDisplaySleep: Bool = false) {
        deactivate()

        // Mirrors `caffeinate -i -s [-d]`:
        //   -i → PreventUserIdleSystemSleep  (keep Mac awake while user idle)
        //   -s → PreventSystemSleep          (prevent deep system sleep on AC)
        //   -d → PreventUserIdleDisplaySleep (keep display on)
        var types: [String] = [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventSystemSleep,
        ]
        if preventDisplaySleep {
            types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep)
        }

        let reason = "Espresso is keeping your Mac awake" as CFString
        var createdIDs: [IOPMAssertionID] = []

        for type in types {
            var id: IOPMAssertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &id
            )
            if result == kIOReturnSuccess {
                createdIDs.append(id)
            } else {
                // Partial failure: roll back any assertions we managed to
                // create so we don't end up in a half-active state.
                for leaked in createdIDs { IOPMAssertionRelease(leaked) }
                print("IOPMAssertionCreateWithName failed for \(type): 0x\(String(result, radix: 16))")
                return
            }
        }

        assertionIDs = createdIDs
        isActive = true
        totalSeconds = duration
        remainingSeconds = duration

        if duration > 0 {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isActive else { return }
                if self.remainingSeconds > 0 {
                    self.remainingSeconds -= 1
                    self.onTimerTick?()
                }
                if self.remainingSeconds <= 0 {
                    // Time's up — release assertions and go idle. Unlike the
                    // old caffeinate path, the release is synchronous so no
                    // async terminationHandler can race the state.
                    self.deactivate()
                }
            }
        }

        onStateChanged?()
    }

    func deactivate() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs = []

        isActive = false
        remainingSeconds = 0
        totalSeconds = 0
        onStateChanged?()
    }

    func toggle(duration: Int = 0, preventDisplaySleep: Bool = false) {
        if isActive {
            deactivate()
        } else {
            activate(duration: duration, preventDisplaySleep: preventDisplaySleep)
        }
    }

    var formattedTimeRemaining: String {
        if !isActive { return "" }
        if totalSeconds == 0 { return "∞" }
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        let seconds = remainingSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    deinit {
        deactivate()
    }
}

// MARK: - App Watcher
class AppWatcher {
    private var observer: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    var onWatchedAppLaunched: ((String) -> Void)?
    var onWatchedAppTerminated: ((String) -> Void)?

    private var watchedBundleIDs: Set<String> = []

    func updateWatchedApps(_ apps: [String]) {
        watchedBundleIDs = Set(apps)
    }

    func startWatching() {
        let workspace = NSWorkspace.shared

        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            if self?.watchedBundleIDs.contains(bundleID) == true {
                self?.onWatchedAppLaunched?(bundleID)
            }
        }

        terminateObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            if self?.watchedBundleIDs.contains(bundleID) == true {
                self?.onWatchedAppTerminated?(bundleID)
            }
        }
    }

    func stopWatching() {
        if let obs = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    /// Check if any watched app is currently running
    func isAnyWatchedAppRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return watchedBundleIDs.contains(bundleID)
        }
    }

    /// Get list of all running GUI apps (for the app picker)
    static func runningGUIApps() -> [(name: String, bundleID: String)] {
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName, let bundleID = app.bundleIdentifier else { return nil }
                return (name: name, bundleID: bundleID)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let powerManager = PowerAssertionManager()
    private let appWatcher = AppWatcher()
    private let prefs = Preferences.shared
    private var autoActivatedByApp = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - menu bar only
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        buildMenu()
        setupCaffeinateCallbacks()
        setupAppWatcher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerManager.deactivate()
        appWatcher.stopWatching()
    }

    // MARK: - Status Item
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusIcon()
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // Right-click: show menu
            buildMenu()
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
            }
        } else {
            // Left-click: toggle with default duration
            let duration = prefs.defaultDuration
            powerManager.toggle(
                duration: duration,
                preventDisplaySleep: prefs.preventDisplaySleep
            )
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        if powerManager.isActive {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: Constants.activeIcon, accessibilityDescription: "Active")
            } else {
                button.title = "☕️"
            }

            if prefs.showTimerInBar && powerManager.totalSeconds > 0 {
                button.title = " \(powerManager.formattedTimeRemaining)"
            } else if prefs.showTimerInBar && powerManager.totalSeconds == 0 {
                button.title = " ∞"
            } else {
                button.title = ""
            }
        } else {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: Constants.inactiveIcon, accessibilityDescription: "Inactive")
            } else {
                button.title = "🫖"
            }
            button.title = ""
        }
    }

    // MARK: - Callbacks
    private func setupCaffeinateCallbacks() {
        powerManager.onStateChanged = { [weak self] in
            self?.updateStatusIcon()
            self?.buildMenu()
        }
        powerManager.onTimerTick = { [weak self] in
            self?.updateStatusIcon()
            self?.updateTimerMenuItem()
        }
    }

    // MARK: - App Watcher
    private func setupAppWatcher() {
        appWatcher.updateWatchedApps(prefs.watchedApps)

        appWatcher.onWatchedAppLaunched = { [weak self] bundleID in
            guard let self = self, !self.powerManager.isActive else { return }
            self.autoActivatedByApp = true
            self.powerManager.activate(
                duration: 0,
                preventDisplaySleep: self.prefs.preventDisplaySleep
            )
        }

        appWatcher.onWatchedAppTerminated = { [weak self] bundleID in
            guard let self = self, self.autoActivatedByApp else { return }
            // Only deactivate if no other watched apps are running
            if !self.appWatcher.isAnyWatchedAppRunning() {
                self.autoActivatedByApp = false
                self.powerManager.deactivate()
            }
        }

        appWatcher.startWatching()

        // Check if any watched app is already running at launch
        if appWatcher.isAnyWatchedAppRunning() {
            autoActivatedByApp = true
            powerManager.activate(
                duration: 0,
                preventDisplaySleep: prefs.preventDisplaySleep
            )
        }
    }

    // MARK: - Menu
    private func buildMenu() {
        menu = NSMenu()

        // Status header
        let statusLabel = powerManager.isActive
            ? "Espresso — Pulling a shot"
            : "Espresso — Machine is cold"
        let statusItem = NSMenuItem(title: statusLabel, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        let font = NSFont.boldSystemFont(ofSize: 13)
        statusItem.attributedTitle = NSAttributedString(
            string: statusLabel,
            attributes: [.font: font]
        )
        menu.addItem(statusItem)

        // Timer remaining (if active with duration)
        if powerManager.isActive && powerManager.totalSeconds > 0 {
            let timerItem = NSMenuItem(
                title: "   Shot ends in \(powerManager.formattedTimeRemaining)",
                action: nil, keyEquivalent: ""
            )
            timerItem.isEnabled = false
            timerItem.tag = 999  // tag for updating
            menu.addItem(timerItem)
        } else if powerManager.isActive && powerManager.totalSeconds == 0 {
            let timerItem = NSMenuItem(title: "   Bottomless cup — running until stopped", action: nil, keyEquivalent: "")
            timerItem.isEnabled = false
            menu.addItem(timerItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Toggle
        let toggleTitle = powerManager.isActive ? "Stop Brewing" : "Start Brewing"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleAction), keyEquivalent: "b")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // "Brew For..." duration submenu
        let durationMenu = NSMenu()
        for d in Duration.allCases {
            let item = NSMenuItem(title: d.label, action: #selector(activateWithDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = d.rawValue
            item.representedObject = d
            if powerManager.isActive && powerManager.totalSeconds == d.rawValue {
                item.state = .on
            }
            durationMenu.addItem(item)
        }
        let durationItem = NSMenuItem(title: "Brew for…", action: nil, keyEquivalent: "")
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

        menu.addItem(NSMenuItem.separator())

        // Wake Triggers (moved up — often-used shortcut)
        let autoActivateMenu = NSMenu()

        let watchedApps = prefs.watchedApps
        if !watchedApps.isEmpty {
            let headerItem = NSMenuItem(title: "Currently brewing for:", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            autoActivateMenu.addItem(headerItem)

            for bundleID in watchedApps {
                let appName = appNameForBundleID(bundleID) ?? bundleID
                let item = NSMenuItem(
                    title: "   \(appName)",
                    action: #selector(removeWatchedApp(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = bundleID
                item.state = .on
                autoActivateMenu.addItem(item)
            }
            autoActivateMenu.addItem(NSMenuItem.separator())
        }

        let addLabel = NSMenuItem(title: "Pick an app to auto-brew for:", action: nil, keyEquivalent: "")
        addLabel.isEnabled = false
        autoActivateMenu.addItem(addLabel)

        let runningApps = AppWatcher.runningGUIApps()
        for appInfo in runningApps {
            if watchedApps.contains(appInfo.bundleID) { continue }
            let item = NSMenuItem(
                title: "   \(appInfo.name)",
                action: #selector(addWatchedApp(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = appInfo.bundleID
            autoActivateMenu.addItem(item)
        }

        let autoActivateItem = NSMenuItem(title: "Auto-brew when an app runs…", action: nil, keyEquivalent: "")
        autoActivateItem.submenu = autoActivateMenu
        menu.addItem(autoActivateItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences section
        let settingsLabel = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        settingsLabel.isEnabled = false
        menu.addItem(settingsLabel)

        // Default duration submenu (a preference — belongs here, not with actions)
        let defaultDurationMenu = NSMenu()
        for d in Duration.allCases {
            let item = NSMenuItem(title: d.label, action: #selector(setDefaultDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = d.rawValue
            if prefs.defaultDuration == d.rawValue {
                item.state = .on
            }
            defaultDurationMenu.addItem(item)
        }
        let defaultDurationItem = NSMenuItem(title: "   One-click shot length…", action: nil, keyEquivalent: "")
        defaultDurationItem.submenu = defaultDurationMenu
        menu.addItem(defaultDurationItem)

        // Prevent display sleep
        let displaySleepItem = NSMenuItem(
            title: "   Keep the screen awake too",
            action: #selector(toggleDisplaySleep(_:)), keyEquivalent: ""
        )
        displaySleepItem.target = self
        displaySleepItem.state = prefs.preventDisplaySleep ? .on : .off
        menu.addItem(displaySleepItem)

        // Show timer in bar
        let showTimerItem = NSMenuItem(
            title: "   Show countdown next to the icon",
            action: #selector(toggleShowTimer(_:)), keyEquivalent: ""
        )
        showTimerItem.target = self
        showTimerItem.state = prefs.showTimerInBar ? .on : .off
        menu.addItem(showTimerItem)

        // Launch at login
        let loginItem = NSMenuItem(
            title: "   Open Espresso at login",
            action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = prefs.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "About \(Constants.appName)…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit \(Constants.appName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func updateTimerMenuItem() {
        guard let item = menu.item(withTag: 999) else { return }
        item.title = "   Shot ends in \(powerManager.formattedTimeRemaining)"
    }

    // MARK: - Actions
    @objc private func toggleAction() {
        powerManager.toggle(
            duration: prefs.defaultDuration,
            preventDisplaySleep: prefs.preventDisplaySleep
        )
    }

    @objc private func activateWithDuration(_ sender: NSMenuItem) {
        let duration = sender.tag
        powerManager.activate(
            duration: duration,
            preventDisplaySleep: prefs.preventDisplaySleep
        )
    }

    @objc private func setDefaultDuration(_ sender: NSMenuItem) {
        prefs.defaultDuration = sender.tag
        buildMenu()
    }

    @objc private func toggleDisplaySleep(_ sender: NSMenuItem) {
        prefs.preventDisplaySleep.toggle()
        // Rebuild assertions if active so the new "prevent display sleep"
        // setting takes effect immediately.
        if powerManager.isActive {
            let remaining = powerManager.remainingSeconds
            let total = powerManager.totalSeconds
            powerManager.deactivate()
            powerManager.activate(
                duration: total > 0 ? remaining : 0,
                preventDisplaySleep: prefs.preventDisplaySleep
            )
        }
        buildMenu()
    }

    @objc private func toggleShowTimer(_ sender: NSMenuItem) {
        prefs.showTimerInBar.toggle()
        updateStatusIcon()
        buildMenu()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        prefs.launchAtLogin.toggle()
        setLaunchAtLogin(prefs.launchAtLogin)
        buildMenu()
    }

    @objc private func addWatchedApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var apps = prefs.watchedApps
        if !apps.contains(bundleID) {
            apps.append(bundleID)
            prefs.watchedApps = apps
            appWatcher.updateWatchedApps(apps)
        }
        buildMenu()
    }

    @objc private func removeWatchedApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var apps = prefs.watchedApps
        apps.removeAll { $0 == bundleID }
        prefs.watchedApps = apps
        appWatcher.updateWatchedApps(apps)
        buildMenu()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(Constants.appName)"
        alert.informativeText = """
            "Life is like spaghetti, it's hard until you make it"
            (Tommy Cash)

            A tiny menu-bar barista that keeps your Mac from dozing off.

            • Left-click the icon to pull a shot
            • Right-click for the full menu

            Under the hood it talks to macOS power management directly
            via IOKit — no subprocess, no magic.

            App by Luca Gibelli
            """
        alert.alertStyle = .informational
        alert.icon = aboutDialogIcon()
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Build a nice big coffee-cup glyph for the About dialog so it doesn't
    /// fall back to the generic "unbundled app" placeholder icon.
    private func aboutDialogIcon() -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
            .applying(.init(paletteColors: [.systemBrown, .white]))
        let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill",
                             accessibilityDescription: "Espresso")?
            .withSymbolConfiguration(config)

        // Render into a fixed-size bitmap so NSAlert resizes predictably.
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        if let symbol = symbol {
            let rect = NSRect(origin: .zero, size: size)
            symbol.draw(in: rect.insetBy(dx: 8, dy: 8),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0)
        }
        return image
    }

    @objc private func quitApp() {
        powerManager.deactivate()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers
    private func appNameForBundleID(_ bundleID: String) -> String? {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at login: \(error)")
            }
        } else {
            // For older macOS, use a LaunchAgent plist
            let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
            let plistPath = launchAgentDir
                .appendingPathComponent("com.nervoussystems.espressomacchiato.plist")

            if enabled {
                guard let appPath = Bundle.main.bundlePath as String? else { return }
                let plist: [String: Any] = [
                    "Label": "com.nervoussystems.espressomacchiato",
                    "ProgramArguments": ["\(appPath)/Contents/MacOS/Espresso"],
                    "RunAtLoad": true,
                ]
                let data = try? PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0
                )
                try? FileManager.default.createDirectory(
                    at: launchAgentDir, withIntermediateDirectories: true
                )
                try? data?.write(to: plistPath)
            } else {
                try? FileManager.default.removeItem(at: plistPath)
            }
        }
    }
}
