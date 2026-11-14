import CoreGraphics
import Foundation

/// Geometric erasing. Strokes stay vector: the precise eraser cuts strokes
/// exactly where the eraser's edge crosses them, the stroke eraser removes
/// whole strokes. Nothing is ever rasterised, so erased pages still export
/// as crisp vector PDF.
enum Eraser {
    /// Cuts `stroke` with a disc. Returns nil when the disc misses it,
    /// otherwise the surviving pieces (possibly none).
    static func cut(_ stroke: Stroke, cx: Float, cy: Float, radius: Float) -> [Stroke]? {
        let b = stroke.bounds
        if CGFloat(cx) < b.minX - CGFloat(radius) || CGFloat(cx) > b.maxX + CGFloat(radius)
            || CGFloat(cy) < b.minY - CGFloat(radius) || CGFloat(cy) > b.maxY + CGFloat(radius) {
            return nil
        }

        let points = stroke.points
        let r2 = radius * radius
        func inside(_ p: StrokePoint) -> Bool {
            let dx = p.x - cx, dy = p.y - cy
            return dx * dx + dy * dy < r2
        }

        guard points.count > 1 else {
            return points.first.map(inside) == true ? [] : nil
        }

        var pieces: [[StrokePoint]] = []
        var current: [StrokePoint] = []
        var changed = false

        func flush() {
            if current.count >= 2 { pieces.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        var previousInside = inside(points[0])
        if previousInside { changed = true } else { current.append(points[0]) }

        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let bInside = inside(b)

            if previousInside && bInside {
                changed = true
            } else if let hit = crossings(a, b, cx: cx, cy: cy, r2: r2) {
                if previousInside {
                    // Leaving the disc: keep from the exit point on.
                    current = [lerp(a, b, min(1, max(0, hit.exit))), b]
                } else if bInside {
                    current.append(lerp(a, b, min(1, max(0, hit.enter))))
                    flush()
                } else if hit.enter > 0, hit.exit < 1 {
                    // Passes straight through between two samples.
                    current.append(lerp(a, b, hit.enter))
                    flush()
                    current = [lerp(a, b, hit.exit), b]
                } else {
                    current.append(b)
                    previousInside = bInside
                    continue
                }
                changed = true
            } else if !previousInside && !bInside {
                current.append(b)
            } else {
                // Numerically degenerate edge case: treat as a clean break.
                changed = true
                flush()
                if !bInside { current = [b] }
            }
            previousInside = bInside
        }
        flush()

        guard changed else { return nil }
        return pieces.compactMap { piece in
            // Drop crumbs that are shorter than the stroke is wide.
            var length: Float = 0
            for i in 1..<piece.count {
                length += hypotf(piece[i].x - piece[i - 1].x, piece[i].y - piece[i - 1].y)
            }
            guard length > piece[0].r * 0.6 else { return nil }
            return Stroke(brush: stroke.brush, color: stroke.color, points: piece)
        }
    }

    /// True when the disc touches any part of the stroke (stroke eraser).
    static func hits(_ stroke: Stroke, cx: Float, cy: Float, radius: Float) -> Bool {
        let b = stroke.bounds
        if CGFloat(cx) < b.minX - CGFloat(radius) || CGFloat(cx) > b.maxX + CGFloat(radius)
            || CGFloat(cy) < b.minY - CGFloat(radius) || CGFloat(cy) > b.maxY + CGFloat(radius) {
            return false
        }
        let points = stroke.points
        guard points.count > 1 else {
            guard let p = points.first else { return false }
            return hypotf(p.x - cx, p.y - cy) <= radius + p.r
        }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t: Float = 0
            if len2 > 1e-12 {
                t = max(0, min(1, ((cx - a.x) * dx + (cy - a.y) * dy) / len2))
            }
            let px = a.x + dx * t, py = a.y + dy * t
            if hypotf(px - cx, py - cy) <= radius + max(a.r, b.r) { return true }
        }
        return false
    }

    /// Parameters at which segment a→b enters and exits the disc, if its
    /// supporting line intersects it.
    private static func crossings(_ a: StrokePoint, _ b: StrokePoint, cx: Float, cy: Float, r2: Float) -> (enter: Float, exit: Float)? {
        let dx = b.x - a.x, dy = b.y - a.y
        let fx = a.x - cx, fy = a.y - cy
        let qa = dx * dx + dy * dy
        guard qa > 1e-12 else { return nil }
        let qb = 2 * (fx * dx + fy * dy)
        let qc = fx * fx + fy * fy - r2
        let disc = qb * qb - 4 * qa * qc
        guard disc > 0 else { return nil }
        let root = disc.squareRoot()
        return ((-qb - root) / (2 * qa), (-qb + root) / (2 * qa))
    }

    private static func lerp(_ a: StrokePoint, _ b: StrokePoint, _ t: Float) -> StrokePoint {
        StrokePoint(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t,
            r: a.r + (b.r - a.r) * t,
            a: a.a + (b.a - a.a) * t
        )
    }
}
