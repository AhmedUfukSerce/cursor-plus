import Foundation
import CoreGraphics

/// Private, in-memory record of the input events Cursor+ has just posted, used to
/// tell our own synthetic motion apart from the real user's — WITHOUT writing any
/// marker onto the events themselves.
///
/// The old approach stamped `eventSourceUserData` with a magic constant so the
/// kill-switch tap could ignore our own events. That value is readable by *any*
/// other event tap on the system, so it was a perfect, self-identifying fingerprint
/// of the tool. This log keeps the same recognition entirely inside the process:
/// when `InputEngine` posts a move/scroll it records `(position, time)` here, and
/// the tap consumes the matching entry. Nothing leaks onto the event.
///
/// Threading: `InputEngine` (writer) and `KillSwitch` (reader) both run on the main
/// thread/run loop, so no locking is required.
final class SyntheticInputLog {

    private enum Kind { case move, scroll, click }

    private struct Entry {
        let x: Double
        let y: Double
        let time: TimeInterval
        let kind: Kind
    }

    /// Posted events are delivered to the session tap on the next run-loop pass, so
    /// a genuine match arrives within a few milliseconds. Keep the window tight to
    /// minimise the chance a real user move coincidentally masks as ours.
    private let timeWindow: TimeInterval = 0.18
    /// The session tap may see the coordinate rounded to the pixel grid vs the
    /// sub-pixel point we posted, so allow a small position tolerance.
    private let positionTolerance: Double = 2.0
    private let capacity = 96

    private var entries: [Entry] = []

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Record a synthetic cursor move at `point` (CG global coordinates).
    func recordMove(_ point: CGPoint) {
        append(Entry(x: point.x, y: point.y, time: now(), kind: .move))
    }

    /// Record a synthetic scroll tick (position is irrelevant — matched by time).
    func recordScroll() {
        append(Entry(x: 0, y: 0, time: now(), kind: .scroll))
    }

    /// Record a synthetic left-button press at `point`. Only the DOWN is recorded —
    /// `.leftMouseUp` is not in the kill-switch tap's mask, so it is never observed.
    func recordClick(_ point: CGPoint) {
        append(Entry(x: point.x, y: point.y, time: now(), kind: .click))
    }

    private func append(_ e: Entry) {
        entries.append(e)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// If `type`/`location` matches an event we recently posted, consume that entry
    /// and return `true` (so the tap ignores it). A move matches by position; a
    /// scroll matches by time only. Consuming guarantees one logged event masks at
    /// most one observed event, so a single stale entry can never hide a stream of
    /// real user input.
    func consume(type: CGEventType, location: CGPoint) -> Bool {
        let t = now()
        entries.removeAll { t - $0.time > timeWindow }

        switch type {
        case .scrollWheel:
            if let i = entries.firstIndex(where: { $0.kind == .scroll }) {
                entries.remove(at: i)
                return true
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            if let i = entries.firstIndex(where: {
                $0.kind == .move &&
                abs($0.x - location.x) <= positionTolerance &&
                abs($0.y - location.y) <= positionTolerance
            }) {
                entries.remove(at: i)
                return true
            }
        case .leftMouseDown:
            if let i = entries.firstIndex(where: {
                $0.kind == .click &&
                abs($0.x - location.x) <= positionTolerance &&
                abs($0.y - location.y) <= positionTolerance
            }) {
                entries.remove(at: i)
                return true
            }
        default:
            break
        }
        return false
    }

    /// Drop everything (used when the bot stops, so stale entries can't linger).
    func reset() {
        entries.removeAll()
    }
}
