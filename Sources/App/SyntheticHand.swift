#if DEBUG
import CoreGraphics
import Foundation

/// Simulated handwriting on glass, for comparing stroke pipelines without a
/// hand in the loop. Each stroke has a clean intended path, traced with a
/// plausible speed and pressure profile at 240 Hz, plus the artefacts a
/// low-friction surface adds:
///
///  - physiological tremor (7–12 Hz) that nothing damps,
///  - overshoot and a tiny loop at every sharp change of direction,
///  - a skid as the tip lands and another as it lifts, at low pressure,
///  - a little sensor noise.
///
/// `slip` scales all of them: 0 is an ideal hand on an ideal surface.
/// This is a model, not a recording; it is good for ranking pipelines, not for
/// claiming how they feel.
enum SyntheticHand {
    struct Stroke {
        var samples: [InputSample]
        /// The path the writer meant to draw, densely sampled.
        var ideal: [CGPoint]
        /// Intended sharp corners.
        var corners: [CGPoint]
        var isTap: Bool
    }

    private struct Shape {
        var duration: Double
        /// Parameters at which the pen sharply changes direction.
        var stops: [Double] = []
        var offset: CGPoint
        var isTap = false
        /// Position in x-heights (y down) for a parameter in 0…1.
        var path: (Double) -> CGPoint
    }

    private static func polyline(_ vertices: [(Double, Double)], _ u: Double) -> CGPoint {
        let scaled = max(0, min(1, u)) * Double(vertices.count - 1)
        let i = min(Int(scaled), vertices.count - 2)
        let t = scaled - Double(i)
        return CGPoint(x: vertices[i].0 + (vertices[i + 1].0 - vertices[i].0) * t,
                       y: vertices[i].1 + (vertices[i + 1].1 - vertices[i].1) * t)
    }

    private static let shapes: [Shape] = [
        // Cursive loops, as in "elle": smooth, no corners.
        Shape(duration: 1.15, offset: CGPoint(x: 0, y: 0)) { u in
            let t = u * 6 * .pi
            return CGPoint(x: 0.30 * t - 0.45 * sin(t), y: -0.5 * (1 - cos(t)))
        },
        // Zigzag, as in "w": sharp angles.
        Shape(duration: 0.62, stops: [0.25, 0.5, 0.75], offset: CGPoint(x: 6.6, y: 0)) { u in
            polyline([(0, -1), (0.35, 0), (0.7, -0.8), (1.05, 0), (1.4, -1)], u)
        },
        // Stem and two arches, as in "m": cusps where the pen retraces.
        Shape(duration: 0.95, stops: [0.2, 0.6], offset: CGPoint(x: 8.7, y: 0)) { u in
            if u < 0.2 { return CGPoint(x: 0, y: -1 + u / 0.2) }
            let second = u >= 0.6
            let t = (u - (second ? 0.6 : 0.2)) / 0.4
            return CGPoint(x: (second ? 0.55 : 0) + 0.55 * (t - sin(2 * .pi * t) / (2 * .pi)),
                           y: -0.95 * pow(max(0, sin(.pi * t)), 0.6))
        },
        // Stem and bar of a "t", and a dot.
        Shape(duration: 0.20, offset: CGPoint(x: 10.9, y: 0)) { u in CGPoint(x: 0, y: -1.5 + 1.5 * u) },
        Shape(duration: 0.13, offset: CGPoint(x: 10.9, y: 0)) { u in CGPoint(x: -0.3 + 0.65 * u, y: -1.0) },
        Shape(duration: 0.03, offset: CGPoint(x: 11.6, y: 0), isTap: true) { u in CGPoint(x: 0.02 * u, y: -1.4) },
        // A long, nearly straight underline.
        Shape(duration: 0.55, offset: CGPoint(x: 0, y: 0)) { u in CGPoint(x: 9 * u, y: 0.5 + 0.12 * sin(.pi * u)) },
    ]

    /// Width of the sample in x-heights.
    static let width: CGFloat = 12

    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    /// Speed profile between two stops: mostly minimum-jerk, never quite stopping.
    private static func ease(_ t: Double) -> Double {
        0.7 * (10 * pow(t, 3) - 15 * pow(t, 4) + 6 * pow(t, 5)) + 0.3 * t
    }

    /// - Parameter tempo: 1 is brisk handwriting; larger is slower, more careful writing.
    static func strokes(origin: CGPoint, xHeight: CGFloat, zoom: CGFloat, slip: CGFloat, seed: UInt64 = 7, tempo: Double = 1) -> [Stroke] {
        var random = Random(state: seed)
        let rate = 240.0
        // Artefact sizes are set in view points (what the hand does on the glass).
        let unit = Double(slip) / Double(zoom)

        return shapes.map { shape in
            func place(_ u: Double) -> CGPoint {
                let p = shape.path(u)
                return CGPoint(x: origin.x + (shape.offset.x + p.x) * xHeight, y: origin.y + (shape.offset.y + p.y) * xHeight)
            }
            let bounds = [0.0] + shape.stops + [1.0]
            let duration = shape.isTap ? shape.duration : shape.duration * tempo
            let count = max(2, Int(duration * rate))

            // Parameter and time of every sample of the intended movement.
            func parameter(_ k: Int) -> Double {
                let progress = Double(k) / Double(count - 1)
                for i in 0..<(bounds.count - 1) where progress <= bounds[i + 1] || i == bounds.count - 2 {
                    let span = bounds[i + 1] - bounds[i]
                    return bounds[i] + span * ease(max(0, min(1, (progress - bounds[i]) / span)))
                }
                return 1
            }
            let stopTimes = shape.stops.map { $0 * duration }

            let phases = (0..<6).map { _ in random.next() * 2 * .pi }
            let frequencies = [7.3, 9.6, 11.8]
            let pressurePhase = random.next() * 2 * .pi

            func direction(at u: Double) -> CGPoint {
                let a = place(max(0, u - 0.01)), b = place(min(1, u + 0.01))
                let length = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
                return CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            }
            func rotate(_ v: CGPoint, degrees: Double) -> CGPoint {
                let r = degrees * .pi / 180
                return CGPoint(x: v.x * cos(r) - v.y * sin(r), y: v.x * sin(r) + v.y * cos(r))
            }

            var samples: [InputSample] = []
            let landing = shape.isTap || slip <= 0 ? 0 : 4
            let lifting = shape.isTap || slip <= 0 ? 0 : 6
            let start = place(0), end = place(1)

            // Skid as the tip lands.
            let side = random.next() < 0.5 ? -1.0 : 1.0
            let approach = rotate(direction(at: 0), degrees: side * (40 + 110 * random.next()))
            for j in 0..<landing {
                let far = 1.4 * unit * (1 - (Double(j) + 0.5) / Double(landing))
                samples.append(InputSample(
                    position: CGPoint(x: start.x + approach.x * far, y: start.y + approach.y * far),
                    pressure: 0.02 + 0.04 * Double(j), altitude: .pi / 3, time: Double(j) / rate
                ))
            }

            var lastPlateau = 0.4
            for k in 0..<count {
                let t = Double(k) / rate
                var p = place(parameter(k))
                if !shape.isTap {
                    // Tremor and sensor noise.
                    for (i, f) in frequencies.enumerated() {
                        p.x += 0.16 * unit * sin(2 * .pi * f * t + phases[i])
                        p.y += 0.16 * unit * sin(2 * .pi * f * t + phases[i + 3])
                    }
                    p.x += 0.03 * unit * (random.next() * 2 - 1)
                    p.y += 0.03 * unit * (random.next() * 2 - 1)
                    // Nothing brakes the tip at a corner: it runs on and loops back.
                    for (i, stopTime) in stopTimes.enumerated() {
                        let phase = (t - stopTime - 0.004) / 0.009
                        let bump = exp(-phase * phase)
                        let incoming = direction(at: max(0, shape.stops[i] - 0.02))
                        let side = CGPoint(x: -incoming.y, y: incoming.x)
                        p.x += 0.55 * unit * bump * (incoming.x + 0.45 * phase * side.x)
                        p.y += 0.55 * unit * bump * (incoming.y + 0.45 * phase * side.y)
                    }
                }
                var pressure = 0.42 + 0.08 * sin(2 * .pi * 1.3 * t + pressurePhase)
                if shape.isTap {
                    pressure = 0.5 * sin(.pi * (Double(k) + 0.5) / Double(count))
                } else {
                    if k < 5 { pressure *= 0.12 + 0.88 * Double(k) / 5 }
                    let fromEnd = count - 1 - k
                    if fromEnd < 4 { pressure *= 1 - 0.4 * Double(4 - fromEnd) / 4 }
                }
                lastPlateau = pressure
                samples.append(InputSample(position: p, pressure: pressure, altitude: .pi / 3, time: Double(landing + k) / rate))
            }

            // Skid as the tip lifts.
            let departure = rotate(direction(at: 1), degrees: -side * (50 + 110 * random.next()))
            for j in 0..<lifting {
                let progress = Double(j + 1) / Double(lifting)
                let far = 1.8 * unit * pow(progress, 1.2)
                samples.append(InputSample(
                    position: CGPoint(x: end.x + departure.x * far, y: end.y + departure.y * far),
                    pressure: lastPlateau * pow(1 - progress, 1.5) + 0.01, altitude: .pi / 3,
                    time: Double(landing + count + j) / rate
                ))
            }

            return Stroke(
                samples: samples,
                ideal: (0...400).map { place(Double($0) / 400) },
                corners: shape.stops.map(place),
                isTap: shape.isTap
            )
        }
    }
}
#endif
