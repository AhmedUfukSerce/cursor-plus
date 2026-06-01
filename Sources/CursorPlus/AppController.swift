import AppKit
import Carbon   // IsSecureEventInputEnabled()

/// Speed-class weight presets [verySlow, slow, normal, fast, veryFast].
private let speedPresets: [[Double]] = [
    [5, 4, 2, 1, 0.5],   // 0 Calm
    [2, 3, 4, 2, 1],     // 1 Balanced (default)
    [1, 2, 3, 4, 2],     // 2 Lively
    [0.5, 1, 2, 3, 5]    // 3 Wild
]

/// Wander-interval presets (minSeconds, maxSeconds): how long the cursor roams
/// during an active burst before an (optional) rest.
private let intervalPresets: [(Double, Double)] = [
    (10, 20), (20, 40), (30, 60), (60, 120)
]

/// Central coordinator: owns every subsystem, enforces the permission gate, and
/// exposes the menu actions. Lives for the whole app lifetime.
final class AppController: NSObject, NSApplicationDelegate {

    private let settings = Settings.shared
    private let syntheticLog = SyntheticInputLog()
    private let autoPause = AutoPause()
    private let powerAssertion = PowerAssertion()
    private lazy var inputEngine = InputEngine(log: syntheticLog)
    private lazy var killSwitch = KillSwitch(tripleEscWindow: settings.tripleEscWindowSeconds,
                                             syntheticLog: syntheticLog)
    private lazy var stateMachine = StateMachine(settings: settings, input: inputEngine, autoPause: autoPause)
    private let menu = MenuBarController()
    private lazy var zoneEditor = ClickZoneEditorController(settings: settings)

    private var permissionPoll: Timer?
    private var safetyWatchdog: Timer?

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.install(controller: self)

        killSwitch.onTripleEsc = { [weak self] in self?.turnOff() }
        killSwitch.onRealInput = { [weak self] in self?.autoPause.markActivity() }
        stateMachine.onStateChange = { [weak self] in self?.refreshUI() }
        stateMachine.onActivityPulse = { [weak self] in self?.powerAssertion.declareUserActivity() }
        zoneEditor.onClose = { [weak self] in
            self?.stateMachine.uiHold = false   // resume motion after the editor closes
            self?.refreshUI()
        }

        // Register the cursorplus:// URL handler so PHB (and any other
        // automation tool) can fire `open cursorplus://start` and
        // `open cursorplus://stop` to flip the bot without a menu click.
        // The triple-ESC kill switch and Auto-Pause-on-real-input semantics
        // still gate motion - URL commands cannot bypass those.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // First-run: ask for the grants. Then arm (or poll until granted).
        if !Permissions.allReady {
            Permissions.requestAll()
        }
        armIfPossible()
        if !Permissions.allReady { startPermissionPoll() }

        refreshUI()
    }

    /// Handle a `cursorplus://<command>` URL fired via NSWorkspace / `open`.
    ///
    /// Supported commands:
    ///   - `cursorplus://start`  - turn the bot on (idempotent)
    ///   - `cursorplus://stop`   - turn the bot off (idempotent)
    ///   - `cursorplus://toggle` - flip current state
    ///
    /// Unknown commands are logged and ignored. The triple-ESC kill switch
    /// + Auto-Pause semantics still apply; a URL `start` against a denied
    /// Accessibility grant cannot bypass `Permissions.allReady`.
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "cursorplus" else { return }
        let command = (url.host ?? "").lowercased()
        switch command {
        case "start":
            turnOn()
        case "stop":
            turnOff()
        case "toggle":
            toggleRunning()
        default:
            NSLog("Cursor+: ignoring unknown URL command '\(command)' from \(urlString)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSafetyWatchdog()
        stateMachine.stop()
        killSwitch.stop()
        powerAssertion.end()
    }

    // MARK: - Arming / permissions

    /// Arm the global kill-switch tap as soon as Input Monitoring is granted, so
    /// the stop gesture is live even before the user starts the bot. Returns
    /// whether the kill switch is actually armed afterward.
    @discardableResult
    private func armIfPossible() -> Bool {
        if !killSwitch.isArmed { _ = killSwitch.start() }
        return killSwitch.isArmed
    }

    /// Secure Event Input (password fields, lock window, some terminals) silently
    /// blinds the key tap, so we cannot guarantee the kill switch — treat it as a
    /// reason to freeze motion.
    private var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Can we safely allow motion right now? Only if the kill switch is live and
    /// Secure Input is not blinding it.
    private var safeToRun: Bool { killSwitch.isArmed && !secureInputActive }

    private func startPermissionPoll() {
        permissionPoll?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.armIfPossible()
            self.refreshUI()
            if Permissions.allReady {
                self.permissionPoll?.invalidate()
                self.permissionPoll = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    // MARK: - On/off

    private func turnOn() {
        guard Permissions.allReady else {
            Permissions.requestAll()
            Permissions.openAccessibilitySettings()
            startPermissionPoll()
            refreshUI()
            return
        }
        // HARD precondition: never move the cursor unless the kill switch is armed.
        guard armIfPossible() else {
            refreshUI()   // status will show "kill switch unavailable"
            return
        }
        reconcilePowerAssertion(running: true)
        stateMachine.safetyHold = !safeToRun
        stateMachine.uiHold = zoneEditor.isOpen   // never start frozen by a stale UI hold
        stateMachine.start()
        startSafetyWatchdog()
        refreshUI()
    }

    /// Keep the live display-sleep assertion in sync with the setting + run state.
    private func reconcilePowerAssertion(running: Bool) {
        if running && settings.preventDisplaySleep {
            powerAssertion.begin()
        } else {
            powerAssertion.end()
        }
    }

    private func turnOff() {
        stateMachine.stop()
        stopSafetyWatchdog()
        stateMachine.safetyHold = false
        powerAssertion.end()
        refreshUI()
    }

    /// While running, continuously re-verify the kill switch is live and Secure
    /// Input isn't active; freeze motion (safetyHold) whenever it isn't safe, and
    /// keep trying to re-arm the tap.
    private func startSafetyWatchdog() {
        safetyWatchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.stateMachine.isOn else { return }
            if !self.killSwitch.isArmed { _ = self.killSwitch.start() }
            let hold = !self.safeToRun
            if self.stateMachine.safetyHold != hold {
                self.stateMachine.safetyHold = hold
                self.refreshUI()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyWatchdog = timer
    }

    private func stopSafetyWatchdog() {
        safetyWatchdog?.invalidate()
        safetyWatchdog = nil
    }

    // MARK: - Menu actions

    @objc func toggleRunning() {
        if stateMachine.isOn { turnOff() } else { turnOn() }
    }

    @objc func setSpeedPreset(_ sender: NSMenuItem) {
        let tag = sender.tag
        guard speedPresets.indices.contains(tag) else { return }
        let w = speedPresets[tag]
        settings.setWeight(w[0], for: .verySlow)
        settings.setWeight(w[1], for: .slow)
        settings.setWeight(w[2], for: .normal)
        settings.setWeight(w[3], for: .fast)
        settings.setWeight(w[4], for: .veryFast)
        refreshUI()
    }

    @objc func setIntervalPreset(_ sender: NSMenuItem) {
        let tag = sender.tag
        guard intervalPresets.indices.contains(tag) else { return }
        settings.burstMinSeconds = intervalPresets[tag].0
        settings.burstMaxSeconds = intervalPresets[tag].1
        refreshUI()
    }

    @objc func togglePreventSleep() {
        settings.preventDisplaySleep.toggle()
        reconcilePowerAssertion(running: stateMachine.isOn)
        refreshUI()
    }

    @objc func toggleScrolling() {
        settings.scrollEnabled.toggle()
        refreshUI()
    }

    @objc func toggleIdlePauses() {
        settings.idlePausesEnabled.toggle()
        refreshUI()
    }

    @objc func toggleLongPauses() {
        settings.longPausesEnabled.toggle()
        refreshUI()
    }

    @objc func toggleClickZones() {
        settings.clickZonesEnabled.toggle()
        refreshUI()
    }

    @objc func editClickAreas() {
        stateMachine.uiHold = true   // freeze motion so the bot doesn't fight the user
        refreshUI()
        zoneEditor.open()
    }

    @objc func clearClickAreas() {
        settings.saveClickZones([])
        refreshUI()
    }

    @objc func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc func resetDefaults() {
        setSpeedPreset(menuItem(tag: 1))     // Balanced
        setIntervalPreset(menuItem(tag: 0))  // 10–20s
        settings.preventDisplaySleep = true
        settings.scrollEnabled = true
        settings.idlePausesEnabled = true
        settings.longPausesEnabled = false
        settings.clickZonesEnabled = true
        reconcilePowerAssertion(running: stateMachine.isOn)
        refreshUI()
    }

    @objc func quit() {
        turnOff()
        killSwitch.stop()
        NSApp.terminate(nil)
    }

    private func menuItem(tag: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = tag
        return item
    }

    // MARK: - UI

    private func currentSpeedPresetTag() -> Int {
        let w = settings.speedWeights()
        let current: [Double] = [w[.verySlow] ?? 0, w[.slow] ?? 0, w[.normal] ?? 0, w[.fast] ?? 0, w[.veryFast] ?? 0]
        return speedPresets.firstIndex { preset in
            zip(preset, current).allSatisfy { abs($0 - $1) < 0.0001 }
        } ?? -1
    }

    private func currentIntervalPresetTag() -> Int {
        intervalPresets.firstIndex {
            abs($0.0 - settings.burstMinSeconds) < 0.0001 && abs($0.1 - settings.burstMaxSeconds) < 0.0001
        } ?? -1
    }

    private func refreshUI() {
        let ready = Permissions.allReady
        let armed = killSwitch.isArmed
        let secure = secureInputActive
        let running = stateMachine.isOn
        let paused = stateMachine.isPaused
        let resting = stateMachine.isResting

        let status: String
        if !ready {
            status = "Cursor+: needs permission"
        } else if !armed {
            status = "Cursor+: kill switch unavailable"
        } else if running && secure {
            status = "Cursor+: paused (secure input)"
        } else if running && paused {
            status = "Cursor+: paused (you're active)"
        } else if running && resting {
            status = "Cursor+: ON · resting"
        } else if running {
            status = "Cursor+: ON · keeping active"
        } else {
            status = "Cursor+: off"
        }

        menu.refresh(MenuState(
            statusText: status,
            toggleTitle: running ? "Stop" : "Start",
            running: running,
            paused: paused,
            ready: ready,
            killSwitchArmed: armed,
            preventSleep: settings.preventDisplaySleep,
            scrollEnabled: settings.scrollEnabled,
            idlePausesEnabled: settings.idlePausesEnabled,
            longPausesEnabled: settings.longPausesEnabled,
            clickZonesEnabled: settings.clickZonesEnabled,
            clickZoneCount: settings.loadClickZones().count,
            speedPresetTag: currentSpeedPresetTag(),
            intervalPresetTag: currentIntervalPresetTag()
        ))
    }
}
