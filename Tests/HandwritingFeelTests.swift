import CoreGraphics
import XCTest
@testable import noteitself

/// Compares stroke pipelines on simulated glass handwriting (`SyntheticHand`).
/// All distances are in view points (1 pt ≈ 0.16–0.19 mm on an iPad).
final class HandwritingFeelTests: XCTestCase {
    struct Config {
        var name: String
        var smoothing: Double
        var paper: Double
        var natural: Bool
    }

    struct Score {
        var track = 0.0      // RMS distance of the ink from the intended path
        var worst = 0.0      // 95th percentile of that distance
        var corner = 0.0     // how far the ink misses intended corners, mean
        var ends = 0.0       // how far strokes start/end from where they were meant to, mean
        var gap = 0.0        // tip-to-ink distance while writing, 95th percentile
        var settling = 0.0   // length of ink that may still move, mean
        var stray = 0.0      // share of the ink (by area) lying off the intended path, percent
    }

    private static let zoom: CGFloat = 1.6

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        let t = length2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) : 0
        return Double(hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t)))
    }

    /// Distance to a polyline and the index of the nearest segment.
    private func nearest(_ p: CGPoint, on path: [CGPoint]) -> (distance: Double, index: Int) {
        var best = (Double.infinity, 0)
        for i in 1..<path.count {
            let d = distance(p, toSegment: path[i - 1], path[i])
            if d < best.0 { best = (d, i) }
        }
        return best
    }

    private func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    // The simulated hand lives in debug builds only.
    #if DEBUG
    private func evaluate(_ config: Config, slip: CGFloat, tempo: Double = 1, seeds: ClosedRange<UInt64> = 1...12) -> Score {
        let zoom = Double(HandwritingFeelTests.zoom)
        var deviations: [Double] = [], corners: [Double] = [], ends: [Double] = [], gaps: [Double] = [], settling: [Double] = []
        var inkArea = 0.0, strayArea = 0.0

        for seed in seeds {
            let strokes = SyntheticHand.strokes(origin: CGPoint(x: 40, y: 100), xHeight: 9, zoom: HandwritingFeelTests.zoom,
                                                slip: slip, seed: seed, tempo: tempo)
            for stroke in strokes where !stroke.isTap {
                let builder = StrokeBuilder(kind: .pen, radius: 0.65, smoothing: config.smoothing, zoom: zoom,
                                            paper: config.paper, naturalInk: config.natural)
                for sample in stroke.samples {
                    builder.add(sample)
                    gaps.append(builder.followGap)
                    settling.append(builder.provisionalLength)
                }
                let finished = builder.finish()
                let ink = finished.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                guard ink.count > 1, let first = ink.first, let last = ink.last else { continue }

                // Ink area (length × width) and how much of it sits clearly off the intended path.
                for i in 1..<finished.count {
                    let a = finished[i - 1], b = finished[i]
                    let area = Double(hypotf(b.x - a.x, b.y - a.y) * (a.r + b.r))
                    let middle = CGPoint(x: CGFloat(a.x + b.x) / 2, y: CGFloat(a.y + b.y) / 2)
                    inkArea += area
                    if nearest(middle, on: stroke.ideal).distance * zoom > 0.45 { strayArea += area }
                }

                for p in ink {
                    let hit = nearest(p, on: stroke.ideal)
                    // The first and last few percent are judged by `ends`.
                    if hit.index > 12, hit.index < stroke.ideal.count - 12 { deviations.append(hit.distance * zoom) }
                }
                for corner in stroke.corners {
                    corners.append(nearest(corner, on: ink).distance * zoom)
                }
                ends.append(Double(hypot(first.x - stroke.ideal[0].x, first.y - stroke.ideal[0].y)) * zoom)
                let target = stroke.ideal[stroke.ideal.count - 1]
                ends.append(Double(hypot(last.x - target.x, last.y - target.y)) * zoom)
            }
        }

        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return Score(
            track: (deviations.reduce(0) { $0 + $1 * $1 } / Double(max(deviations.count, 1))).squareRoot(),
            worst: percentile(deviations, 0.95),
            corner: mean(corners), ends: mean(ends),
            gap: percentile(gaps, 0.95), settling: mean(settling),
            stray: inkArea > 0 ? 100 * strayArea / inkArea : 0
        )
    }

    private let configs = [
        Config(name: "raw input", smoothing: 0, paper: 0, natural: false),
        Config(name: "smoothing 25% (old default)", smoothing: 0.25, paper: 0, natural: false),
        Config(name: "smoothing 50%", smoothing: 0.5, paper: 0, natural: false),
        Config(name: "smoothing 80%", smoothing: 0.8, paper: 0, natural: false),
        Config(name: "paper 60% + smoothing 10% (new default)", smoothing: 0.1, paper: 0.6, natural: true),
        Config(name: "paper 100% + smoothing 10%", smoothing: 0.1, paper: 1.0, natural: true),
        Config(name: "paper 60%, no smoothing", smoothing: 0, paper: 0.6, natural: true),
    ]

    private func table(_ title: String, slip: CGFloat, tempo: Double) -> [String: Score] {
        var scores: [String: Score] = [:]
        print("FEEL  \(title)")
        print("FEEL    pipeline                                   track   p95  corner   ends  stray%  tip-gap  settling")
        for config in configs {
            let s = evaluate(config, slip: slip, tempo: tempo)
            scores[config.name] = s
            print(String(format: "FEEL    %@ %5.2f %5.2f  %5.2f  %5.2f  %5.1f   %5.2f    %5.2f",
                         config.name.padding(toLength: 42, withPad: " ", startingAt: 0),
                         s.track, s.worst, s.corner, s.ends, s.stray, s.gap, s.settling))
        }
        return scores
    }

    func testPaperFeelOnGlass() {
        let brisk = table("brisk handwriting on glass (distances in view pt)", slip: 1, tempo: 1)
        let careful = table("slow, careful writing on glass", slip: 1, tempo: 4)
        let perfect = table("a perfect hand: nothing to fix, nothing should change", slip: 0, tempo: 1)

        let newName = "paper 60% + smoothing 10% (new default)", oldName = "smoothing 25% (old default)"
        guard let raw = brisk["raw input"], let old = brisk[oldName], let heavy = brisk["smoothing 80%"], let new = brisk[newName],
              let carefulRaw = careful["raw input"], let carefulOld = careful[oldName], let carefulNew = careful[newName],
              let idealRaw = perfect["raw input"], let ideal = perfect[newName] else {
            return XCTFail("missing scores")
        }

        // Brisk writing: far less stray ink (skids, overshoot loops), corners
        // as sharp as the raw input, and the ink closer to the tip than before.
        XCTAssertLessThan(new.stray, old.stray * 0.6)
        XCTAssertLessThan(new.ends, old.ends * 0.75)
        XCTAssertLessThanOrEqual(new.corner, raw.corner + 0.08)
        XCTAssertLessThan(new.corner, heavy.corner * 0.5)
        XCTAssertLessThan(new.gap, old.gap)
        XCTAssertLessThanOrEqual(new.track, old.track)

        // Careful writing: this is where a shaky line shows, and where the
        // settling average can remove tremor without any lag.
        XCTAssertLessThan(carefulNew.track, carefulRaw.track * 0.75)
        XCTAssertLessThan(carefulNew.track, carefulOld.track * 0.8)

        // A hand that needed no help is left alone.
        XCTAssertLessThan(ideal.track, 0.1)
        // (Friction lets the ink round a sharp corner by a fraction of its grip:
        // under 0.2 pt, about a third of a pixel.)
        XCTAssertLessThanOrEqual(ideal.corner, idealRaw.corner + 0.2)
    }
    #endif

    func testNaturalInkTerminalsAndDots() {
        func build(_ samples: [InputSample], natural: Bool) -> [StrokePoint] {
            let builder = StrokeBuilder(kind: .pen, radius: 1, smoothing: 0.15, zoom: 1, paper: 0.6, naturalInk: natural)
            samples.forEach(builder.add)
            return builder.finish()
        }
        // A 60 pt line: pressure rises over the landing and falls over the lift.
        let line = (0..<120).map { i -> InputSample in
            let landing = min(1, Double(i) / 6), lift = min(1, Double(119 - i) / 6)
            return InputSample(position: CGPoint(x: Double(i) * 0.5, y: 0), pressure: CGFloat(0.5 * landing * lift),
                               altitude: .pi / 2, time: Double(i) / 240)
        }
        let natural = build(line, natural: true), classic = build(line, natural: false)
        let middle = natural[natural.count / 2].r
        XCTAssertLessThan(natural.first!.r, middle * 0.35, "the stroke starts as a hairline")
        XCTAssertLessThan(natural.last!.r, middle * 0.55, "and thins as the tip lifts")
        XCTAssertGreaterThan(classic.first!.r, classic[classic.count / 2].r * 0.6, "classic ink starts blunt")
        XCTAssertEqual(middle, 1, accuracy: 0.2, "full weight in between")

        // A quick tap: a few samples, barely any pressure registered at first.
        let tap = (0..<5).map { i in
            InputSample(position: CGPoint(x: 10 + Double(i) * 0.05, y: 10), pressure: CGFloat([0.0, 0.2, 0.45, 0.3, 0.05][i]),
                        altitude: .pi / 2, time: Double(i) / 240)
        }
        let dot = build(tap, natural: true)
        XCTAssertEqual(dot.count, 1, "a tap is one round dot")
        XCTAssertGreaterThan(dot[0].r, 0.8, "big enough to read as a full stop or the dot of an i")
    }

    func testSkidsAreRemovedButDeliberateStrokesAreKept() {
        func ink(_ samples: [InputSample]) -> [CGPoint] {
            let builder = StrokeBuilder(kind: .pen, radius: 0.65, smoothing: 0, zoom: 1, paper: 0.6, naturalInk: true)
            samples.forEach(builder.add)
            return builder.finish().map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        }
        func sample(_ x: Double, _ y: Double, _ pressure: Double, _ i: Int) -> InputSample {
            InputSample(position: CGPoint(x: x, y: y), pressure: CGFloat(pressure), altitude: .pi / 2, time: Double(i) / 240)
        }

        // A horizontal line with a light 1.5 pt skid before and after, both doubling back sharply.
        var skidding: [InputSample] = []
        for i in 0..<4 { skidding.append(sample(1.0 - Double(i) * 0.33, -1.2 + Double(i) * 0.4, 0.02 + 0.03 * Double(i), i)) }
        for i in 0..<80 { skidding.append(sample(Double(i) * 0.5, 0, 0.45, 4 + i)) }
        for i in 0..<5 { skidding.append(sample(39.5 - Double(i + 1) * 0.25, Double(i + 1) * 0.3, 0.3 * pow(1 - Double(i + 1) / 5, 1.5), 84 + i)) }
        let cleaned = ink(skidding)
        XCTAssertLessThan(abs(cleaned.first!.y), 0.2, "landing skid removed")
        XCTAssertLessThan(abs(cleaned.last!.y), 0.2, "lift skid removed")
        XCTAssertGreaterThan(cleaned.last!.x, 38.5, "the stroke keeps its full length")

        // The same shape drawn with pressure throughout is deliberate (a serif, a tick): kept.
        let deliberate = ink(skidding.map { var s = $0; s.pressure = 0.45; return s })
        XCTAssertGreaterThan(abs(deliberate.first!.y), 0.8)
        XCTAssertGreaterThan(abs(deliberate.last!.y), 0.8)

        // A long tick at the end of a stroke (a check mark) is far beyond skid length: kept.
        var check: [InputSample] = []
        for i in 0..<40 { check.append(sample(Double(i) * 0.3, Double(i) * 0.3, 0.45, i)) }
        for i in 1...60 { check.append(sample(12 + Double(i) * 0.3, 12 - Double(i) * 0.45, 0.45 * (i > 54 ? Double(60 - i) / 6 : 1), 40 + i)) }
        let mark = ink(check)
        XCTAssertLessThan(mark.last!.y, -12, "the long upstroke survives")
    }
}
