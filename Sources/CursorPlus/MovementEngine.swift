import Foundation
import CoreGraphics

/// Speed bands for a single move. Truly randomized motion picks a class per move
/// (weighted by Settings), then a px/s value within that class's range.
enum SpeedClass: CaseIterable {
    case verySlow, slow, normal, fast, veryFast

    /// Pixels-per-second range for each band (verified against the research plan).
    var pixelsPerSecondRange: ClosedRange<Double> {
        switch self {
        case .verySlow: return 80...150
        case .slow:     return 150...350
        case .normal:   return 350...700
        case .fast:     return 700...1400
        case .veryFast: return 1400...3000
        }
    }
}

/// Pure geometry + timing for human-like cursor motion. No AppKit, no OS calls —
/// this just turns "go from A to B" into a stream of points over time, so it is
/// trivially testable and reused unchanged regardless of how points get posted.
enum MovementEngine {

    // MARK: - Speed selection

    /// Weighted-random speed class, then a random px/s inside that class.
    static func randomSpeed(settings: Settings) -> Double {
        let weights = settings.speedWeights()
        let total = weights.values.reduce(0, +)
        guard total > 0 else {
            return SpeedClass.normal.pixelsPerSecondRange.lowerBound
        }
        var roll = Double.random(in: 0..<total)
        // Default to the LAST class so floating-point round-off at the very top of
        // the range falls through to a high band rather than always to Normal.
        var chosen: SpeedClass = .veryFast
        for cls in SpeedClass.allCases {
            let w = weights[cls] ?? 0
            if roll < w { chosen = cls; break }
            roll -= w
        }
        return Double.random(in: chosen.pixelsPerSecondRange)
    }

    // MARK: - WindMouse path generation

    /// WindMouse (ben.land) human-mouse-movement physics. Produces a curved,
    /// never-identical polyline from `start` to `dest`. The intrinsic velocity
    /// variation gives natural overshoot/correction; the per-class px/s in
    /// `PathPlayer` controls overall pace.
    ///
    /// Parameters are passed in (rather than fixed) so callers can randomize them
    /// per move — a constant `(G,W,M,D)` makes every path share one statistical
    /// signature, which is exactly what a trained classifier keys on.
    static func windMousePath(from start: CGPoint,
                              to dest: CGPoint,
                              gravity G: Double = 9,
                              wind W: Double = 3,
                              maxStep Mmax: Double = 15,
                              dampDistance D: Double = 12) -> [CGPoint] {
        var points: [CGPoint] = []
        let sqrt3 = 3.0.squareRoot()
        let sqrt5 = 5.0.squareRoot()

        var sx = start.x, sy = start.y
        var vx = 0.0, vy = 0.0
        var wx = 0.0, wy = 0.0
        var M = Mmax

        var dist = hypot(dest.x - sx, dest.y - sy)
        var guardCounter = 0
        let guardLimit = 100_000   // never spin forever on a pathological input

        while dist >= 1.0 && guardCounter < guardLimit {
            guardCounter += 1
            let wMag = min(W, dist)

            if dist >= D {
                wx = wx / sqrt3 + (2.0 * Double.random(in: 0..<1) - 1.0) * wMag / sqrt5
                wy = wy / sqrt3 + (2.0 * Double.random(in: 0..<1) - 1.0) * wMag / sqrt5
            } else {
                wx /= sqrt3
                wy /= sqrt3
                if M < 3 {
                    M = Double.random(in: 3...6)
                } else {
                    M /= sqrt5
                }
            }

            vx += wx + G * (dest.x - sx) / dist
            vy += wy + G * (dest.y - sy) / dist

            let vMag = hypot(vx, vy)
            if vMag > M {
                // Clip to a RANDOM magnitude in [M/2, M] — the source of natural pace variation.
                let vClip = M / 2.0 + Double.random(in: 0..<1) * (M / 2.0)
                vx = (vx / vMag) * vClip
                vy = (vy / vMag) * vClip
            }

            sx += vx
            sy += vy
            points.append(CGPoint(x: sx, y: sy))
            dist = hypot(dest.x - sx, dest.y - sy)
        }

        points.append(dest)
        return points
    }

    /// WindMouse with per-move randomized physics, so no two moves share the same
    /// curvature/velocity signature.
    static func randomizedWindMousePath(from start: CGPoint, to dest: CGPoint) -> [CGPoint] {
        windMousePath(from: start, to: dest,
                      gravity: Double.random(in: 7...12),
                      wind: Double.random(in: 2...5),
                      maxStep: Double.random(in: 12...18),
                      dampDistance: Double.random(in: 10...16))
    }

    /// Total arc length of a polyline.
    static func pathLength(_ path: [CGPoint]) -> Double {
        guard path.count > 1 else { return 0 }
        var acc = 0.0
        for i in 1..<path.count {
            acc += hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y)
        }
        return acc
    }

    // MARK: - Random Gaussian (Box–Muller), drives the tremor band-pass filter

    static func gaussian(mean: Double = 0, standardDeviation sigma: Double = 1) -> Double {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude...1)
        let u2 = Double.random(in: 0..<1)
        let z = (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
        return mean + z * sigma
    }
}

/// A 2nd-order band-pass (biquad) resonator. Driven by white noise it produces a
/// smooth 8–12 Hz resonance hump — the broadband character of real physiological
/// tremor — instead of the two sharp FFT spikes a sum of pure sine tones makes.
/// (RBJ cookbook constant-peak-gain (0 dB) band-pass; `b1 = 0`.)
private struct TremorFilter {
    private let b0: Double, b2: Double, a1: Double, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(centerHz fc: Double, q: Double, sampleHz fs: Double) {
        let w0 = 2 * Double.pi * fc / fs
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b2 = -alpha / a0
        a1 = (-2 * cos(w0)) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Walks a precomputed polyline at a target speed (px/s) over real time. Each move
/// gets its OWN randomized velocity-profile shape (asymmetric accel/decel) plus a
/// subtle band-limited 8–12 Hz physiological tremor, so the per-move kinematics vary
/// the way a real hand's do instead of repeating one fixed easing envelope every
/// time. The caller pumps it with `advance(by:)` once per tick.
final class PathPlayer {

    private let path: [CGPoint]
    private let cumulative: [Double]   // arc length up to each point index
    private let totalLength: Double
    private let targetSpeed: Double    // px/s

    // Per-move randomized ease profile.
    private let easeFloor: Double      // min fraction of target speed at the ends
    private let easePeak: Double       // progress in [0,1] where full speed is reached

    // Band-limited physiological tremor: white noise → biquad band-pass per axis,
    // giving a smooth 8–12 Hz resonance hump (not two sharp spectral spikes), and
    // carrying no broadband high-frequency jerk the way raw per-tick noise would.
    private let tremorGain: Double
    private var tremorX: TremorFilter
    private var tremorY: TremorFilter

    private var distanceTraveled: Double = 0
    private(set) var isFinished = false

    init(path: [CGPoint], targetSpeed: Double, tremorAmplitude: Double = 0.5) {
        // Filter out zero-length duplicate points to keep arc-length math clean.
        var cleaned: [CGPoint] = []
        for p in path {
            if let last = cleaned.last, hypot(p.x - last.x, p.y - last.y) < 0.0001 { continue }
            cleaned.append(p)
        }
        if cleaned.count < 2 { cleaned = path.isEmpty ? [.zero, .zero] : [path[0], path[path.count - 1]] }

        self.path = cleaned
        self.targetSpeed = max(1, targetSpeed)

        // Randomize the velocity-profile shape per move. A peak before 0.5 means a
        // quick accel + longer decel (and vice-versa) — directional asymmetry that
        // a fixed symmetric sine never produces.
        self.easeFloor = Double.random(in: 0.30...0.50)
        self.easePeak  = Double.random(in: 0.35...0.60)

        // Band-limited tremor: scale the white-noise drive so the band-pass output
        // RMS lands near the intended sub-pixel amplitude (the filter attenuates
        // ~0.23×, so ×4).
        let amp = max(0, tremorAmplitude)
        self.tremorGain = (amp > 0 ? Double.random(in: (amp * 0.5)...amp) : 0) * 3.0
        // Independent center + Q per axis so the tremor isn't perfectly isotropic.
        // sampleHz is the NOMINAL tick rate; the real tick is jittered ~75–150 Hz, so
        // the realized 8–12 Hz hump smears slightly with it (harmless — more human).
        self.tremorX = TremorFilter(centerHz: Double.random(in: 8...12), q: Double.random(in: 2.5...4.0), sampleHz: 120.0)
        self.tremorY = TremorFilter(centerHz: Double.random(in: 8...12), q: Double.random(in: 2.5...4.0), sampleHz: 120.0)

        var cum: [Double] = [0]
        var acc = 0.0
        for i in 1..<cleaned.count {
            acc += hypot(cleaned[i].x - cleaned[i - 1].x, cleaned[i].y - cleaned[i - 1].y)
            cum.append(acc)
        }
        self.cumulative = cum
        self.totalLength = acc

        // Warm up the resonators so the 8–12 Hz band is populated from tick one.
        if tremorGain > 0 {
            for _ in 0..<64 {
                _ = tremorX.step(MovementEngine.gaussian())
                _ = tremorY.step(MovementEngine.gaussian())
            }
        }
    }

    /// Asymmetric ease: ramps from `easeFloor` of target speed at the ends up to
    /// full speed at `easePeak`. Never reaches 0, so the move always progresses.
    private func easeMultiplier(progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        // Warp progress so the velocity peak lands at `easePeak` instead of 0.5.
        let warped: Double
        if p < easePeak {
            warped = easePeak > 0 ? 0.5 * (p / easePeak) : 0.5
        } else {
            warped = easePeak < 1 ? 0.5 + 0.5 * ((p - easePeak) / (1 - easePeak)) : 1.0
        }
        return easeFloor + (1 - easeFloor) * sin(.pi * warped)
    }

    /// Advance along the path by `dt` seconds. Returns the next cursor point to
    /// post (with band-limited tremor), or the exact endpoint on the final tick.
    /// Returns nil once finished.
    func advance(by dt: Double) -> CGPoint? {
        guard !isFinished else { return nil }
        guard totalLength > 0 else {
            isFinished = true
            return path.last
        }

        let progress = distanceTraveled / totalLength
        distanceTraveled += targetSpeed * easeMultiplier(progress: progress) * dt

        if distanceTraveled >= totalLength {
            isFinished = true
            return path.last   // land exactly on target, no added noise
        }

        let base = point(atDistance: distanceTraveled)
        guard tremorGain > 0 else { return base }
        // Physiological tremor is suppressed during fast/ballistic motion and present
        // during slow/precise motion (muscle thixotropy): scale it down as speed rises.
        let speedNow = targetSpeed * easeMultiplier(progress: progress)
        // Ceiling < 1 so even slow moves keep the tremor sub-pixel (no visible shake).
        let velScale = max(0.15, min(0.8, 300.0 / max(speedNow, 1)))
        let g = tremorGain * velScale
        let tx = g * tremorX.step(MovementEngine.gaussian())
        let ty = g * tremorY.step(MovementEngine.gaussian())
        return CGPoint(x: base.x + tx, y: base.y + ty)
    }

    private func point(atDistance d: Double) -> CGPoint {
        // Binary-search the cumulative array for the segment containing `d`.
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < d { lo = mid + 1 } else { hi = mid }
        }
        let i = max(1, lo)
        let segStart = cumulative[i - 1]
        let segEnd = cumulative[i]
        let segLen = max(segEnd - segStart, 0.0001)
        let t = min(max((d - segStart) / segLen, 0), 1)
        let a = path[i - 1], b = path[i]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// Emits a single human-like scroll gesture: a total pixel distance delivered over
/// a duration with an ease (slow start, faster middle, slow settle to ~0) so it
/// reads like a slow, DELIBERATE two-finger scroll rather than a constant-rate
/// machine scroll. Deliberately NOT a fast flick: because the gesture decelerates
/// to ~0, the absence of a momentum/coast tail is physically consistent (a flick
/// would coast, a deliberate scroll does not). The caller pumps it once per tick
/// and posts each returned per-tick pixel delta.
final class ScrollPlayer {

    private let totalPixels: Double      // signed: + scrolls one way, − the other
    private let duration: Double

    private var elapsed: Double = 0
    private var emitted: Double = 0
    private(set) var isFinished = false

    init() {
        // A slow, deliberate scroll: ~120–420px over 0.5–1.1s (≈110–840 px/s),
        // random direction — well below "flick" speed so no coast tail is expected.
        let magnitude = Double.random(in: 120...420)
        self.totalPixels = Bool.random() ? magnitude : -magnitude
        self.duration = Double.random(in: 0.5...1.1)
    }

    /// Fraction of the total that should have been emitted by normalized time `u`
    /// (a symmetric smoothstep S-curve: ease-in, then ease-out to ~0 velocity — so
    /// the gesture ends slow and a momentum/coast tail is legitimately absent).
    private func progressFraction(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Advance by `dt`. Returns the integer pixel delta to scroll this tick (may be
    /// 0 on a tick that didn't accumulate a whole pixel), or nil once finished.
    func advance(by dt: Double) -> Int32? {
        guard !isFinished else { return nil }
        elapsed += dt
        let u = elapsed / duration
        let target = totalPixels * progressFraction(u)
        let step = target - emitted

        if u >= 1 {
            isFinished = true
            let remainder = totalPixels - emitted
            return Int32(remainder.rounded())
        }

        let whole = step.rounded(.towardZero)
        guard abs(whole) >= 1 else { return 0 }
        emitted += whole
        return Int32(whole)
    }
}
