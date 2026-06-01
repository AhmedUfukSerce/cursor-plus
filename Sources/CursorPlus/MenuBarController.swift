import AppKit

/// Snapshot of everything the menu needs to render.
struct MenuState {
    let statusText: String
    let toggleTitle: String
    let running: Bool
    let paused: Bool
    let ready: Bool
    let killSwitchArmed: Bool
    let preventSleep: Bool
    let scrollEnabled: Bool
    let idlePausesEnabled: Bool
    let longPausesEnabled: Bool
    let clickZonesEnabled: Bool
    let clickZoneCount: Int
    let speedPresetTag: Int      // -1 = custom
    let intervalPresetTag: Int   // -1 = custom
}

/// Owns the menu-bar `NSStatusItem` and its menu. Menu items target the
/// `AppController` (an NSObject) via selectors — the standard AppKit pattern.
final class MenuBarController {

    private var statusItem: NSStatusItem!
    private weak var controller: AppController?

    private var statusLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var preventSleepItem: NSMenuItem!
    private var scrollItem: NSMenuItem!
    private var idlePausesItem: NSMenuItem!
    private var longPausesItem: NSMenuItem!
    private var clickZonesItem: NSMenuItem!
    private var editZonesItem: NSMenuItem!
    private var clearZonesItem: NSMenuItem!
    private var speedItems: [NSMenuItem] = []
    private var intervalItems: [NSMenuItem] = []
    private var stopHintItem: NSMenuItem!

    static let speedPresetNames = ["Calm", "Balanced", "Lively", "Wild"]
    static let intervalPresetNames = ["10–20s", "20–40s", "30–60s", "60–120s"]

    // The most human-like / least-detectable option in each submenu — the one to
    // leave selected the majority of the time. Marked with a ★ in the menu.
    // Balanced = natural speed spread centered on normal; 10–20s = frequent, human
    // burst/pause rhythm (longer bursts move continuously too long to look human).
    private static let recommendedSpeedIndex = 1     // Balanced
    private static let recommendedIntervalIndex = 0  // 10–20s

    private static func label(_ name: String, recommended: Bool) -> String {
        recommended ? "\(name)  ★" : name
    }

    func install(controller: AppController) {
        self.controller = controller

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow",
                                           accessibilityDescription: "Cursor+")

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine = NSMenuItem(title: "Cursor+", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Start",
                                action: #selector(AppController.toggleRunning),
                                keyEquivalent: "")
        toggleItem.target = controller
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Motion speed submenu
        let speedMenu = NSMenu()
        for (i, name) in Self.speedPresetNames.enumerated() {
            let it = NSMenuItem(title: Self.label(name, recommended: i == Self.recommendedSpeedIndex),
                                action: #selector(AppController.setSpeedPreset(_:)),
                                keyEquivalent: "")
            it.tag = i
            it.target = controller
            speedMenu.addItem(it)
            speedItems.append(it)
        }
        let speedParent = NSMenuItem(title: "Motion speed", action: nil, keyEquivalent: "")
        speedParent.submenu = speedMenu
        menu.addItem(speedParent)

        // Wander-interval submenu (how long the cursor roams between rests)
        let intervalMenu = NSMenu()
        for (i, name) in Self.intervalPresetNames.enumerated() {
            let it = NSMenuItem(title: Self.label(name, recommended: i == Self.recommendedIntervalIndex),
                                action: #selector(AppController.setIntervalPreset(_:)),
                                keyEquivalent: "")
            it.tag = i
            it.target = controller
            intervalMenu.addItem(it)
            intervalItems.append(it)
        }
        let intervalParent = NSMenuItem(title: "Wander interval", action: nil, keyEquivalent: "")
        intervalParent.submenu = intervalMenu
        menu.addItem(intervalParent)

        menu.addItem(.separator())

        scrollItem = NSMenuItem(title: "Occasional scrolling",
                                action: #selector(AppController.toggleScrolling),
                                keyEquivalent: "")
        scrollItem.target = controller
        menu.addItem(scrollItem)

        idlePausesItem = NSMenuItem(title: "Human idle pauses",
                                    action: #selector(AppController.toggleIdlePauses),
                                    keyEquivalent: "")
        idlePausesItem.target = controller
        menu.addItem(idlePausesItem)

        longPausesItem = NSMenuItem(title: "Occasional long pauses",
                                    action: #selector(AppController.toggleLongPauses),
                                    keyEquivalent: "")
        longPausesItem.target = controller
        menu.addItem(longPausesItem)

        preventSleepItem = NSMenuItem(title: "Prevent display sleep",
                                      action: #selector(AppController.togglePreventSleep),
                                      keyEquivalent: "")
        preventSleepItem.target = controller
        menu.addItem(preventSleepItem)

        menu.addItem(.separator())

        // Click zones: occasionally click inside user-defined regions.
        clickZonesItem = NSMenuItem(title: "Click defined areas",
                                    action: #selector(AppController.toggleClickZones),
                                    keyEquivalent: "")
        clickZonesItem.target = controller
        menu.addItem(clickZonesItem)

        editZonesItem = NSMenuItem(title: "Edit click areas…",
                                   action: #selector(AppController.editClickAreas),
                                   keyEquivalent: "")
        editZonesItem.target = controller
        menu.addItem(editZonesItem)

        clearZonesItem = NSMenuItem(title: "Clear click areas",
                                    action: #selector(AppController.clearClickAreas),
                                    keyEquivalent: "")
        clearZonesItem.target = controller
        menu.addItem(clearZonesItem)

        menu.addItem(.separator())

        let permItem = NSMenuItem(title: "Open Accessibility Settings…",
                                  action: #selector(AppController.openAccessibilitySettings),
                                  keyEquivalent: "")
        permItem.target = controller
        menu.addItem(permItem)

        let resetItem = NSMenuItem(title: "Reset to defaults",
                                   action: #selector(AppController.resetDefaults),
                                   keyEquivalent: "")
        resetItem.target = controller
        menu.addItem(resetItem)

        menu.addItem(.separator())

        stopHintItem = NSMenuItem(title: "Stop with: Esc Esc Esc", action: nil, keyEquivalent: "")
        stopHintItem.isEnabled = false
        menu.addItem(stopHintItem)

        let quitItem = NSMenuItem(title: "Quit Cursor+",
                                  action: #selector(AppController.quit),
                                  keyEquivalent: "q")
        quitItem.target = controller
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func refresh(_ state: MenuState) {
        statusLine.title = state.statusText
        toggleItem.title = state.toggleTitle
        // Only allow starting when the kill switch is actually live (or to stop).
        toggleItem.isEnabled = state.running || (state.ready && state.killSwitchArmed)

        stopHintItem.title = state.killSwitchArmed
            ? "Stop with: Esc Esc Esc"
            : "Stop gesture INACTIVE — grant Input Monitoring"

        preventSleepItem.state = state.preventSleep ? .on : .off
        scrollItem.state = state.scrollEnabled ? .on : .off
        idlePausesItem.state = state.idlePausesEnabled ? .on : .off
        longPausesItem.state = state.longPausesEnabled ? .on : .off
        clickZonesItem.state = state.clickZonesEnabled ? .on : .off
        clickZonesItem.isEnabled = state.clickZoneCount > 0   // nothing to act on with no zones
        editZonesItem.title = state.clickZoneCount > 0
            ? "Edit click areas (\(state.clickZoneCount))…"
            : "Add a click area…"
        clearZonesItem.isEnabled = state.clickZoneCount > 0

        for (i, item) in speedItems.enumerated() {
            item.state = (i == state.speedPresetTag) ? .on : .off
        }
        for (i, item) in intervalItems.enumerated() {
            item.state = (i == state.intervalPresetTag) ? .on : .off
        }

        let symbol: String
        if !state.ready {
            symbol = "exclamationmark.triangle"
        } else if state.paused {
            symbol = "pause.circle"
        } else if state.running {
            symbol = "cursorarrow.motionlines"
        } else {
            symbol = "cursorarrow"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "Cursor+")
    }
}
