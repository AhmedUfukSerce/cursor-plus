import Foundation

/// All user-tunable knobs for Cursor+, persisted in UserDefaults.
///
/// Defaults are deliberately conservative and "human-feeling". Everything here
/// is read live by the state machine each cycle, so changing a value from the
/// menu takes effect on the next cycle without a restart.
final class Settings {

    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let burstMinSeconds        = "burstMinSeconds"
        static let burstMaxSeconds        = "burstMaxSeconds"
        static let restMinSeconds         = "restMinSeconds"
        static let restMaxSeconds         = "restMaxSeconds"
        static let scrollEnabled          = "scrollEnabled"
        static let scrollProbability      = "scrollProbability"
        static let clickZonesEnabled      = "clickZonesEnabled"
        static let clickProbability       = "clickProbability"
        static let clickZones             = "clickZones"
        static let idlePausesEnabled      = "idlePausesEnabled"
        static let longPausesEnabled      = "longPausesEnabled"
        static let longPauseMinSeconds    = "longPauseMinSeconds"
        static let longPauseMaxSeconds    = "longPauseMaxSeconds"
        static let longPauseProbability   = "longPauseProbability"
        static let tremorAmplitude        = "tremorAmplitude"
        static let autoPauseCooldownSecs  = "autoPauseCooldownSecs"
        static let tripleEscWindowMs      = "tripleEscWindowMs"
        static let weightVerySlow         = "weightVerySlow"
        static let weightSlow             = "weightSlow"
        static let weightNormal           = "weightNormal"
        static let weightFast             = "weightFast"
        static let weightVeryFast         = "weightVeryFast"
        static let preventDisplaySleep    = "preventDisplaySleep"
    }

    private init() {
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.burstMinSeconds:       10.0,
            Key.burstMaxSeconds:       20.0,
            Key.restMinSeconds:        0.5,
            Key.restMaxSeconds:        3.0,
            Key.scrollEnabled:         true,
            Key.scrollProbability:     0.25,   // chance of a scroll at a burst end
            Key.clickZonesEnabled:     true,   // act on user-defined click zones (if any)
            Key.clickProbability:      0.20,   // chance of a zone-click visit at a burst end
            Key.idlePausesEnabled:     true,
            Key.longPausesEnabled:     false,   // opt-in: trades instant-active for realism
            Key.longPauseMinSeconds:   30.0,
            Key.longPauseMaxSeconds:   90.0,
            Key.longPauseProbability:  0.12,    // chance a rest becomes a long pause
            Key.tremorAmplitude:       0.5,     // px; subtle 8–12 Hz micro-motion
            Key.autoPauseCooldownSecs: 3.0,
            Key.tripleEscWindowMs:     900.0,
            Key.weightVerySlow:        2.0,
            Key.weightSlow:            3.0,
            Key.weightNormal:          4.0,
            Key.weightFast:            2.0,
            Key.weightVeryFast:        1.0,
            Key.preventDisplaySleep:   true
        ])
    }

    // MARK: - Active-burst timing (seconds the cursor wanders before a pause)

    var burstMinSeconds: Double {
        get { defaults.double(forKey: Key.burstMinSeconds) }
        set { defaults.set(newValue, forKey: Key.burstMinSeconds) }
    }

    var burstMaxSeconds: Double {
        get { defaults.double(forKey: Key.burstMaxSeconds) }
        set { defaults.set(newValue, forKey: Key.burstMaxSeconds) }
    }

    /// A fresh random active-burst duration in [min, max] seconds.
    func randomBurstSeconds() -> Double {
        let lo = min(burstMinSeconds, burstMaxSeconds)
        let hi = max(burstMinSeconds, burstMaxSeconds)
        guard hi > lo else { return lo }
        return Double.random(in: lo...hi)
    }

    // MARK: - Rest timing (short, bounded human-like pauses between bursts)

    var restMinSeconds: Double {
        get { defaults.double(forKey: Key.restMinSeconds) }
        set { defaults.set(newValue, forKey: Key.restMinSeconds) }
    }

    var restMaxSeconds: Double {
        get { defaults.double(forKey: Key.restMaxSeconds) }
        set { defaults.set(newValue, forKey: Key.restMaxSeconds) }
    }

    /// Hard cap on a rest so no setting (even a hand-edited UserDefaults value) can
    /// open a long silent window that lets the idle timer climb and defeats the
    /// tool's whole purpose.
    private let restHardCapSeconds = 10.0

    /// A fresh random rest duration, clamped to [0, restHardCapSeconds].
    func randomRestSeconds() -> Double {
        let lo = max(0, min(restMinSeconds, restMaxSeconds))
        let hi = min(max(restMinSeconds, restMaxSeconds), restHardCapSeconds)
        guard hi > lo else { return min(lo, restHardCapSeconds) }
        return Double.random(in: lo...hi)
    }

    // MARK: - Scrolling (occasional slow, deliberate scrolls)

    var scrollEnabled: Bool {
        get { defaults.bool(forKey: Key.scrollEnabled) }
        set { defaults.set(newValue, forKey: Key.scrollEnabled) }
    }

    /// Probability of emitting a scroll at the end of an active burst.
    var scrollProbability: Double {
        get { defaults.double(forKey: Key.scrollProbability) }
        set { defaults.set(newValue, forKey: Key.scrollProbability) }
    }

    // MARK: - Click zones (user-defined regions the cursor may occasionally click)

    /// Whether to perform occasional clicks in the user's defined zones. Acts only
    /// if at least one zone exists; toggling off disables clicking without deleting
    /// the zones.
    var clickZonesEnabled: Bool {
        get { defaults.bool(forKey: Key.clickZonesEnabled) }
        set { defaults.set(newValue, forKey: Key.clickZonesEnabled) }
    }

    /// Probability of a zone-click visit at the end of an active burst.
    var clickProbability: Double {
        get { defaults.double(forKey: Key.clickProbability) }
        set { defaults.set(newValue, forKey: Key.clickProbability) }
    }

    /// Load the user's click zones (CG global top-left rects). Empty if none/invalid.
    func loadClickZones() -> [CGRect] {
        guard let data = defaults.data(forKey: Key.clickZones),
              let zones = try? JSONDecoder().decode([ClickZone].self, from: data)
        else { return [] }
        return zones.map { $0.rect }
    }

    /// Persist the user's click zones.
    func saveClickZones(_ rects: [CGRect]) {
        let zones = rects.map { ClickZone(rect: $0) }
        if let data = try? JSONEncoder().encode(zones) {
            defaults.set(data, forKey: Key.clickZones)
        }
    }

    // MARK: - Idle pauses

    var idlePausesEnabled: Bool {
        get { defaults.bool(forKey: Key.idlePausesEnabled) }
        set { defaults.set(newValue, forKey: Key.idlePausesEnabled) }
    }

    // MARK: - Long idle pauses (opt-in heavy-tailed gaps)

    /// When on, a rest occasionally becomes a genuinely long pause (tens of seconds),
    /// giving the activity a human heavy-tailed idle distribution instead of "never
    /// idle >10s". Trade-off: during a long pause no HID events post, so presence/
    /// "away" status may flip — the display-sleep assertion is re-pulsed to keep the
    /// screen awake, but this is why it defaults OFF.
    var longPausesEnabled: Bool {
        get { defaults.bool(forKey: Key.longPausesEnabled) }
        set { defaults.set(newValue, forKey: Key.longPausesEnabled) }
    }

    var longPauseMinSeconds: Double {
        get { defaults.double(forKey: Key.longPauseMinSeconds) }
        set { defaults.set(newValue, forKey: Key.longPauseMinSeconds) }
    }

    var longPauseMaxSeconds: Double {
        get { defaults.double(forKey: Key.longPauseMaxSeconds) }
        set { defaults.set(newValue, forKey: Key.longPauseMaxSeconds) }
    }

    /// Probability that a given rest is upgraded to a long pause (when enabled).
    var longPauseProbability: Double {
        get { defaults.double(forKey: Key.longPauseProbability) }
        set { defaults.set(newValue, forKey: Key.longPauseProbability) }
    }

    /// Hard cap so even a hand-edited value can't open a multi-minute dead window.
    private let longPauseHardCapSeconds = 180.0

    /// A fresh random long-pause duration, clamped to [0, longPauseHardCapSeconds].
    func randomLongPauseSeconds() -> Double {
        let lo = max(0, min(longPauseMinSeconds, longPauseMaxSeconds))
        let hi = min(max(longPauseMinSeconds, longPauseMaxSeconds), longPauseHardCapSeconds)
        guard hi > lo else { return min(lo, longPauseHardCapSeconds) }
        return Double.random(in: lo...hi)
    }

    // MARK: - Motion feel

    /// Amplitude (px) of the subtle 8–12 Hz physiological tremor added to motion.
    /// 0 disables it.
    var tremorAmplitude: Double {
        get { defaults.double(forKey: Key.tremorAmplitude) }
        set { defaults.set(newValue, forKey: Key.tremorAmplitude) }
    }

    // MARK: - Auto-pause

    /// Seconds of real-user idle required before the bot resumes after a pause.
    var autoPauseCooldownSeconds: Double {
        get { defaults.double(forKey: Key.autoPauseCooldownSecs) }
        set { defaults.set(newValue, forKey: Key.autoPauseCooldownSecs) }
    }

    // MARK: - Kill switch

    /// Time window in which three ESC presses count as a triple-tap.
    var tripleEscWindowSeconds: Double {
        get { defaults.double(forKey: Key.tripleEscWindowMs) / 1000.0 }
        set { defaults.set(newValue * 1000.0, forKey: Key.tripleEscWindowMs) }
    }

    // MARK: - Power assertion

    /// Also hold an IOPMAssertion so the display never sleeps while running.
    var preventDisplaySleep: Bool {
        get { defaults.bool(forKey: Key.preventDisplaySleep) }
        set { defaults.set(newValue, forKey: Key.preventDisplaySleep) }
    }

    // MARK: - Speed-class weights

    /// Relative likelihood of picking each speed class for a given move.
    func speedWeights() -> [SpeedClass: Double] {
        [
            .verySlow: defaults.double(forKey: Key.weightVerySlow),
            .slow:     defaults.double(forKey: Key.weightSlow),
            .normal:   defaults.double(forKey: Key.weightNormal),
            .fast:     defaults.double(forKey: Key.weightFast),
            .veryFast: defaults.double(forKey: Key.weightVeryFast)
        ]
    }

    func setWeight(_ value: Double, for speedClass: SpeedClass) {
        let key: String
        switch speedClass {
        case .verySlow: key = Key.weightVerySlow
        case .slow:     key = Key.weightSlow
        case .normal:   key = Key.weightNormal
        case .fast:     key = Key.weightFast
        case .veryFast: key = Key.weightVeryFast
        }
        defaults.set(value, forKey: key)
    }
}
