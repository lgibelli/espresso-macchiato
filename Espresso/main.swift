import Cocoa
import IOKit.pwr_mgt
import ServiceManagement

// Sparkle auto-update, only in the Developer ID build.
//
//   `!MAS`                → Mac App Store build has `MAS` set as a Swift
//                            compilation condition (see project.pbxproj
//                            ReleaseMAS config). The App Store owns
//                            updates there, so we skip Sparkle entirely.
//   `canImport(Sparkle)`  → lets this file compile cleanly *before* the
//                            Sparkle SPM package is added to the project,
//                            so the repo isn't broken mid-integration.
#if !MAS && canImport(Sparkle)
import Sparkle
#endif

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
    static let watchedAppsKey = "WatchedApps"
    static let preventDisplaySleepKey = "PreventDisplaySleep"
    static let launchAtLoginKey = "LaunchAtLogin"
    static let showTimerInBarKey = "ShowTimerInBar"
    static let brewDurationsKey = "BrewDurations"

    /// Progression of total durations applied when the user clicks the
    /// countdown text next to the icon. The first icon-click activates at
    /// `clickProgression[0]` (30 min); each subsequent click on the
    /// countdown advances to the next entry. Capped at the last entry
    /// (24 h) — further timer clicks are a no-op. A click on the icon
    /// itself toggles the brew off, matching the long-standing behavior.
    static let clickProgression: [Int] = [
        30 * 60,        // 30 min
        60 * 60,        // 1 h
        90 * 60,        // 1 h 30 min
        2  * 3600,      // 2 h
        3  * 3600,      // 3 h
        4  * 3600,      // 4 h
        5  * 3600,      // 5 h
        6  * 3600,      // 6 h
        7  * 3600,      // 7 h
        8  * 3600,      // 8 h
        12 * 3600,      // 12 h
        16 * 3600,      // 16 h
        20 * 3600,      // 20 h
        24 * 3600,      // 24 h (cap)
    ]

    /// Seed values for the right-click "Brew for…" submenu. The live list is
    /// stored in UserDefaults under `brewDurationsKey`, so users can edit
    /// the presets (e.g. `defaults write com.nervoussystems.espressomacchiato
    /// BrewDurations -array-add <seconds>`) without a recompile. `0` means
    /// "indefinite / until I stop it".
    static let defaultBrewDurations: [Int] = [
        300,      // 5 min
        900,      // 15 min
        1800,     // 30 min
        3600,     // 1 hour
        7200,     // 2 hours
        18000,    // 5 hours
        0,        // Until I stop it
    ]

    /// Human label for a brew-duration preset (seconds). `0` → indefinite.
    static func brewDurationLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "Until I stop it" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours) h \(minutes) min"
    }
}

// MARK: - Preferences
class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private init() {
        // Menu-bar countdown is on unless the user has switched it off.
        // register(defaults:) only supplies fallback values — it never
        // writes to disk, so a stored `false` still wins.
        defaults.register(defaults: [Constants.showTimerInBarKey: true])
    }

    var preventDisplaySleep: Bool {
        get { defaults.bool(forKey: Constants.preventDisplaySleepKey) }
        set { defaults.set(newValue, forKey: Constants.preventDisplaySleepKey) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Constants.launchAtLoginKey) }
        set { defaults.set(newValue, forKey: Constants.launchAtLoginKey) }
    }

    var showTimerInBar: Bool {
        get { defaults.bool(forKey: Constants.showTimerInBarKey) }
        set { defaults.set(newValue, forKey: Constants.showTimerInBarKey) }
    }

    /// Configurable right-click "Brew for…" presets. Seeded from
    /// `Constants.defaultBrewDurations` on first read; writing back to this
    /// property persists the user's custom list in UserDefaults.
    var brewDurations: [Int] {
        get {
            if let raw = defaults.array(forKey: Constants.brewDurationsKey) {
                let ints = raw.compactMap { ($0 as? NSNumber)?.intValue }
                if !ints.isEmpty { return ints }
            }
            return Constants.defaultBrewDurations
        }
        set { defaults.set(newValue, forKey: Constants.brewDurationsKey) }
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
                NSLog("IOPMAssertionCreateWithName failed for %@: 0x%@", type, String(result, radix: 16))
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
            // Let the system coalesce wakeups — the menu-bar countdown is
            // minute-granular, so sub-second jitter is invisible.
            countdownTimer?.tolerance = 0.2
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
        // Minute-granular countdown — seconds in a menu-bar timer are just
        // noise and make the bar width jitter every tick. We ceil so the
        // label matches the user's mental model: "29m" means "up to 29
        // minutes left", not "29m 59s".
        let totalMinutes = Int(ceil(Double(remainingSeconds) / 60.0))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
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
        observer = makeObserver(forName: NSWorkspace.didLaunchApplicationNotification) { [weak self] bundleID in
            self?.onWatchedAppLaunched?(bundleID)
        }
        terminateObserver = makeObserver(forName: NSWorkspace.didTerminateApplicationNotification) { [weak self] bundleID in
            self?.onWatchedAppTerminated?(bundleID)
        }
    }

    /// Observe a workspace app-lifecycle notification, invoking `handler`
    /// with the bundle ID only when it belongs to a watched app.
    private func makeObserver(forName name: Notification.Name,
                              handler: @escaping (String) -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  self?.watchedBundleIDs.contains(bundleID) == true else { return }
            handler(bundleID)
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

    /// Index into `Constants.clickProgression` that we're currently on, or
    /// `-1` when the brew wasn't started via icon/timer clicks (e.g. the
    /// user picked a duration from the right-click menu, or an app-watcher
    /// auto-activated). Timer clicks use this to decide the "next" step.
    private var clickStepIndex: Int = -1

    /// Tag for the countdown menu item so the per-second tick can find and
    /// update it without rebuilding the whole menu.
    private static let timerItemTag = 999

    #if !MAS && canImport(Sparkle)
    /// Handles update checks for the Developer ID build. The MAS build
    /// gets updates via the App Store and never instantiates this.
    ///
    /// `startingUpdater: true` wires Sparkle up to the standard scheduled
    /// check cadence (once every 24 h by default) and shows the stock
    /// Cocoa update UI when a new version is available. Feed URL and the
    /// EdDSA public key are read from Info.plist (SUFeedURL /
    /// SUPublicEDKey).
    private lazy var updaterController: SPUStandardUpdaterController =
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - menu bar only
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        buildMenu()
        setupCaffeinateCallbacks()
        setupAppWatcher()

        #if !MAS && canImport(Sparkle)
        // Touching the lazy var instantiates SPUStandardUpdaterController,
        // which (with startingUpdater: true) schedules the periodic check.
        _ = updaterController
        #endif
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
            return
        }

        // Left-click: decide whether the click landed on the icon or on the
        // countdown text. The icon toggles (matches long-standing behavior);
        // the countdown text steps the total duration up through
        // `Constants.clickProgression`, capping at 24 h.
        //
        // When there's no countdown shown — inactive brew, or timer display
        // disabled — every left click is treated as an icon click so the
        // button keeps working end-to-end.
        let showingCountdown = powerManager.isActive && prefs.showTimerInBar
        if !showingCountdown {
            handleIconClick()
            return
        }

        let pointInButton = sender.convert(event.locationInWindow, from: nil)
        let imageFrame = sender.cell?.imageRect(forBounds: sender.bounds) ?? .zero
        // A small slop on the right edge of the image so a click on the
        // trailing pixels of the icon still reads as an icon click.
        let iconRightEdge = imageFrame.maxX + 2
        if pointInButton.x <= iconRightEdge {
            handleIconClick()
        } else {
            handleTimerClick()
        }
    }

    /// Icon-click behavior: classic toggle. First click starts a fresh
    /// 30-minute brew (the first rung of `clickProgression`); the second
    /// click turns the anti-idle off.
    private func handleIconClick() {
        if powerManager.isActive {
            clickStepIndex = -1
            powerManager.deactivate()
            return
        }
        clickStepIndex = 0
        powerManager.activate(
            duration: Constants.clickProgression[0],
            preventDisplaySleep: prefs.preventDisplaySleep
        )
    }

    /// Countdown-click behavior: advance to the next rung of
    /// `clickProgression`. If the brew was started via the right-click menu
    /// or an app watcher (clickStepIndex == -1), find the first rung
    /// strictly greater than the current total and jump to it, so the
    /// click still "adds time" from wherever we happen to be. Capped at
    /// the last rung.
    private func handleTimerClick() {
        guard powerManager.isActive else { return }
        let progression = Constants.clickProgression

        let nextIndex: Int
        if clickStepIndex >= 0 {
            nextIndex = clickStepIndex + 1
        } else {
            // Unknown provenance — pick the first rung above the current total.
            let current = powerManager.totalSeconds
            if current <= 0 {
                // Indefinite brew — start fresh from the first rung.
                nextIndex = 0
            } else if let idx = progression.firstIndex(where: { $0 > current }) {
                nextIndex = idx
            } else {
                // Already at or beyond the last rung — cap.
                return
            }
        }

        if nextIndex >= progression.count {
            // Already at the 24 h cap.
            return
        }

        clickStepIndex = nextIndex
        powerManager.activate(
            duration: progression[nextIndex],
            preventDisplaySleep: prefs.preventDisplaySleep
        )
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        if powerManager.isActive {
            button.image = NSImage(systemSymbolName: Constants.activeIcon, accessibilityDescription: "Active")
            if prefs.showTimerInBar && powerManager.totalSeconds > 0 {
                button.title = " \(powerManager.formattedTimeRemaining)"
            } else if prefs.showTimerInBar && powerManager.totalSeconds == 0 {
                button.title = " ∞"
            } else {
                button.title = ""
            }
        } else {
            button.image = NSImage(systemSymbolName: Constants.inactiveIcon, accessibilityDescription: "Inactive")
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

        appWatcher.onWatchedAppLaunched = { [weak self] _ in
            guard let self = self, !self.powerManager.isActive else { return }
            self.autoActivateBrew()
        }

        appWatcher.onWatchedAppTerminated = { [weak self] _ in
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
            autoActivateBrew()
        }
    }

    /// Start an indefinite brew on the app watcher's behalf — a watched app
    /// launched, or was already running at startup.
    private func autoActivateBrew() {
        autoActivatedByApp = true
        clickStepIndex = -1
        powerManager.activate(
            duration: 0,
            preventDisplaySleep: prefs.preventDisplaySleep
        )
    }

    // MARK: - Menu
    private func buildMenu() {
        menu = NSMenu()
        buildStatusSection(into: menu)
        menu.addItem(NSMenuItem.separator())
        buildBrewSection(into: menu)
        menu.addItem(NSMenuItem.separator())
        buildAutoBrewSection(into: menu)
        menu.addItem(NSMenuItem.separator())
        buildPreferencesSection(into: menu)
        menu.addItem(NSMenuItem.separator())
        buildFooterSection(into: menu)
    }

    /// Single source for the countdown line — used when the menu is built
    /// and again on every timer tick update.
    private var shotCountdownTitle: String {
        "   Shot ends in \(powerManager.formattedTimeRemaining)"
    }

    /// Bold status header plus the countdown / bottomless-cup line.
    private func buildStatusSection(into menu: NSMenu) {
        let statusLabel = powerManager.isActive
            ? "Espresso — Pulling a shot"
            : "Espresso — Machine is cold"
        let headerItem = NSMenuItem(title: statusLabel, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        headerItem.attributedTitle = NSAttributedString(
            string: statusLabel,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(headerItem)

        if powerManager.isActive && powerManager.totalSeconds > 0 {
            let timerItem = NSMenuItem(title: shotCountdownTitle, action: nil, keyEquivalent: "")
            timerItem.isEnabled = false
            timerItem.tag = Self.timerItemTag
            menu.addItem(timerItem)
        } else if powerManager.isActive && powerManager.totalSeconds == 0 {
            let timerItem = NSMenuItem(title: "   Bottomless cup — running until stopped", action: nil, keyEquivalent: "")
            timerItem.isEnabled = false
            menu.addItem(timerItem)
        }
    }

    /// Start/stop toggle and the "Brew for…" duration presets.
    private func buildBrewSection(into menu: NSMenu) {
        let toggleTitle = powerManager.isActive ? "Stop Brewing" : "Start Brewing"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleAction), keyEquivalent: "b")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // "Brew For..." duration submenu. The list comes from
        // `prefs.brewDurations` — configurable via UserDefaults, not
        // hardcoded — so users can trim/extend the presets without a
        // recompile. `0` means "Until I stop it" (indefinite).
        let durationMenu = NSMenu()
        for seconds in prefs.brewDurations {
            let item = NSMenuItem(
                title: Constants.brewDurationLabel(seconds),
                action: #selector(activateWithDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = seconds
            if powerManager.isActive && powerManager.totalSeconds == seconds {
                item.state = .on
            }
            durationMenu.addItem(item)
        }
        let durationItem = NSMenuItem(title: "Brew for…", action: nil, keyEquivalent: "")
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)
    }

    /// "Auto-brew when an app runs…" submenu: the watched apps (click to
    /// remove) followed by the running apps available to add.
    private func buildAutoBrewSection(into menu: NSMenu) {
        let autoActivateMenu = NSMenu()

        let watchedApps = prefs.watchedApps
        if !watchedApps.isEmpty {
            let headerItem = NSMenuItem(title: "Currently brewing for:", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            autoActivateMenu.addItem(headerItem)

            for bundleID in watchedApps {
                addAppMenuItem(
                    to: autoActivateMenu,
                    title: appNameForBundleID(bundleID) ?? bundleID,
                    bundleID: bundleID,
                    action: #selector(removeWatchedApp(_:)),
                    checked: true
                )
            }
            autoActivateMenu.addItem(NSMenuItem.separator())
        }

        let addLabel = NSMenuItem(title: "Pick an app to auto-brew for:", action: nil, keyEquivalent: "")
        addLabel.isEnabled = false
        autoActivateMenu.addItem(addLabel)

        for appInfo in AppWatcher.runningGUIApps() where !watchedApps.contains(appInfo.bundleID) {
            addAppMenuItem(
                to: autoActivateMenu,
                title: appInfo.name,
                bundleID: appInfo.bundleID,
                action: #selector(addWatchedApp(_:))
            )
        }

        let autoActivateItem = NSMenuItem(title: "Auto-brew when an app runs…", action: nil, keyEquivalent: "")
        autoActivateItem.submenu = autoActivateMenu
        menu.addItem(autoActivateItem)
    }

    /// One indented app entry in the auto-brew submenu.
    private func addAppMenuItem(to menu: NSMenu, title: String, bundleID: String,
                                action: Selector, checked: Bool = false) {
        let item = NSMenuItem(title: "   \(title)", action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = bundleID
        if checked { item.state = .on }
        menu.addItem(item)
    }

    /// Checkbox preferences: display sleep, countdown visibility, login item.
    private func buildPreferencesSection(into menu: NSMenu) {
        let settingsLabel = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        settingsLabel.isEnabled = false
        menu.addItem(settingsLabel)

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
    }

    /// Update check (Developer ID build only), About, and Quit.
    private func buildFooterSection(into menu: NSMenu) {
        #if !MAS && canImport(Sparkle)
        // Manual update check — only meaningful in the Developer ID build.
        // The MAS build gets updates through the App Store.
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)
        #endif

        let aboutItem = NSMenuItem(title: "About \(Constants.appName)…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit \(Constants.appName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func updateTimerMenuItem() {
        guard let item = menu.item(withTag: Self.timerItemTag) else { return }
        item.title = shotCountdownTitle
    }

    // MARK: - Actions
    @objc private func toggleAction() {
        // Menu "Start / Stop Brewing" — an explicit, duration-less toggle.
        // The icon click covers the timed 30-min one-tap case; this menu
        // entry is for users who just want an open-ended brew.
        clickStepIndex = -1
        powerManager.toggle(
            duration: 0,
            preventDisplaySleep: prefs.preventDisplaySleep
        )
    }

    @objc private func activateWithDuration(_ sender: NSMenuItem) {
        // "Brew for…" submenu picked a specific duration. This did not
        // come from the click-progression path, so blank out the step
        // index — if the user later clicks the countdown, we'll find the
        // next rung above the picked duration instead of blindly advancing.
        clickStepIndex = -1
        let duration = sender.tag
        powerManager.activate(
            duration: duration,
            preventDisplaySleep: prefs.preventDisplaySleep
        )
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
            // Mirror the at-launch check: if the newly watched app is
            // already running, start the auto-brew now rather than waiting
            // for a relaunch.
            let appIsRunning = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == bundleID }
            if !powerManager.isActive && appIsRunning {
                autoActivateBrew()
            }
        }
        buildMenu()
    }

    @objc private func removeWatchedApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var apps = prefs.watchedApps
        apps.removeAll { $0 == bundleID }
        prefs.watchedApps = apps
        appWatcher.updateWatchedApps(apps)
        // If this removal orphaned an auto-started brew (no watched app
        // running anymore), stop it — the terminate observer could no
        // longer match the app that triggered it.
        if autoActivatedByApp && !appWatcher.isAnyWatchedAppRunning() {
            autoActivatedByApp = false
            powerManager.deactivate()
        }
        buildMenu()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(Constants.appName)"
        alert.informativeText = """
            "Life is like spaghetti, it's hard until you make it"
            (Tommy Cash)

            A tiny menu-bar barista that keeps your Mac from dozing off.

            • Left-click the icon to start (30 min) or stop brewing
            • Click the countdown to add time (up to 24 h)
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
        let symbol = NSImage(systemSymbolName: Constants.activeIcon,
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
                NSLog("Failed to set launch at login: %@", String(describing: error))
            }
        } else {
            // For older macOS, use a LaunchAgent plist. Label and executable
            // path come from the running bundle so they can't drift from
            // Info.plist / the build settings.
            let label = Bundle.main.bundleIdentifier ?? "com.nervoussystems.espressomacchiato"
            let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
            let plistPath = launchAgentDir
                .appendingPathComponent("\(label).plist")

            do {
                if enabled {
                    guard let executablePath = Bundle.main.executablePath else {
                        NSLog("Failed to install launch agent: no executable path")
                        return
                    }
                    let plist: [String: Any] = [
                        "Label": label,
                        "ProgramArguments": [executablePath],
                        "RunAtLoad": true,
                    ]
                    let data = try PropertyListSerialization.data(
                        fromPropertyList: plist, format: .xml, options: 0
                    )
                    try FileManager.default.createDirectory(
                        at: launchAgentDir, withIntermediateDirectories: true
                    )
                    try data.write(to: plistPath)
                } else if FileManager.default.fileExists(atPath: plistPath.path) {
                    try FileManager.default.removeItem(at: plistPath)
                }
            } catch {
                NSLog("Failed to update launch agent: %@", String(describing: error))
            }
        }
    }
}
