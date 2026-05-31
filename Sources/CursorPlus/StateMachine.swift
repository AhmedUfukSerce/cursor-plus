import Foundation
import CoreGraphics

/// The activity rhythm. Drives, on the main run loop, a human-like loop:
///
///   MOVING (wander to random destinations for an "active burst") ->
///   optionally SCROLLING (an occasional deliberate scroll) ->
///   optionally a CLICK VISIT (curve to a user-defined click zone, dwell, click) ->
///   optionally RESTING (a short, bounded pause, like a human reading) ->
///   MOVING ...
///
/// Clicking happens ONLY inside user-defined zones (see ClickZone) — never on
/// arbitrary/empty space — so it is goal-directed (the human pattern) rather than
/// the timer-on-empty-desktop clicking that was previously removed. With no zones
/// defined (or clicking disabled) the loop is movement + scroll only. Motion comes
/// in bursts separated by short rests — still resetting the idle timer often enough
/// (and with the IOPMAssertion) to keep the Mac active.
///
/// It honors auto-pause every tick (pausing the instant the real user is active).
///
/// Threading: everything here runs on the main thread (the self-rescheduling tick
/// targets `.main` and the event tap delivers on the main run loop), so no locking
/// is required.
final class StateMachine {

    enum Phase {
        case idle             // tool is OFF
        case moving           // wandering during an active burst
        case scrolling        // emitting an occasional deliberate scroll
        case approachingClick // moving toward a point inside a user click zone
        case clickDwell       // brief human pause on the target before clicking
        case clicking         // left button held down for a human 50–150ms
        case resting          // a short, bounded human-like pause
    }

    // Collaborators
    private let settings: Settings
    private let input: InputEngine
    private let autoPause: AutoPause

    // Observability
    var onStateChange: (() -> Void)?
    /// Fired at the start of each active burst, so the owner can pulse an idle-reset
    /// backstop (IOPMAssertionDeclareUserActivity) in addition to the HID motion.
    var onActivityPulse: (() -> Void)?

    // Public state
    private(set) var isOn = false
    private(set) var isPaused = false
    private(set) var phase: Phase = .idle
    var isResting: Bool { phase == .resting }

    /// Set by AppController to freeze motion when it cannot guarantee the kill
    /// switch (tap not armed, or Secure Input active). Honored like a pause.
    var safetyHold = false

    /// Set by AppController to freeze motion while a modal UI (the click-zone editor)
    /// is open, so the bot doesn't fight the user's mouse. Honored like a pause.
    var uiHold = false

    /// Longest a single sub-move may take, so one slow move can't run forever.
    private let maxMoveSeconds = 4.0

    /// Human pre-click dwell and button-hold ranges (seconds).
    private let clickDwellRange = 0.08...0.30
    private let clickHoldRange = 0.05...0.15

    /// How often to re-pulse the display-wake assertion during a long idle pause.
    private let longPauseRepulseSeconds: TimeInterval = 25

    // Self-rescheduling tick (~120 Hz nominal, with per-tick interval jitter so the
    // synthetic event stream isn't suspiciously uniform).
    private let baseTickSeconds = 1.0 / 120.0
    private var runToken = 0

    // Motion
    private var currentPoint: CGPoint = .zero
    private var player: PathPlayer?
    private var scrollPlayer: ScrollPlayer?
    private var scrollStarted = false
    private var lastTick: TimeInterval = 0

    // Burst / rest clocks
    private var burstStart: TimeInterval = 0
    private var burstDuration: TimeInterval = 0
    private var restStart: TimeInterval = 0
    private var restDuration: TimeInterval = 0
    private var lastRestPulse: TimeInterval = 0   // re-pulse the wake assertion during long pauses

    // Click-visit state
    private var clickPoint: CGPoint = .zero       // frozen press point (so down/up match)
    private var clickDwellStart: TimeInterval = 0
    private var clickDwellDuration: TimeInterval = 0
    private var clickHoldStart: TimeInterval = 0
    private var clickHoldDuration: TimeInterval = 0
    private var clickDown = false                 // is a synthetic button currently held?

    init(settings: Settings, input: InputEngine, autoPause: AutoPause) {
        self.settings = settings
        self.input = input
        self.autoPause = autoPause
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - On/off

    func start() {
        guard !isOn else { return }
        isOn = true
        isPaused = false
        autoPause.reset()
        input.reset()                                   // reseed deltas, clear stale log
        currentPoint = InputEngine.currentLocation()
        beginBurst()
        lastTick = now()

        runToken &+= 1
        scheduleNextTick(token: runToken)
        onStateChange?()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        isPaused = false
        releaseClickIfHeld()    // never leave a button held when stopping
        phase = .idle
        runToken &+= 1          // invalidate any in-flight scheduled tick
        player = nil
        scrollPlayer = nil
        scrollStarted = false
        input.reset()           // drop stale self-recognition entries
        onStateChange?()
    }

    // MARK: - Tick scheduling (jittered, self-rescheduling)

    private func scheduleNextTick(token: Int) {
        guard isOn, token == runToken else { return }
        let interval = baseTickSeconds * Double.random(in: 0.8...1.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.tick(token: token)
        }
    }

    private func tick(token: Int) {
        guard isOn, token == runToken else { return }
        let t = now()
        let dt = max(0, min(t - lastTick, 0.1))   // clamp after any stall
        lastTick = t
        step(t: t, dt: dt)
        scheduleNextTick(token: token)
    }

    // MARK: - Step

    private func step(t: TimeInterval, dt: TimeInterval) {
        // Pause instantly on real user input OR when the app cannot guarantee the
        // kill switch (safetyHold); resume only after a quiet cooldown.
        let userActive = autoPause.shouldPause(cooldown: settings.autoPauseCooldownSeconds)
        if userActive || safetyHold || uiHold {
            releaseClickIfHeld()            // never leave a button held across a pause
            if !isPaused { isPaused = true; onStateChange?() }
            return
        } else if isPaused {
            isPaused = false
            input.reset()                                  // reseed deltas, clear stale log
            currentPoint = InputEngine.currentLocation()   // user may have moved it
            beginBurst()                                   // fresh burst
            onStateChange?()
        }

        switch phase {
        case .idle:
            break

        case .moving:
            if player == nil && t - burstStart >= burstDuration {
                endBurst()
                return
            }
            if player == nil { newPlayer(to: Geometry.randomVisiblePointCG()) }
            advance(dt: dt)

        case .scrolling:
            guard let sp = scrollPlayer else { beginInterludeOrBurst(); return }
            if let delta = sp.advance(by: dt), delta != 0 {
                input.scroll(deltaY: delta, phase: scrollStarted ? .changed : .began)
                scrollStarted = true
            }
            if sp.isFinished {
                if scrollStarted { input.scroll(deltaY: 0, phase: .ended) }   // close the gesture
                scrollPlayer = nil
                scrollStarted = false
                beginInterludeOrBurst()
            }

        case .approachingClick:
            if player == nil {           // arrived at the in-zone target
                phase = .clickDwell
                clickDwellStart = t
                clickDwellDuration = Double.random(in: clickDwellRange)   // human pre-click pause
                return
            }
            advance(dt: dt)

        case .clickDwell:
            if t - clickDwellStart >= clickDwellDuration { beginClick(at: t) }

        case .clicking:
            // Cursor frozen during the hold (no advance), so the press can't drag.
            if t - clickHoldStart >= clickHoldDuration {
                releaseClickIfHeld()
                beginInterludeOrBurst()
            }

        case .resting:
            // During a long pause no HID events post, so re-pulse the display-wake
            // assertion every ~25s to keep the screen awake while we sit idle.
            if t - lastRestPulse >= longPauseRepulseSeconds {
                lastRestPulse = t
                onActivityPulse?()
            }
            if t - restStart >= restDuration { beginBurst() }
        }
    }

    // MARK: - Phase transitions

    private func beginBurst() {
        phase = .moving
        player = nil
        scrollPlayer = nil
        burstStart = now()
        burstDuration = settings.randomBurstSeconds()
        onActivityPulse?()      // idle-reset backstop at the start of each burst
        onStateChange?()
    }

    /// End of an active burst: occasionally pay a goal-directed "click visit" to a
    /// user-defined zone, else occasionally scroll, else go to the interlude. The
    /// cheap probability checks short-circuit before decoding the zones.
    private func endBurst() {
        if settings.clickZonesEnabled && Double.random(in: 0..<1) < settings.clickProbability,
           let zone = settings.loadClickZones().randomElement() {
            beginClickVisit(zone: zone)
            return
        }
        if settings.scrollEnabled && Double.random(in: 0..<1) < settings.scrollProbability {
            phase = .scrolling
            scrollPlayer = ScrollPlayer()
            scrollStarted = false
            onActivityPulse?()      // idle-reset backstop while scrolling
            onStateChange?()
        } else {
            beginInterludeOrBurst()
        }
    }

    // MARK: - Click visit (goal-directed, user-defined zones only)

    /// Curve toward a random (center-biased) point inside a user zone; on arrival we
    /// dwell then click. The approach reuses the normal WindMouse path, so it
    /// naturally curves in — exactly the human point-and-click pattern.
    private func beginClickVisit(zone: CGRect) {
        let target = Geometry.clampToVisible(ClickZone(rect: zone).randomPoint())
        phase = .approachingClick
        newPlayer(to: target)
        onActivityPulse?()
        onStateChange?()
    }

    /// Press the left button at the (frozen) arrival point and hold a human 50–150ms.
    private func beginClick(at t: TimeInterval) {
        phase = .clicking
        clickPoint = currentPoint
        clickHoldStart = t
        clickHoldDuration = Double.random(in: clickHoldRange)
        input.mouseDown(at: Geometry.clampToVisible(clickPoint))
        clickDown = true
        onActivityPulse?()
        onStateChange?()
    }

    /// Release a held synthetic click immediately, at the SAME point as the press so
    /// it can never read as a drag. Idempotent; safe to call from any exit path.
    private func releaseClickIfHeld() {
        guard clickDown else { return }
        clickDown = false
        input.mouseUp(at: Geometry.clampToVisible(clickPoint))
    }

    /// After moving/scrolling: take a short human-like rest (if enabled) then move.
    /// Occasionally (opt-in) the rest is a genuinely long pause, giving the activity
    /// a human heavy-tailed idle distribution instead of "never idle >10s".
    private func beginInterludeOrBurst() {
        guard settings.idlePausesEnabled else { beginBurst(); return }
        phase = .resting
        restStart = now()
        lastRestPulse = restStart
        if settings.longPausesEnabled && Double.random(in: 0..<1) < settings.longPauseProbability {
            restDuration = settings.randomLongPauseSeconds()
        } else {
            restDuration = settings.randomRestSeconds()
        }
        onActivityPulse?()      // pulse at rest start
        onStateChange?()
    }

    // MARK: - Motion helpers

    private func newPlayer(to dest: CGPoint) {
        let path = MovementEngine.randomizedWindMousePath(from: currentPoint, to: dest)
        var speed = MovementEngine.randomSpeed(settings: settings)
        // Floor the speed so even a "very slow" pick can't make one move drag on
        // past maxMoveSeconds.
        let length = MovementEngine.pathLength(path)
        let minSpeed = length / maxMoveSeconds
        if speed < minSpeed { speed = minSpeed }
        player = PathPlayer(path: path, targetSpeed: speed, tremorAmplitude: settings.tremorAmplitude)
    }

    /// Advance the active move by `dt` and post the cursor. Clears `player` when done.
    private func advance(dt: TimeInterval) {
        guard let p = player else { return }
        if let pt = p.advance(by: dt) {
            currentPoint = pt
            input.move(to: Geometry.clampToVisible(pt))
        }
        if p.isFinished { player = nil }
    }
}
