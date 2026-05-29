import AppKit
import CoreGraphics

/// Coordinate-space helpers. The whole tool works in **CG global coordinates**
/// (top-left origin, spanning all displays) because that is what `CGEvent` and
/// `CGEvent.location` use.
///
/// AppKit's `NSScreen` works in **bottom-left** global coordinates, so we flip
/// around the primary display's height whenever we borrow `visibleFrame`
/// (which conveniently excludes the menu bar and the Dock).
enum Geometry {

    /// Height of the primary display — the screen whose AppKit origin is (0,0).
    /// This is the pivot for the bottom-left <-> top-left flip.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    /// AppKit global rect (bottom-left) -> CG global rect (top-left).
    static func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Each screen's usable region (menu bar + Dock excluded) in CG coordinates.
    static func visibleRegionsCG() -> [CGRect] {
        NSScreen.screens.map { cgRect(fromAppKit: $0.visibleFrame) }
    }

    /// A random point inside some screen's visibleFrame, returned in CG (top-left)
    /// coordinates. Screens are weighted by visible area so multi-monitor setups
    /// roam proportionally. A small inset keeps motion off the very edge.
    static func randomVisiblePointCG(inset: CGFloat = 6) -> CGPoint {
        let regions = visibleRegionsCG()
        guard !regions.isEmpty else { return .zero }
        let areas = regions.map { Double(max($0.width, 0) * max($0.height, 0)) }
        let total = areas.reduce(0, +)
        var chosen = regions[0]
        if total > 0 {
            var roll = Double.random(in: 0..<total)
            for (i, r) in regions.enumerated() {
                if roll < areas[i] { chosen = r; break }
                roll -= areas[i]
            }
        }
        let r = chosen.insetBy(dx: min(inset, chosen.width / 2),
                               dy: min(inset, chosen.height / 2))
        let x = CGFloat.random(in: r.minX...max(r.minX, r.maxX))
        let y = CGFloat.random(in: r.minY...max(r.minY, r.maxY))
        return CGPoint(x: x, y: y)
    }

    /// Clamp a CG point into the nearest visible region so motion never wanders
    /// onto the menu bar / off-screen.
    static func clampToVisible(_ p: CGPoint) -> CGPoint {
        let regions = visibleRegionsCG()
        guard !regions.isEmpty else { return p }
        if regions.contains(where: { $0.contains(p) }) { return p }
        // Snap to the region whose center is nearest.
        var best = regions[0]
        var bestDist = Double.greatestFiniteMagnitude
        for r in regions {
            let c = CGPoint(x: r.midX, y: r.midY)
            let d = Double(hypot(c.x - p.x, c.y - p.y))
            if d < bestDist { bestDist = d; best = r }
        }
        return CGPoint(x: min(max(p.x, best.minX), best.maxX),
                       y: min(max(p.y, best.minY), best.maxY))
    }
}
