import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Posts the real OS-level cursor moves (and occasional scrolls) via Quartz.
///
/// Posting a `mouseMoved` event both *moves* the cursor and *registers activity*
/// (resetting the system idle timer) — which is the whole point of the tool.
///
/// Detectability notes (see reviewer.md):
///  • Events are posted from a `.hidSystemState` source to `.cghidEventTap`, so they
///    enter at the HID layer and read as genuine hardware input.
///  • We do NOT stamp `eventSourceUserData` — that constant was a self-identifying
///    fingerprint. Self-recognition is handled out-of-band by `SyntheticInputLog`.
///  • Every move carries a `mouseEventDeltaX/Y` consistent with its position change,
///    matching what real hardware reports (a posted move with a zero delta but a
///    changed position is an impossible state a monitor can flag).
final class InputEngine {

    private let source: CGEventSource?
    private let log: SyntheticInputLog
    private var lastPosted: CGPoint?

    init(log: SyntheticInputLog) {
        self.log = log
        let s = CGEventSource(stateID: .hidSystemState)
        // Do NOT suppress detection of real user input after we post — this keeps
        // auto-pause instantaneous (avoids the 0.25s post-event suppression default).
        s?.localEventsSuppressionInterval = 0
        self.source = s
    }

    /// Phase of a continuous (trackpad-like) scroll gesture.
    enum ScrollPhase: Int64 {
        case began = 1      // kCGScrollPhaseBegan
        case changed = 2    // kCGScrollPhaseChanged
        case ended = 4      // kCGScrollPhaseEnded
    }

    /// Forget the last posted position and clear the synthetic-event log. Call when
    /// motion (re)starts or stops so deltas reseed from the live cursor and no stale
    /// self-recognition entries linger.
    func reset() {
        lastPosted = nil
        log.reset()
    }

    /// Move the real cursor to `point` (CG global coordinates, top-left origin).
    func move(to point: CGPoint) {
        // Seed from the live cursor on the first move (or after a reset) so the
        // first event reports a REAL delta, not a zero-delta-with-changed-position
        // (which is an impossible hardware state a monitor can flag).
        let last = lastPosted ?? InputEngine.currentLocation()

        // Sub-pixel step: skip it. A same-pixel move would be coalesced to a no-op
        // anyway, and nudging by a fixed +1px would compound into a sideways "walk"
        // on slow moves (an artifact in its own right). The path keeps accumulating,
        // so a real ≥1px step arrives within a tick or two and is posted then.
        if abs(point.x - last.x) < 1 && abs(point.y - last.y) < 1 {
            lastPosted = last
            return
        }

        guard let e = CGEvent(mouseEventSource: source,
                              mouseType: .mouseMoved,
                              mouseCursorPosition: point,
                              mouseButton: .left) else { return }

        // Report a hardware-consistent delta (change since the last posted point).
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - last.x).rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - last.y).rounded()))

        // Stamp a real monotonic timestamp. Posted events are constructed with
        // timestamp 0; if the WindowServer doesn't overwrite it on post, a monitor
        // reads timestamp==0 on every event — a deterministic synthetic tell.
        e.timestamp = mach_absolute_time()

        log.recordMove(point)      // record BEFORE post so the tap sees the entry
        e.post(tap: .cghidEventTap)
        lastPosted = point
    }

    /// Emit one tick of a continuous scroll gesture: `deltaY` pixels (positive =
    /// content up / wheel down) at the given phase.
    ///
    /// Pixel-precise scrolling only comes from a continuous device (trackpad / Magic
    /// Mouse), which always carries a phase lifecycle (began → changed → ended) and
    /// `isContinuous = 1`. We stamp both so the event isn't an impossible "phaseless
    /// pixel scroll", which a monitor could flag. Our gesture is a slow, deliberate
    /// scroll that decelerates to ~0, so the absence of a momentum/coast tail is
    /// physically consistent (only a fast flick would coast).
    func scroll(deltaY: Int32, phase: ScrollPhase) {
        guard let e = CGEvent(scrollWheelEvent2Source: source,
                              units: .pixel,
                              wheelCount: 1,
                              wheel1: deltaY,
                              wheel2: 0,
                              wheel3: 0) else { return }
        e.timestamp = mach_absolute_time()
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        log.recordScroll()
        e.post(tap: .cghidEventTap)
    }

    /// Click state for a single (non-double/triple) click — hardware reports 1 for
    /// the first click of a sequence, and both the down and the matching up carry it.
    private static let singleClickState: Int64 = 1

    /// Post a left-button DOWN at `point`. `point` MUST be the cursor's current
    /// (frozen) position: a click happens in place, so deltaX/Y = 0 is the correct
    /// hardware report (the "changed position with 0 delta" tell only fires when the
    /// position actually changed). Recorded in the log so the kill-switch tap ignores
    /// our own click and auto-pause doesn't trip on it.
    func mouseDown(at point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source,
                              mouseType: .leftMouseDown,
                              mouseCursorPosition: point,
                              mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: InputEngine.singleClickState)
        e.setIntegerValueField(.mouseEventDeltaX, value: 0)
        e.setIntegerValueField(.mouseEventDeltaY, value: 0)
        e.timestamp = mach_absolute_time()
        log.recordClick(point)     // record BEFORE post so the tap sees the entry
        e.post(tap: .cghidEventTap)
        lastPosted = point
    }

    /// Post a left-button UP at `point` — MUST be the SAME point as the matching
    /// `mouseDown` so the press never becomes a drag. `.leftMouseUp` is not in the
    /// kill-switch tap's mask, so it needs no log entry.
    func mouseUp(at point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source,
                              mouseType: .leftMouseUp,
                              mouseCursorPosition: point,
                              mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: InputEngine.singleClickState)
        e.setIntegerValueField(.mouseEventDeltaX, value: 0)
        e.setIntegerValueField(.mouseEventDeltaY, value: 0)
        e.timestamp = mach_absolute_time()
        e.post(tap: .cghidEventTap)
        lastPosted = point
    }

    /// The cursor's current location in CG global (top-left) coordinates.
    /// Falls back to the main display's center (never the (0,0) menu-bar corner).
    static func currentLocation() -> CGPoint {
        if let loc = CGEvent(source: nil)?.location { return loc }
        let b = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: b.midX, y: b.midY)
    }
}

/// Holds an IOPMAssertion so the display won't sleep while Cursor+ is running.
/// Belt-and-suspenders alongside the synthetic motion (which already resets idle).
final class PowerAssertion {

    private var id: IOPMAssertionID = 0
    private var active = false

    func begin() {
        guard !active else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Cursor+ keeping the Mac active" as CFString,
            &newID)
        if result == kIOReturnSuccess {
            id = newID
            active = true
        }
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
        id = 0
    }

    /// Declare local user activity — powers the display on and resets the display
    /// idle timer. Called periodically (each burst) as an idle-reset backstop in
    /// addition to the synthetic HID motion. The transient assertion is managed by
    /// the system, so we don't retain it.
    func declareUserActivity() {
        var aid: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Cursor+ user activity" as CFString,
                                             kIOPMUserActiveLocal,
                                             &aid)
    }
}
