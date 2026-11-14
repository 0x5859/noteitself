import CoreGraphics
import UIKit
import XCTest
@testable import noteitself

private func line(from a: CGPoint, to b: CGPoint, samples: Int = 120, pressure: CGFloat = 0.5, noise: CGFloat = 0) -> [InputSample] {
    (0..<samples).map { i in
        let t = CGFloat(i) / CGFloat(samples - 1)
        // Deterministic pseudo-noise perpendicular-ish to the path.
        let wobble = noise * CGFloat(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        return InputSample(
            position: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + wobble),
            pressure: pressure, altitude: .pi / 2, time: Double(i) / 240
        )
    }
}

private func build(_ samples: [InputSample], kind: BrushKind = .pen, radius: Float = 1, smoothing: Double = 0.25) -> [StrokePoint] {
    let builder = StrokeBuilder(kind: kind, radius: radius, smoothing: smoothing, zoom: 1)
    samples.forEach(builder.add)
    return builder.finish()
}

private func straight(_ y: Float, from x0: Float = 0, to x1: Float = 100, r: Float = 1, brush: BrushKind = .pen) -> Stroke {
    let points = stride(from: x0, through: x1, by: 2).map { StrokePoint(x: $0, y: y, r: r, a: 1) }
    return Stroke(brush: brush, color: .black, points: points)
}

final class StrokeBuilderTests: XCTestCase {
    func testStrokeStartsAndEndsAtThePen() {
        let points = build(line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 210, y: 80)))
        XCTAssertGreaterThan(points.count, 10)
        XCTAssertEqual(points.first!.x, 10, accuracy: 0.01)
        XCTAssertEqual(points.first!.y, 20, accuracy: 0.01)
        // Smoothing lags behind the pen; finishing must still reach the lift point.
        XCTAssertEqual(points.last!.x, 210, accuracy: 0.01)
        XCTAssertEqual(points.last!.y, 80, accuracy: 0.01)
    }

    func testStraightInputStaysStraightAndOrdered() {
        let points = build(line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 300, y: 50)))
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.x, a.x - 0.001)
        }
        XCTAssertLessThan(points.map { abs($0.y - 50) }.max()!, 0.01)
    }

    func testSmoothingReducesJitter() {
        let noisy = line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 120, y: 50), samples: 240, noise: 0.8)
        func roughness(_ points: [StrokePoint]) -> Float {
            // Total vertical travel: a jittery line goes up and down a lot.
            zip(points, points.dropFirst()).reduce(0) { $0 + abs($1.1.y - $1.0.y) }
        }
        let raw = roughness(build(noisy, smoothing: 0))
        let light = roughness(build(noisy, smoothing: 0.3))
        let heavy = roughness(build(noisy, smoothing: 0.9))
        XCTAssertLessThan(light, raw * 0.8)
        XCTAssertLessThan(heavy, light * 0.6)
    }

    func testPressureWidensPenAndStaysInRange() {
        let soft = build(line(from: .zero, to: CGPoint(x: 100, y: 0), pressure: 0.1), radius: 2)
        let hard = build(line(from: .zero, to: CGPoint(x: 100, y: 0), pressure: 0.9), radius: 2)
        let softMid = soft[soft.count / 2].r, hardMid = hard[hard.count / 2].r
        XCTAssertGreaterThan(hardMid, softMid * 1.2)
        for p in soft + hard {
            XCTAssertGreaterThan(p.r, 0.5)
            XCTAssertLessThan(p.r, 3)
        }
    }

    func testMarkerIgnoresPressure() {
        let points = build(line(from: .zero, to: CGPoint(x: 100, y: 0), pressure: 0.9), kind: .marker, radius: 3)
        XCTAssertTrue(points.allSatisfy { abs($0.r - 3) < 0.001 })
    }

    func testCurvesAreFlattenedWithinTolerance() {
        // A circle of radius 40: every output point must stay close to it.
        let samples = (0..<400).map { i -> InputSample in
            let a = Double(i) / 399 * 2 * .pi
            return InputSample(position: CGPoint(x: 100 + 40 * cos(a), y: 100 + 40 * sin(a)), pressure: 0.5, altitude: .pi / 2, time: Double(i) / 240)
        }
        let points = build(samples, smoothing: 0)
        let worst = points.map { abs(hypot(Double($0.x) - 100, Double($0.y) - 100) - 40) }.max()!
        XCTAssertLessThan(worst, 0.15)
        XCTAssertGreaterThan(points.count, 100)
    }

    func testTapMakesADot() {
        let builder = StrokeBuilder(kind: .pen, radius: 1, smoothing: 0.25, zoom: 1)
        builder.add(InputSample(position: CGPoint(x: 5, y: 5), pressure: 0.4, altitude: .pi / 2, time: 0))
        let points = builder.finish()
        XCTAssertEqual(points.count, 1)
        var instances: [CapsuleInstance] = []
        MeshBuilder.appendCapsules(points, color: 0, into: &instances)
        XCTAssertEqual(instances.count, 1)
    }

    func testTailReachesPredictedPosition() {
        let builder = StrokeBuilder(kind: .pen, radius: 1, smoothing: 0.25, zoom: 1)
        line(from: .zero, to: CGPoint(x: 50, y: 0), samples: 60).forEach(builder.add)
        let tail = builder.tailPoints(predicted: [CGPoint(x: 54, y: 0), CGPoint(x: 58, y: 0)])
        XCTAssertEqual(tail.last!.x, 58, accuracy: 0.01)
        // Asking for the tail must not commit anything.
        let count = builder.points.count
        _ = builder.tailPoints(predicted: [CGPoint(x: 70, y: 0)])
        XCTAssertEqual(builder.points.count, count)
    }
}

final class EraserTests: XCTestCase {
    func testMissLeavesStrokeUntouched() {
        XCTAssertNil(Eraser.cut(straight(0), cx: 50, cy: 30, radius: 5))
        XCTAssertFalse(Eraser.hits(straight(0), cx: 50, cy: 30, radius: 5))
    }

    func testCutSplitsStrokeExactlyAtTheEraserEdge() {
        let pieces = Eraser.cut(straight(0), cx: 51, cy: 0, radius: 5)
        XCTAssertEqual(pieces?.count, 2)
        guard let left = pieces?.first, let right = pieces?.last else { return }
        XCTAssertEqual(left.points.first!.x, 0, accuracy: 0.001)
        XCTAssertEqual(left.points.last!.x, 46, accuracy: 0.001)
        XCTAssertEqual(right.points.first!.x, 56, accuracy: 0.001)
        XCTAssertEqual(right.points.last!.x, 100, accuracy: 0.001)
        XCTAssertEqual(left.brush, .pen)
    }

    func testCutBetweenSparseSamples() {
        // Two points 100 apart; the eraser sits between them, touching neither.
        let stroke = Stroke(brush: .pen, color: .black, points: [
            StrokePoint(x: 0, y: 0, r: 1, a: 1), StrokePoint(x: 100, y: 0, r: 1, a: 1),
        ])
        let pieces = Eraser.cut(stroke, cx: 50, cy: 0, radius: 4)
        XCTAssertEqual(pieces?.count, 2)
        XCTAssertEqual(pieces?.first?.points.last?.x ?? 0, 46, accuracy: 0.001)
        XCTAssertEqual(pieces?.last?.points.first?.x ?? 0, 54, accuracy: 0.001)
    }

    func testErasingAnEndTrimsIt() {
        let pieces = Eraser.cut(straight(0), cx: 0, cy: 0, radius: 7)
        XCTAssertEqual(pieces?.count, 1)
        XCTAssertEqual(pieces?.first?.points.first?.x ?? 0, 7, accuracy: 0.001)
    }

    func testCoveringEraserRemovesEverything() {
        XCTAssertEqual(Eraser.cut(straight(0, from: 0, to: 10), cx: 5, cy: 0, radius: 20)?.count, 0)
    }

    func testStrokeEraserHitsWithinStrokeWidth() {
        let fat = straight(0, r: 4)
        XCTAssertTrue(Eraser.hits(fat, cx: 50, cy: 6, radius: 3))
        XCTAssertFalse(Eraser.hits(fat, cx: 50, cy: 8, radius: 3))
    }
}

final class StorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noteitself-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testPageCodecRoundTrip() throws {
        var ink = Layer(name: "Ink ✍️", strokes: [straight(3), straight(9, r: 2.5, brush: .highlighter)])
        ink.opacity = 0.4
        ink.isVisible = false
        let image = Layer(name: "Photo", image: ImageRef(asset: "a.png", frame: CGRect(x: 1.5, y: -2, width: 300, height: 200)))

        let data = PageCodec.encode([image, ink])
        let decoded = try PageCodec.decode(data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, image.id)
        XCTAssertEqual(decoded[0].image, image.image)
        XCTAssertEqual(decoded[1].name, "Ink ✍️")
        XCTAssertEqual(decoded[1].opacity, 0.4, accuracy: 0.0001)
        XCTAssertFalse(decoded[1].isVisible)
        XCTAssertEqual(decoded[1].strokes.count, 2)
        XCTAssertEqual(decoded[1].strokes[0].points, ink.strokes[0].points)
        XCTAssertEqual(decoded[1].strokes[1].brush, .highlighter)
        XCTAssertEqual(decoded[1].strokes[1].color, ink.strokes[1].color)
        XCTAssertEqual(decoded[1].strokes[1].bounds, ink.strokes[1].bounds)
    }

    func testCodecRejectsGarbage() {
        XCTAssertThrowsError(try PageCodec.decode(Data([1, 2, 3])))
        XCTAssertThrowsError(try PageCodec.decode(Data("SUMI\u{1}\u{0}".utf8) + Data([9, 0, 1])))
    }

    func testDocumentSurvivesSaveAndReopen() throws {
        let library = Library(root: root)
        let item = try library.create(kind: .notebook)
        XCTAssertEqual(library.items.count, 1)

        let document = try NoteDocument(url: item.url)
        let session = EditorSession(document: document)
        session.commit(straight(10), pageIndex: 0)
        session.commit(straight(20), pageIndex: 0)
        session.addPage()
        session.commit(straight(30, brush: .pencil), pageIndex: 1)
        session.close()

        let reopened = try NoteDocument(url: item.url)
        XCTAssertEqual(reopened.pages.count, 2)
        reopened.pages.forEach(reopened.ensureLoaded)
        XCTAssertEqual(reopened.pages[0].layers.first?.strokes.count, 2)
        XCTAssertEqual(reopened.pages[1].layers.first?.strokes.first?.brush, .pencil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.thumbnailURL.path))
    }

    func testUndoRedoAndErase() throws {
        let library = Library(root: root)
        let document = try NoteDocument(url: try library.create(kind: .canvas).url)
        let session = EditorSession(document: document)
        // Tool preferences persist between launches; pin the mode under test.
        let savedMode = session.box.eraserMode
        session.box.eraserMode = .precise
        defer { session.box.eraserMode = savedMode }
        func strokeCount() -> Int { session.layers.reduce(0) { $0 + $1.strokes.count } }

        session.commit(straight(0), pageIndex: 0)
        session.commit(straight(10), pageIndex: 0)
        XCTAssertEqual(strokeCount(), 2)

        session.beginErase(pageIndex: 0)
        XCTAssertTrue(session.erase(from: CGPoint(x: 50, y: -5), to: CGPoint(x: 50, y: 15), radius: 3))
        session.endErase()
        XCTAssertEqual(strokeCount(), 4, "each line is cut in two")

        session.undo()
        XCTAssertEqual(strokeCount(), 2)
        session.undo()
        XCTAssertEqual(strokeCount(), 1)
        XCTAssertTrue(session.canRedo)
        session.redo()
        session.redo()
        XCTAssertEqual(strokeCount(), 4)
        XCTAssertFalse(session.canRedo)

        session.addLayer()
        XCTAssertEqual(session.layers.count, 2)
        session.commit(straight(40), pageIndex: 0)
        XCTAssertEqual(session.layers[1].strokes.count, 1, "new strokes go to the selected layer")
        session.undo()
        session.undo()
        XCTAssertEqual(session.layers.count, 1)

        // The stroke eraser removes whole strokes instead of cutting them.
        session.box.eraserMode = .stroke
        session.beginErase(pageIndex: 0)
        session.erase(from: CGPoint(x: 20, y: -5), to: CGPoint(x: 20, y: 3), radius: 3)
        session.endErase()
        XCTAssertEqual(strokeCount(), 3, "only the piece that was touched is removed, whole")
    }

    func testLibraryRenameDuplicateDelete() throws {
        let library = Library(root: root)
        let first = try library.create(kind: .notebook)
        let second = try library.create(kind: .notebook)
        XCTAssertNotEqual(first.title, second.title)

        try library.rename(first, to: "Lecture / notes")
        XCTAssertTrue(library.items.contains { $0.title == "Lecture - notes" })
        XCTAssertThrowsError(try library.rename(second, to: "Lecture - notes"))

        try library.duplicate(second)
        XCTAssertEqual(library.items.count, 3)
        try library.delete(second)
        XCTAssertEqual(library.items.count, 2)
    }

    func testNotesSavedUnderTheOldExtensionAreAdopted() throws {
        func make(_ name: String, kind: DocKind = .notebook) throws {
            try NoteDocument.create(at: root.appendingPathComponent(name), kind: kind)
        }
        try make("Lecture.sumi")
        try make("Sketch.sumi", kind: .canvas)
        // Same title in both spellings: neither may be overwritten.
        try make("Clash.sumi")
        try make("Clash.noteitself")
        // Somebody else's folder that happens to use the old extension.
        let foreign = root.appendingPathComponent("Other.sumi")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: foreign.appendingPathComponent("file.txt"))

        let library = Library(root: root)
        XCTAssertEqual(Set(library.items.map(\.title)), ["Lecture", "Sketch", "Clash", "Clash 2"])
        XCTAssertTrue(library.items.allSatisfy { $0.url.pathExtension == "noteitself" })
        XCTAssertEqual(library.items.first { $0.title == "Sketch" }?.kind, .canvas)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Lecture.sumi").path))
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("file.txt")), Data("keep".utf8))

        // New notes use the new extension, and a second launch changes nothing.
        XCTAssertEqual(try library.create(kind: .notebook).url.pathExtension, "noteitself")
        XCTAssertEqual(Library(root: root).items.count, 5)
    }

    func testPDFImportAnnotateAndExport() throws {
        // A two-page source: portrait and landscape.
        let source = root.appendingPathComponent("source.pdf")
        let sizes = [CGSize(width: 400, height: 600), CGSize(width: 700, height: 300)]
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sizes[0])).writePDF(to: source) { context in
            for size in sizes {
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                ("Page" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
            }
        }

        let library = Library(root: root)
        let item = try library.importPDF(at: source)
        let document = try NoteDocument(url: item.url)
        XCTAssertEqual(document.pages.map(\.size), sizes)
        XCTAssertTrue(document.pages.allSatisfy { $0.pdf != nil })

        let session = EditorSession(document: document)
        session.commit(straight(50, brush: .highlighter), pageIndex: 0)
        session.commit(straight(80), pageIndex: 1)

        let output = try PDFExporter.export(ExportSnapshot(document: document))
        let exported = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(exported.numberOfPages, 2)
        for (index, size) in sizes.enumerated() {
            let box = try XCTUnwrap(exported.page(at: index + 1)).getBoxRect(.mediaBox)
            XCTAssertEqual(box.width, size.width, accuracy: 0.5)
            XCTAssertEqual(box.height, size.height, accuracy: 0.5)
        }
    }

    func testCanvasExportFitsContent() throws {
        let library = Library(root: root)
        let document = try NoteDocument(url: try library.create(kind: .canvas).url)
        let session = EditorSession(document: document)
        session.commit(straight(-1000, from: 5000, to: 5200), pageIndex: 0)

        let output = try PDFExporter.export(ExportSnapshot(document: document))
        let page = try XCTUnwrap(CGPDFDocument(output as CFURL)?.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 200 + 2 + 48, accuracy: 1)
        XCTAssertEqual(box.height, 2 + 48, accuracy: 1)
    }
}

final class MeshTests: XCTestCase {
    func testInstanceLayoutsMatchShaders() {
        XCTAssertEqual(MemoryLayout<CapsuleInstance>.stride, 32)
        XCTAssertEqual(MemoryLayout<StampInstance>.stride, 24)
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, 32)
        XCTAssertEqual(MemoryLayout<PaperUniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<QuadUniforms>.stride, 32)
        XCTAssertEqual(MemoryLayout<StrokePoint>.stride, 16)
    }

    func testStampsFollowThePathAtRegularSpacing() {
        var stamps: [StampInstance] = []
        MeshBuilder.appendStamps(straight(0, from: 0, to: 100, r: 1).points, color: 0, into: &stamps)
        // Spacing is 0.28 × radius.
        XCTAssertEqual(Double(stamps.count), 100 / 0.28, accuracy: 4)
        XCTAssertEqual(stamps.first!.center.x, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(stamps.last!.center.x, 100.001)
        for (a, b) in zip(stamps, stamps.dropFirst()) {
            XCTAssertEqual(b.center.x - a.center.x, 0.28, accuracy: 0.01)
        }
    }

    func testIncrementalStampsMatchOneShot() {
        let points = straight(0, from: 0, to: 60, r: 1.5).points
        var whole: [StampInstance] = []
        MeshBuilder.appendStamps(points, color: 7, into: &whole)

        var walker = StampWalker()
        var pieces: [StampInstance] = []
        for p in points { walker.feed(p, color: 7, into: &pieces) }
        XCTAssertEqual(whole.count, pieces.count)
        XCTAssertEqual(whole.last!.center.x, pieces.last!.center.x, accuracy: 0.0001)
    }

    func testCapsulesCoverEverySegment() {
        var instances: [CapsuleInstance] = []
        let points = straight(0, from: 0, to: 20).points
        MeshBuilder.appendCapsules(points, color: 0xFF00_00FF, into: &instances)
        XCTAssertEqual(instances.count, points.count - 1)
        XCTAssertEqual(instances[0].p0.x, 0)
        XCTAssertEqual(instances.last!.p1.x, 20)
        XCTAssertEqual(instances[0].color, 0xFF00_00FF)
    }
}
