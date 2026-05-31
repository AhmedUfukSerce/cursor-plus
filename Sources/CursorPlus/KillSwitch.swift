import AppKit
import CoreGraphics

/// Escape key's virtual keycode (kVK_Escape).
private let kEscapeKeyCode: Int64 = 53

/// C trampoline — a `CGEventTapCallBack` cannot capture context, so we route
/// through the `userInfo` pointer back to the owning `KillSwitch` instance.
private func killSwitchCallback(proxy: CGEventTapProxy,
                                type: CGEventType,
                                event: CGEvent,
                                userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo = userInfo {
        let ks = Unmanaged<KillSwitch>.fromOpaque(userInfo).takeUnretainedValue()
        ks.handle(type: type, event: event)
    }
    // .listenOnly tap: never consume — always pass the event straight through.
    return Unmanaged.passUnretained(event)
}

/// Owns the single global `CGEventTap` that powers BOTH safety features:
///   • triple-tap ESC within a short window  -> `onTripleEsc`
///   • any real (non-synthetic) user input    -> `onRealInput` (drives auto-pause)
///
/// Robustness layers, because a dead kill switch while the bot moves is the worst
/// possible failure:
///   1. Re-enable inside the callback on `.tapDisabledByTimeout/.ByUserInput`.
///   2. A persistent 2s health timer that re-enables or fully reinstalls the tap,
///      and that is NEVER torn down by a failed reinstall (it keeps retrying).
///   3. A redundant `NSEvent` global keyDown monitor for ESC, so the gesture still
///      works if the CG tap hits the silent-disable race (deduped against the tap).
final class KillSwitch {

    var onTripleEsc: (() -> Void)?
    var onRealInput: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var globalMonitor: Any?

    private var escTimestamps: [TimeInterval] = []
    private var lastEscAt: TimeInterval = 0
    private let escWindow: TimeInterval

    /// Lets us recognize (and ignore) our OWN synthetic moves/scrolls without
    /// stamping anything on the events — see `SyntheticInputLog`.
    private let syntheticLog: SyntheticInputLog

    init(tripleEscWindow: TimeInterval, syntheticLog: SyntheticInputLog) {
        self.escWindow = tripleEscWindow
        self.syntheticLog = syntheticLog
    }

    /// The CG tap is installed AND currently enabled.
    var isArmed: Bool {
        guard let tap = tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Start (or ensure) the kill switch: install the tap, the persistent health
    /// timer, and the redundant monitor. Returns whether the CG tap armed.
    @discardableResult
    func start() -> Bool {
        if healthTimer == nil { startHealthTimer() }
        if globalMonitor == nil { startGlobalMonitor() }
        return installTapIfNeeded()
    }

    /// Full teardown (used on quit).
    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        removeTap()
        escTimestamps.removeAll()
    }

    // MARK: - Tap install / remove (independent of the health timer)

    @discardableResult
    private func installTapIfNeeded() -> Bool {
        if let tap = tap, CGEvent.tapIsEnabled(tap: tap) { return true }
        removeTap()

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .listenOnly,
                                             eventsOfInterest: mask,
                                             callback: killSwitchCallback,
                                             userInfo: info) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        runLoopSource = source
        return CGEvent.tapIsEnabled(tap: newTap)
    }

    private func removeTap() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Event handling (main run loop)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Ignore our OWN synthetic moves/scrolls — matched against the private
        // in-memory log by position/time, with nothing stamped on the event itself.
        if type == .mouseMoved || type == .scrollWheel ||
           type == .leftMouseDragged || type == .rightMouseDragged ||
           type == .leftMouseDown {
            if syntheticLog.consume(type: type, location: event.location) { return }
        }

        onRealInput?()   // real user input -> auto-pause

        guard type == .keyDown else { return }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        if event.getIntegerValueField(.keyboardEventKeycode) == kEscapeKeyCode {
            recordEsc()
        }
    }

    /// Records one ESC press, de-duplicating the same physical press seen by both
    /// the CG tap and the NSEvent monitor (within 60ms).
    private func recordEsc() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastEscAt < 0.06 { return }
        lastEscAt = now
        escTimestamps.append(now)
        escTimestamps.removeAll { now - $0 > escWindow }
        if escTimestamps.count >= 3 {
            escTimestamps.removeAll()
            onTripleEsc?()
        }
    }

    // MARK: - Redundant global ESC monitor (mouse is NOT monitored here — it could
    // not be distinguished from our own synthetic motion).

    private func startGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return }
            self.onRealInput?()
            if ev.keyCode == UInt16(kEscapeKeyCode) {
                self.recordEsc()
            }
        }
    }

    // MARK: - Persistent health check (never torn down by a failed reinstall)

    private func startHealthTimer() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.installTapIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }
}
