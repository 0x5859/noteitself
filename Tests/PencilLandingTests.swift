import CoreGraphics
import XCTest
@testable import noteitself

/// How a stroke begins with a real Apple Pencil.
///
/// Until the Pencil's first measurement arrives over Bluetooth, UIKit reports
/// a placeholder force: the same constant (1/3) at the start of every stroke,
/// whatever the hand is doing. Strokes recorded on an iPad all began at the
/// width for that force; with a wide brush and a light hand that was a blob
/// up to 30 times wider than the line.
final class PencilLandingTests: XCTestCase {
    private static let placeholder: CGFloat = 1.0 / 3

    /// What UIKit delivers for a light stroke: (force, update still expected).
    private func lightStroke(placeholders: Int, force: CGFloat = 0.04, count: Int = 120) -> [(CGFloat, Bool)] {
        (0..<count).map { i in
            if i < placeholders { return (PencilLandingTests.placeholder, true) }
            // The real force builds over a few samples, then holds, with sensor noise.
            let ramp = min(1, CGFloat(i - placeholders + 1) / 4)
            return (force * ramp * (1 + 0.05 * sin(CGFloat(i))), i > count - 3)
        }
    }

    private func draw(_ tool: Tool, width: Double, forces: [(CGFloat, Bool)]) -> [StrokePoint] {
        let settings = ToolSettings.defaults(for: tool)
        let zoom = 1.0
        let builder = StrokeBuilder(kind: tool.brush!, radius: Float(width / 2), smoothing: settings.smoothing,
                                    zoom: zoom, paper: settings.paper, naturalInk: settings.naturalInk)
        var pencil = PencilForce()
        for (i, (force, expectsUpdate)) in forces.enumerated() {
            // Rests for 20 ms, then writes at about 150 pt/s. Uptime timestamps.
            let moving = Double(max(0, i - 5))
            builder.add(InputSample(
                position: CGPoint(x: 100 + moving * 150 / 240, y: 200 + sin(moving / 12) * 3),
                pressure: pencil.pressure(force: force, expectsUpdate: expectsUpdate),
                altitude: 1.0, time: 512_345.678 + Double(i) / 240
            ))
        }
        return builder.finish()
    }

    private func startToBody(_ points: [StrokePoint]) -> Float {
        let radii = points.map(\.r)
        let body = radii[(radii.count / 3)..<(radii.count * 2 / 3)].sorted()
        return (radii.prefix(4).max() ?? 0) / body[body.count / 2]
    }

    func testStrokeDoesNotStartWithABlob() {
        for (tool, width) in [(Tool.brush, 24.0), (.brush, 4), (.pen, 6), (.pen, 1.3), (.pencil, 1.8)] {
            for placeholders in [1, 2, 5] {
                let points = draw(tool, width: width, forces: lightStroke(placeholders: placeholders))
                XCTAssertLessThanOrEqual(startToBody(points), 1.25,
                                         "\(tool.rawValue) \(width) pt, \(placeholders) placeholder samples")
            }
        }
    }

    func testPlaceholderForceIsNotPressure() {
        var pencil = PencilForce()
        XCTAssertEqual(pencil.pressure(force: PencilLandingTests.placeholder, expectsUpdate: true), 0)
        XCTAssertEqual(pencil.pressure(force: PencilLandingTests.placeholder, expectsUpdate: true), 0)
        // The first value that differs is a measurement, and so is everything after it.
        XCTAssertEqual(pencil.pressure(force: 0.09, expectsUpdate: true), 0.05, accuracy: 1e-6)
        XCTAssertEqual(pencil.pressure(force: PencilLandingTests.placeholder, expectsUpdate: true),
                       PencilLandingTests.placeholder / PencilForce.fullScale, accuracy: 1e-6)
        XCTAssertEqual(pencil.pressure(force: 9, expectsUpdate: false), 1)
    }

    /// A stylus without a pressure sensor may report one force throughout.
    /// It must not be mistaken for a placeholder forever.
    func testConstantForceIsAcceptedAfterAMoment() {
        var pencil = PencilForce()
        let pressures = (0..<40).map { _ in pencil.pressure(force: 0.9, expectsUpdate: false) }
        XCTAssertEqual(pressures.first, 0)
        XCTAssertEqual(pressures.last ?? 0, 0.5, accuracy: 1e-6)
        XCTAssertLessThan(pressures.firstIndex { $0 > 0 } ?? 99, 12)
    }

    /// While UIKit still promises the real value, keep waiting for it.
    func testKeepsWaitingWhileAnUpdateIsPromised() {
        var pencil = PencilForce()
        let pressures = (0..<40).map { _ in pencil.pressure(force: PencilLandingTests.placeholder, expectsUpdate: true) }
        XCTAssertEqual(pressures.max(), 0)
    }
}
