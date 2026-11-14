import CoreGraphics
import Foundation
import simd

/// One raw input sample, already converted to page coordinates.
struct InputSample {
    var position: CGPoint
    /// 0…1, or negative when the device reports no pressure (finger, mouse).
    var pressure: CGFloat
    /// Radians above the screen plane; π/2 is perpendicular.
    var altitude: CGFloat
    var time: TimeInterval
}

/// How a brush turns pressure, speed and tilt into width and opacity.
struct BrushDynamics {
    var minScale: Float
    var maxScale: Float
    var gamma: Float
    /// Width lost at speed.
    var speedThinning: Float
    var tiltWidening: Float
    var minAlpha: Float
    var maxAlpha: Float
    /// Extra width where the tip dwells and ink keeps soaking in (natural ink).
    var pooling: Float = 0
    /// Width follows the tip's landing and lift down to a hairline (natural ink).
    var tapers = false
    /// Opacity follows the tip's landing and lift (graphite).
    var fades = false

    /// `natural` models real writing instruments: line weight comes mostly
    /// from how the tip moves (ink flow), terminals taper with the landing
    /// and lift, and pressure matters less than on a typical digital pen.
    static func forKind(_ kind: BrushKind, natural: Bool = false) -> BrushDynamics {
        switch kind {
        case .pen:
            return natural
                ? BrushDynamics(minScale: 0.80, maxScale: 1.22, gamma: 0.8, speedThinning: 0.22, tiltWidening: 0,
                                minAlpha: 1, maxAlpha: 1, pooling: 0.14, tapers: true)
                : BrushDynamics(minScale: 0.62, maxScale: 1.28, gamma: 0.85, speedThinning: 0.12, tiltWidening: 0, minAlpha: 1, maxAlpha: 1)
        case .brush:
            return natural
                ? BrushDynamics(minScale: 0.14, maxScale: 2.0, gamma: 1.25, speedThinning: 0.3, tiltWidening: 0,
                                minAlpha: 1, maxAlpha: 1, pooling: 0.10, tapers: true)
                : BrushDynamics(minScale: 0.14, maxScale: 2.0, gamma: 1.25, speedThinning: 0.3, tiltWidening: 0, minAlpha: 1, maxAlpha: 1)
        case .marker, .highlighter:
            return BrushDynamics(minScale: 1, maxScale: 1, gamma: 1, speedThinning: 0, tiltWidening: 0, minAlpha: 1, maxAlpha: 1)
        case .pencil:
            return BrushDynamics(minScale: 0.85, maxScale: 1.1, gamma: 1, speedThinning: 0, tiltWidening: 3,
                                 minAlpha: 0.2, maxAlpha: 0.95, fades: natural)
        }
    }
}

/// Turns raw touch samples into a variable-width polyline, incrementally.
///
/// A stylus on glass has almost no friction, so the tip skids as it lands and
/// lifts, overshoots at corners and carries every tremor of the hand straight
/// into the line. Time-domain smoothing hides some of that but behaves like
/// writing through syrup: its lag grows with speed and it melts corners. This
/// builder instead models what paper does:
///
///  1. **Grip.** The ink is dragged by the tip through dry (Coulomb) friction
///     that grows with pressure: tip movements smaller than the grip distance
///     do not move the ink at all, larger ones drag it along a fixed, tiny
///     distance behind. Unlike a low-pass filter this lag is a bounded
///     distance, not a time, so it never becomes visible at speed.
///  2. **Settling.** Ink within a couple of points of the tip stays
///     provisional. As the tip moves on, each control point is replaced by a
///     zero-phase average of its neighbours on both sides, which removes
///     tremor with no lag at all. The average stops at corners, so cusps and
///     angles stay as sharp as they were drawn.
///  3. **Landing and lift.** Short, light, sharply angled skids at the two
///     ends of a stroke are removed.
///  4. **Ink flow.** With natural ink, line weight follows the tip like a
///     real pen: hairline as it lands and lifts, a little heavier where it
///     slows or dwells, lighter when it races.
///
/// `smoothing` (the classic viscous filter) is still available on top.
/// With `paper == 0` and `naturalInk == false` the output is exactly the
/// classic pipeline.
///
/// `points` only ever grows. Everything between the last committed point and
/// the pen tip, including the still-settling ink, is returned by `tailPoints`
/// and redrawn every frame, so the line always reaches the tip.
final class StrokeBuilder {
    private struct Node {
        var p: SIMD2<Double>
        var r: Float
        var a: Float
        /// Arc length from the start of the stroke, page units.
        var s: Double = 0
        var pressure: Float = 0

        var point: StrokePoint { StrokePoint(x: Float(p.x), y: Float(p.y), r: r, a: a) }

        static func mid(_ a: Node, _ b: Node) -> Node {
            Node(p: (a.p + b.p) * 0.5, r: (a.r + b.r) * 0.5, a: (a.a + b.a) * 0.5)
        }
    }

    let kind: BrushKind
    /// Base half-width in page units.
    let radius: Float
    /// 0 (off) … 1 (heavy): classic speed-adaptive low-pass.
    let smoothing: Double
    /// 0 (glass) … 1 (toothy paper): friction, settling and skid removal.
    let paper: Double
    let naturalInk: Bool
    /// View points per page unit when the stroke started. All perceptual
    /// thresholds are defined on screen, so writing behaves the same at any zoom.
    let zoom: Double

    private let dynamics: BrushDynamics
    private let tolerance: Double
    private let minSpacing: Double

    // Paper model, page units.
    private let sigma: Double       // radius of the settling average
    private let baseline: Double    // span over which a corner is judged
    private let hookLength: Double  // longest skid that may be removed
    private let hookAngle: Double   // sharpest turn that is still kept, radians
    private let loopLength: Double  // longest overshoot loop that is closed up
    private let window: Double      // how far behind the tip ink stays provisional

    private(set) var points: [StrokePoint] = []

    private var nodes: [Node] = []          // every control point of the stroke
    private var cornerCache: [Float] = []   // NaN until known for good
    private var settled = 0                 // nodes[..<settled] are in `points`

    private var anchor: Node?      // last committed point
    private var lastControl: Node? // last committed control point
    private var current: Node?     // latest filtered state
    private var controlCount = 0

    private var started = false
    private var finished = false
    private var startChecked = false
    private var hasPressure = false
    private var rawLast = SIMD2<Double>(0, 0)
    private var nib = SIMD2<Double>(0, 0)       // where friction has dragged the ink
    private var slack = SIMD2<Double>(0, 0)     // from the ink to the tip when it was last dragged
    private var filtered = SIMD2<Double>(0, 0)
    private var lastTime: TimeInterval = 0
    private var speed: Double = 0               // view points per second, smoothed
    private var pressure: Double = 0
    private var contactPressure: Double = 0     // like `pressure`, but lets go at once
    private var peakPressure: Double = 0
    private var flow: Float = -1                // ink flow (width scale) with inertia

    init(kind: BrushKind, radius: Float, smoothing: Double, zoom: Double, paper: Double = 0, naturalInk: Bool = false) {
        self.kind = kind
        self.radius = max(radius, 0.05)
        self.smoothing = max(0, min(1, smoothing))
        self.paper = max(0, min(1, paper))
        self.naturalInk = naturalInk
        self.zoom = max(zoom, 0.0001)
        self.dynamics = BrushDynamics.forKind(kind, natural: naturalInk)
        // Geometry error budget: about a tenth of a screen point at the zoom
        // the stroke was drawn at, bounded so strokes drawn zoomed out still
        // hold up when zoomed in later.
        self.tolerance = min(0.05, max(0.003, 0.1 / self.zoom))
        self.minSpacing = 0.35 / self.zoom

        let feel = self.paper
        sigma = feel * 1.1 / self.zoom
        baseline = 1.5 / self.zoom
        hookLength = feel > 0 ? (1.2 + 1.6 * feel) / self.zoom : 0
        hookAngle = (95 - 20 * feel) * .pi / 180
        loopLength = feel > 0 ? (1.0 + 2.0 * feel) / self.zoom : 0
        window = feel > 0 ? max(3 * sigma, hookLength, loopLength) + baseline : 0
    }

    var isEmpty: Bool { !started }

    /// Distance between the pen tip and the ink it is dragging, in view points.
    var followGap: Double {
        guard let current else { return 0 }
        return simd_length(rawLast - current.p) * zoom
    }

    /// Length of ink behind the tip that may still settle, in view points.
    var provisionalLength: Double {
        guard let tip = nodes.last else { return 0 }
        let from = settled > 0 ? nodes[settled - 1].s : nodes[0].s
        return (tip.s - from) * zoom
    }

    // MARK: Input

    func add(_ sample: InputSample) {
        guard !finished else { return }
        let raw = SIMD2<Double>(Double(sample.position.x), Double(sample.position.y))

        guard started else {
            started = true
            hasPressure = sample.pressure >= 0
            rawLast = raw
            nib = raw
            filtered = raw
            lastTime = sample.time
            speed = 0
            pressure = targetPressure(for: sample)
            contactPressure = pressure
            peakPressure = pressure
            let node = makeNode(at: raw, altitude: sample.altitude, dt: 0)
            current = node
            nodes.append(node)
            cornerCache.append(.nan)
            settle()
            return
        }

        let dt = max(sample.time - lastTime, 0.001)
        lastTime = sample.time

        let instantSpeed = simd_length(raw - rawLast) * zoom / dt
        speed += (instantSpeed - speed) * (1 - exp(-dt / 0.03))
        rawLast = raw

        let force = targetPressure(for: sample)
        pressure += (force - pressure) * (1 - exp(-dt / (naturalInk ? 0.008 : 0.014)))
        // Losing contact shows immediately; gaining it is smoothed.
        contactPressure = min(pressure, force)
        peakPressure = max(peakPressure, pressure)

        // Dry friction: the harder the tip presses, the more it has to move
        // before the ink follows. The ink then trails by exactly that grip.
        var target = raw
        let slackBefore = slack
        if paper > 0 {
            let grip = paper * (0.10 + 0.45 * max(0, min(1, pressure))) / zoom
            let pull = raw - nib
            let stretch = simd_length(pull)
            if stretch > grip {
                nib += pull * ((stretch - grip) / stretch)
                slack = raw - nib
            }
            target = nib
        }

        if smoothing > 0.001 {
            let minCutoff = 30 * pow(0.04, smoothing)          // Hz
            let beta = 0.12 + (0.004 - 0.12) * smoothing       // Hz per (pt/s)
            let cutoff = minCutoff + beta * speed
            filtered += (target - filtered) * (1 - exp(-2 * .pi * cutoff * dt))
        } else {
            filtered = target
        }

        let node = makeNode(at: filtered, altitude: sample.altitude, dt: dt)
        let previous = current
        current = node

        // Where the ink doubled back between control points, keep the turning
        // point itself, so cusps and corners reach as far as the pen did.
        if paper > 0, let previous, let last = nodes.last {
            let out = previous.p - last.p, back = node.p - previous.p
            if simd_length(out) >= minSpacing * 0.3, simd_dot(out, back) < 0 {
                // The ink stopped one grip short of where the tip turned;
                // the stroke should reach as far as the pen did.
                var vertex = previous
                if simd_dot(slackBefore, out) > 0 { vertex.p += slackBefore }
                place(vertex)
            }
        }
        guard let last = nodes.last, simd_length(node.p - last.p) >= minSpacing else { return }
        place(node)
        settle()
    }

    private func place(_ node: Node) {
        guard let last = nodes.last else { return }
        var placed = node
        placed.s = last.s + simd_length(node.p - last.p)
        nodes.append(placed)
        cornerCache.append(.nan)
        if loopLength > 0 { closeOvershootLoop() }
    }

    /// With nothing to brake it, the tip runs past a corner and swings back,
    /// leaving a loop far too small to be deliberate; tremor does the same
    /// where the pen retraces a line. Paper would have held the tip to a
    /// clean reversal, so fold each such loop flat: the ink still goes out to
    /// the loop's farthest point and comes back, but as a sharp cusp.
    private func closeOvershootLoop() {
        let n = nodes.count
        guard n >= 4 else { return }
        let c = nodes[n - 2].p, d = nodes[n - 1].p
        var i = n - 4
        while i >= max(settled - 1, 0), nodes[n - 2].s - nodes[i + 1].s <= loopLength {
            let a = nodes[i].p, b = nodes[i + 1].p
            let r = b - a, q = d - c
            let denominator = r.x * q.y - r.y * q.x
            if abs(denominator) > 1e-18 {
                let t = ((c.x - a.x) * q.y - (c.y - a.y) * q.x) / denominator
                let u = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denominator
                if t > 0, t < 1, u > 0, u < 1 {
                    let from = nodes[i], to = nodes[i + 1]
                    let crossing = Node(
                        p: a + r * t,
                        r: from.r + (to.r - from.r) * Float(t), a: from.a + (to.a - from.a) * Float(t),
                        pressure: from.pressure + (to.pressure - from.pressure) * Float(t)
                    )
                    // The point of the loop that reached farthest from the crossing.
                    var far = nodes[i + 1]
                    for k in (i + 1)...(n - 2) where simd_length(nodes[k].p - crossing.p) > simd_length(far.p - crossing.p) {
                        far = nodes[k]
                    }
                    // Out to the far point and straight back. The far point is
                    // doubled so the curve passes through it.
                    var folded = [crossing, far, far, crossing, nodes[n - 1]]
                    var arc = from.s
                    var position = a
                    for k in folded.indices {
                        arc += simd_length(folded[k].p - position)
                        position = folded[k].p
                        folded[k].s = arc
                    }
                    nodes.replaceSubrange((i + 1)..<n, with: folded)
                    cornerCache = [Float](repeating: .nan, count: nodes.count)
                    return
                }
            }
            i -= 1
        }
    }

    private func targetPressure(for sample: InputSample) -> Double {
        if sample.pressure >= 0 { return Double(min(sample.pressure, 1)) }
        // No pressure sensor: fake it from speed so fast strokes thin out.
        return 0.72 - 0.42 * min(1, speed / 1600)
    }

    private func makeNode(at p: SIMD2<Double>, altitude: CGFloat, dt: Double) -> Node {
        let force = Float(max(0, min(1, pressure)))
        let w = pow(force, dynamics.gamma)
        var scale = dynamics.minScale + (dynamics.maxScale - dynamics.minScale) * w
        var alpha = dynamics.minAlpha + (dynamics.maxAlpha - dynamics.minAlpha) * w

        if naturalInk {
            // Ink flow: more where the tip lingers, less when it races.
            let v = Float(speed)
            scale *= 1 + dynamics.pooling * exp(-v / 30) - dynamics.speedThinning * min(1, v / 700)
            // Flow has a little inertia; it cannot jump between samples.
            flow = flow < 0 ? scale : flow + (scale - flow) * Float(1 - exp(-dt / 0.010))
            scale = flow
            // A nib only lays down a full line while it bears on the paper,
            // so the line thins to a hairline as the tip lands and lifts.
            let contact: Float = hasPressure ? 1 - exp(-Float(max(0, contactPressure)) / 0.03) : 1
            if dynamics.tapers { scale *= contact }
            if dynamics.fades { alpha *= contact }
        } else {
            scale *= 1 - dynamics.speedThinning * Float(min(1, speed / 2400))
        }

        if dynamics.tiltWidening > 0 {
            // Laying the pencil down shades with the side of the lead.
            let degrees = Float(altitude) * 180 / .pi
            let tilt = max(0, min(1, (55 - degrees) / 35))
            let widen = 1 + dynamics.tiltWidening * tilt
            scale *= widen
            alpha /= pow(widen, 0.6)
        }
        return Node(p: p, r: max(0.04, radius * scale), a: max(0.02, min(1, alpha)), pressure: force)
    }

    // MARK: Settling

    /// Commits control points once they are far enough behind the tip.
    private func settle(all: Bool = false) {
        while settled < nodes.count, let tip = nodes.last?.s, all || tip - nodes[settled].s >= window {
            if settled == 0, hookLength > 0, !startChecked {
                startChecked = true
                if removeStartHook() { continue }
            }
            emit(smoothed(settled))
            settled += 1
        }
    }

    /// Extends the committed curve by one control point.
    private func emit(_ node: Node) {
        guard let previous = lastControl, let start = anchor else {
            points.append(node.point)
            anchor = node
            lastControl = node
            controlCount = 1
            return
        }
        let mid = Node.mid(previous, node)
        if controlCount == 1 {
            points.append(mid.point)
        } else {
            flatten(from: start, control: previous, to: mid, into: &points)
        }
        anchor = mid
        lastControl = node
        controlCount += 1
    }

    /// The control point with tremor averaged out. The average is symmetric
    /// (so it adds no lag), shrinks to nothing next to the tip and the ends
    /// (so the line still meets the pen), and never reaches across a corner.
    private func smoothed(_ index: Int) -> Node {
        var node = nodes[index]
        guard sigma > 0, index > 0, index < nodes.count - 1 else { return node }
        let reach = min(node.s - nodes[0].s, nodes[nodes.count - 1].s - node.s)
        let spread = min(sigma, reach / 3) * Double(1 - cornerStrength(index))
        guard spread > minSpacing * 0.25 else { return node }

        var weight = span(index)
        var sum = node.p * weight
        for direction in [-1, 1] {
            var barrier = 1.0
            var j = index + direction
            while j >= 0, j < nodes.count {
                let distance = abs(nodes[j].s - node.s)
                if distance > 3 * spread { break }
                barrier *= Double(1 - cornerStrength(j))
                if barrier < 0.05 { break }
                let w = exp(-distance * distance / (2 * spread * spread)) * barrier * span(j)
                sum += nodes[j].p * w
                weight += w
                j += direction
            }
        }
        if weight > 0 { node.p = sum / weight }
        return node
    }

    /// Length of path a control point stands for (they are unevenly spaced).
    private func span(_ index: Int) -> Double {
        let before = index > 0 ? nodes[index].s - nodes[index - 1].s : 0
        let after = index < nodes.count - 1 ? nodes[index + 1].s - nodes[index].s : 0
        return max((before + after) / 2, 1e-9)
    }

    /// 0 on straight or gently curving ink, 1 at a sharp turn. Judged over a
    /// span long enough that tremor does not read as a corner.
    private func cornerStrength(_ index: Int) -> Float {
        let cached = cornerCache[index]
        if !cached.isNaN { return cached }
        let node = nodes[index]
        let back = min(baseline, node.s - nodes[0].s)
        let ahead = min(baseline, nodes[nodes.count - 1].s - node.s)
        guard back > baseline * 0.3, ahead > baseline * 0.3 else { return 0 }
        let strength = Float(max(0, min(1, (turn(at: index, back: back, ahead: ahead) - 40 * .pi / 180) / (50 * .pi / 180))))
        let eased = strength * strength * (3 - 2 * strength)
        if back >= baseline * 0.999, ahead >= baseline * 0.999 { cornerCache[index] = eased }
        return eased
    }

    /// Angle between the path arriving at a node and the path leaving it.
    private func turn(at index: Int, back: Double, ahead: Double) -> Double {
        let node = nodes[index]
        let u = node.p - position(atArc: node.s - back, near: index)
        let v = position(atArc: node.s + ahead, near: index) - node.p
        let lu = simd_length(u), lv = simd_length(v)
        guard lu > 1e-12, lv > 1e-12 else { return 0 }
        return acos(max(-1, min(1, simd_dot(u, v) / (lu * lv))))
    }

    private func position(atArc s: Double, near index: Int) -> SIMD2<Double> {
        var j = index
        if s >= nodes[index].s {
            while j < nodes.count - 1, nodes[j + 1].s < s { j += 1 }
            guard j < nodes.count - 1 else { return nodes[nodes.count - 1].p }
            let a = nodes[j], b = nodes[j + 1]
            return b.s > a.s ? a.p + (b.p - a.p) * ((s - a.s) / (b.s - a.s)) : a.p
        }
        while j > 0, nodes[j - 1].s > s { j -= 1 }
        guard j > 0 else { return nodes[0].p }
        let a = nodes[j - 1], b = nodes[j]
        return b.s > a.s ? a.p + (b.p - a.p) * ((s - a.s) / (b.s - a.s)) : b.p
    }

    private func node(nearArc s: Double, from index: Int) -> Node {
        var j = index
        while j < nodes.count - 1, nodes[j].s < s { j += 1 }
        while j > 0, nodes[j].s > s { j -= 1 }
        return nodes[j]
    }

    // MARK: Landing and lift skids

    /// A skid as the tip lands: a short, light run that turns sharply into
    /// the stroke proper. Only judged with a pressure-sensing stylus, where
    /// rising pressure tells a landing from a deliberate serif.
    private func removeStartHook() -> Bool {
        guard hasPressure, nodes.count >= 3, let tip = nodes.last?.s else { return false }
        var vertex = -1
        var sharpest = hookAngle
        for v in 1..<(nodes.count - 1) {
            let lead = nodes[v].s - nodes[0].s
            if lead > hookLength { break }
            let ahead = min(baseline, tip - nodes[v].s)
            guard ahead >= baseline * 0.6, lead > 1e-9 else { continue }
            let angle = turn(at: v, back: lead, ahead: ahead)
            let settledPressure = node(nearArc: nodes[v].s + ahead, from: v).pressure
            if angle >= sharpest, nodes[0].pressure < 0.6 * settledPressure {
                vertex = v
                sharpest = angle
            }
        }
        guard vertex > 0 else { return false }
        nodes.removeFirst(vertex)
        let origin = nodes[0].s
        for i in nodes.indices { nodes[i].s -= origin }
        cornerCache = [Float](repeating: .nan, count: nodes.count)
        return true
    }

    /// The matching skid as the tip lifts: pressure falls away while the tip
    /// slides off at a sharp angle.
    private func removeEndHook() {
        guard hasPressure, nodes.count >= 3 else { return }
        let end = nodes.count - 1
        var vertex = -1
        var sharpest = hookAngle
        var v = end - 1
        while v >= max(settled, 1) {
            let tail = nodes[end].s - nodes[v].s
            if tail > hookLength { break }
            let back = min(baseline, nodes[v].s - nodes[0].s)
            if back >= baseline * 0.6, tail > 1e-9 {
                let angle = turn(at: v, back: back, ahead: tail)
                let writingPressure = node(nearArc: nodes[v].s - back, from: v).pressure
                if angle >= sharpest, nodes[end].pressure < 0.6 * writingPressure {
                    vertex = v
                    sharpest = angle
                }
            }
            v -= 1
        }
        guard vertex > 0 else { return }
        nodes.removeSubrange((vertex + 1)...)
        cornerCache = [Float](repeating: .nan, count: nodes.count)
    }

    // MARK: Output

    /// Polyline from the last committed point to the pen tip (plus predicted
    /// positions), including ink that is still settling. Not part of
    /// `points`; recomputed on every update.
    func tailPoints(predicted: [CGPoint] = []) -> [StrokePoint] {
        guard let current else { return [] }
        var controls: [Node] = []
        if let lastControl { controls.append(lastControl) }
        func push(_ node: Node) {
            if let last = controls.last, simd_length(node.p - last.p) < minSpacing * 0.5 { return }
            controls.append(node)
        }
        if settled < nodes.count {
            for index in settled..<nodes.count { push(smoothed(index)) }
        }
        push(current)
        push(Node(p: rawLast, r: current.r, a: current.a))
        for p in predicted {
            push(Node(p: SIMD2<Double>(Double(p.x), Double(p.y)), r: current.r, a: current.a))
        }
        guard let first = controls.first else { return [] }

        var out: [StrokePoint] = []
        var cursor: Node
        if let anchor {
            cursor = anchor
        } else {
            // Nothing committed yet: the tail is the whole stroke so far.
            cursor = first
            out.append(first.point)
        }
        for i in 0..<(controls.count - 1) {
            let mid = Node.mid(controls[i], controls[i + 1])
            flatten(from: cursor, control: controls[i], to: mid, into: &out)
            cursor = mid
        }
        let last = controls[controls.count - 1].point
        if out.last != last { out.append(last) }
        return out
    }

    /// Ends the stroke where the pen lifted and returns the finished polyline.
    @discardableResult
    func finish() -> [StrokePoint] {
        guard started, !finished else { return points }
        finished = true

        // Make the pen's last reported position part of the stroke.
        if let current {
            append(final: current)
            append(final: Node(p: rawLast, r: current.r, a: current.a, pressure: current.pressure))
        }
        if hookLength > 0 {
            if !startChecked {
                startChecked = true
                _ = removeStartHook()
            }
            removeEndHook()
        }
        settle(all: true)
        if let end = lastControl?.point, points.last != end {
            points.append(end)
        }
        if naturalInk {
            collapseTap()
            if dynamics.tapers { taperExit() }
        }
        return points
    }

    /// A pen that is still moving as it lifts leaves a tapered tail; one that
    /// stops first leaves a full, round end. The lift itself is too brief
    /// for the pressure sensor to describe reliably, so shape it from speed.
    private func taperExit() {
        guard points.count > 2, speed > 40 else { return }
        let length = min(3.5, speed * 0.012) / zoom                 // page units
        let floor = Float(max(0.3, 1 - (speed - 40) / 160))         // weight left at the very end
        guard length > 0, floor < 1 else { return }

        var distance: Double = 0
        var index = points.count - 1
        var reference = points[index].r
        while index > 0, distance < length {
            let a = points[index], b = points[index - 1]
            distance += Double(hypotf(a.x - b.x, a.y - b.y))
            index -= 1
            reference = max(reference, points[index].r)
        }
        var travelled: Double = 0
        for i in stride(from: points.count - 1, through: index + 1, by: -1) {
            let t = Float(min(1, travelled / length))
            let eased = t * t * (3 - 2 * t)
            points[i].r = min(points[i].r, reference * (floor + (1 - floor) * eased))
            travelled += Double(hypotf(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
    }

    private func append(final node: Node) {
        guard let last = nodes.last else { return }
        let step = simd_length(node.p - last.p)
        guard step >= minSpacing * 0.5 else { return }
        var placed = node
        placed.s = last.s + step
        nodes.append(placed)
        cornerCache.append(.nan)
    }

    /// A tap leaves a round dot sized by how firmly it was made, as a pen
    /// does, instead of a faint speck or a tiny scribble.
    private func collapseTap() {
        guard let first = nodes.first, let last = nodes.last, (last.s - first.s) * zoom < 1.6 else { return }
        let w = pow(Float(max(0.3, min(1, peakPressure))), dynamics.gamma)
        let nominal = radius * (dynamics.minScale + (dynamics.maxScale - dynamics.minScale) * w)
        let centre = nodes.reduce(SIMD2<Double>(0, 0)) { $0 + $1.p } / Double(nodes.count)
        let r = max(points.map(\.r).max() ?? 0, nominal)
        let a = max(points.map(\.a).max() ?? 0, dynamics.minAlpha + (dynamics.maxAlpha - dynamics.minAlpha) * w)
        points = [StrokePoint(x: Float(centre.x), y: Float(centre.y), r: r, a: min(1, a))]
    }

    private func flatten(from p0: Node, control c: Node, to p1: Node, into out: inout [StrokePoint]) {
        let deviation = simd_length(p0.p - 2 * c.p + p1.p)
        let count = max(1, min(24, Int((deviation / (4 * tolerance)).squareRoot().rounded(.up))))
        for i in 1...count {
            let t = Double(i) / Double(count)
            let u = 1 - t
            let w0 = u * u, w1 = 2 * u * t, w2 = t * t
            let p = p0.p * w0 + c.p * w1 + p1.p * w2
            let r = p0.r * Float(w0) + c.r * Float(w1) + p1.r * Float(w2)
            let a = p0.a * Float(w0) + c.a * Float(w1) + p1.a * Float(w2)
            out.append(StrokePoint(x: Float(p.x), y: Float(p.y), r: r, a: a))
        }
    }
}
