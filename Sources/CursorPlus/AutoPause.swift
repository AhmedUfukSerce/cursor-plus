import Foundation

/// Tracks the last time the *real* user did something (mouse/keyboard), so the
/// state machine can pause the bot the instant the user takes over and resume
/// only after a quiet cooldown. All access is on the main thread.
final class AutoPause {

    /// Monotonic timestamp of the last real user input, or 0 if none yet seen.
    private(set) var lastActivity: TimeInterval = 0

    /// Call from the event tap whenever a *real* (non-synthetic) input arrives.
    func markActivity() {
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    /// True while we should stay paused: the user has been active within `cooldown`.
    func shouldPause(cooldown: TimeInterval) -> Bool {
        guard lastActivity > 0 else { return false }
        return (ProcessInfo.processInfo.systemUptime - lastActivity) < cooldown
    }

    /// Reset so a fresh ON toggle doesn't start paused from stale activity.
    func reset() {
        lastActivity = 0
    }
}
