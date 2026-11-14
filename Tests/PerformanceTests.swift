import Metal
import XCTest
@testable import noteitself

/// CPU-side costs of the ink pipeline on a dense page. Run in Release for
/// meaningful numbers:
///
///     xcodebuild test -scheme noteitself -configuration Release ENABLE_TESTABILITY=YES \
///         -only-testing:noteitselfTests/PerformanceTests …
///
/// The limits are loose on purpose; they exist to catch order-of-magnitude
/// regressions, and the measured values are printed.
final class PerformanceTests: XCTestCase {
    /// Roughly a full page of small handwriting.
    private func handwriting(strokes count: Int) -> [Stroke] {
        (0..<count).map { i in
            // The default pen: paper feel on, natural ink.
            let builder = StrokeBuilder(kind: .pen, radius: 0.65, smoothing: 0.1, zoom: 1.6, paper: 0.6, naturalInk: true)
            let x0 = 40 + CGFloat(i % 64) * 8
            let y0 = 50 + CGFloat(i / 64) * 12
            for s in 0..<60 {   // a quarter second of Pencil samples
                let t = Double(s) / 60
                builder.add(InputSample(
                    position: CGPoint(x: x0 + 5 * t + 2.5 * sin(t * 9), y: y0 + 4 * cos(t * 7)),
                    pressure: CGFloat(0.4 + 0.3 * sin(t * 6)), altitude: .pi / 2, time: Double(s) / 240
                ))
                // What the canvas does every frame while writing.
                if s % 2 == 0 { _ = builder.tailPoints(predicted: [CGPoint(x: x0 + 5 * t + 1, y: y0)]) }
            }
            return Stroke(brush: .pen, color: .black, points: builder.finish())
        }
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        work()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    func testDensePageCosts() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

        var strokes: [Stroke] = []
        let build = milliseconds { strokes = handwriting(strokes: 4000) }
        let samples = 4000 * 60
        let points = strokes.reduce(0) { $0 + $1.points.count }
        print(String(format: "PERF smoothing: %.2f µs per input sample (%d samples → %d points)",
                     build * 1000 / Double(samples), samples, points))

        let mesh = LayerMesh(device: device)
        let rebuild = milliseconds { mesh.rebuild(from: strokes) }
        print(String(format: "PERF mesh rebuild: %.2f ms for %d strokes, %d segments", rebuild, strokes.count, mesh.capsules.count))

        let append = milliseconds { for stroke in strokes.prefix(200) { mesh.append(stroke) } } / 200
        print(String(format: "PERF mesh append: %.1f µs per stroke", append * 1000))

        // One eraser movement: a short sweep across the middle of the page.
        var remaining = strokes
        var passes = 0
        let erase = milliseconds {
            for step in 0..<120 {
                let cx = Float(100 + step * 3), cy = Float(300 + (step % 7))
                var out: [Stroke]?
                for (i, stroke) in remaining.enumerated() {
                    if let pieces = Eraser.cut(stroke, cx: cx, cy: cy, radius: 6) {
                        if out == nil { out = Array(remaining[..<i]) }
                        out?.append(contentsOf: pieces)
                    } else {
                        out?.append(stroke)
                    }
                }
                if let out { remaining = out }
                passes += 1
            }
        } / 120
        print(String(format: "PERF eraser: %.1f µs per eraser position over %d strokes", erase * 1000, strokes.count))
        XCTAssertNotEqual(remaining.count, strokes.count, "the sweep should have cut something")

        let layer = Layer(name: "Ink", strokes: strokes)
        var data = Data()
        let encode = milliseconds { data = PageCodec.encode([layer]) }
        var decoded: [Layer] = []
        let decode = milliseconds { decoded = (try? PageCodec.decode(data)) ?? [] }
        print(String(format: "PERF file: %.1f ms to encode, %.1f ms to decode, %d KB on disk (%.1f bytes per point)",
                     encode, decode, data.count / 1024, Double(data.count) / Double(points)))
        XCTAssertEqual(decoded.first?.strokes.count, strokes.count)

        #if !DEBUG
        XCTAssertLessThan(build * 1000 / Double(samples), 5, "smoothing must be far below the 4 ms between Pencil samples")
        XCTAssertLessThan(rebuild, 40)
        XCTAssertLessThan(erase, 2)
        #endif
    }
}
