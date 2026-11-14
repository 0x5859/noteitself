import XCTest
@testable import noteitself

final class PixelCanvasSizeTests: XCTestCase {
    /// 4 × 3 artwork in which every pixel's value encodes its position.
    private func artwork() -> PixelDocument {
        var pixels = [UInt32](repeating: 0, count: 12)
        for y in 0..<3 {
            for x in 0..<4 { pixels[y * 4 + x] = 0xFF00_0000 | UInt32(y * 16 + x + 1) }
        }
        let layer = PixelLayer(id: UUID(), name: "Layer 1", isVisible: true, opacity: 1, pixels: pixels)
        return PixelDocument(width: 4, height: 3, layers: [layer], activeLayerID: nil)
    }

    private func value(_ document: PixelDocument, _ x: Int, _ y: Int) -> UInt32 {
        document.layers[0].pixels[y * document.width + x]
    }

    private func painted(_ document: PixelDocument) -> Int {
        document.layers[0].pixels.filter { $0 != 0 }.count
    }

    func testGrowingKeepsTheArtworkAtTheAnchor() {
        let art = artwork()

        let topLeft = art.resized(width: 8, height: 7, anchor: .topLeft)
        XCTAssertEqual([topLeft.width, topLeft.height, topLeft.layers[0].pixels.count], [8, 7, 56])
        XCTAssertEqual(value(topLeft, 0, 0), value(art, 0, 0))
        XCTAssertEqual(value(topLeft, 3, 2), value(art, 3, 2))
        XCTAssertEqual(value(topLeft, 4, 0), 0)

        let centre = art.resized(width: 8, height: 7)
        XCTAssertEqual(value(centre, 2, 2), value(art, 0, 0))
        XCTAssertEqual(value(centre, 5, 4), value(art, 3, 2))

        let bottomRight = art.resized(width: 8, height: 7, anchor: PixelAnchor(column: 2, row: 2))
        XCTAssertEqual(value(bottomRight, 4, 4), value(art, 0, 0))
        XCTAssertEqual(value(bottomRight, 7, 6), value(art, 3, 2))

        for grown in [topLeft, centre, bottomRight] { XCTAssertEqual(painted(grown), 12, "nothing may be lost") }
    }

    func testShrinkingCropsAwayFromTheAnchor() {
        let art = artwork()

        let left = art.resized(width: 2, height: 3, anchor: .topLeft)
        XCTAssertEqual([value(left, 0, 1), value(left, 1, 1)], [value(art, 0, 1), value(art, 1, 1)])

        let right = art.resized(width: 2, height: 3, anchor: PixelAnchor(column: 2, row: 0))
        XCTAssertEqual([value(right, 0, 1), value(right, 1, 1)], [value(art, 2, 1), value(art, 3, 1)])

        let bottom = art.resized(width: 4, height: 1, anchor: PixelAnchor(column: 0, row: 2))
        XCTAssertEqual((0..<4).map { value(bottom, $0, 0) }, (0..<4).map { value(art, $0, 2) })

        let middle = art.resized(width: 2, height: 1)
        XCTAssertEqual([value(middle, 0, 0), value(middle, 1, 0)], [value(art, 1, 1), value(art, 2, 1)])
    }

    @MainActor
    func testResizingIsClampedUndoableAndSaved() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixel-size-\(UUID().uuidString)")
            .appendingPathComponent("Art").appendingPathExtension(Library.fileExtension)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

        let model = PixelEditorModel(packageURL: package)
        XCTAssertEqual([model.canvasWidth, model.canvasHeight], [32, 32])

        // Not square, and not one of the presets.
        model.resizeCanvas(width: 48, height: 20, anchor: .topLeft)
        XCTAssertEqual([model.canvasWidth, model.canvasHeight], [48, 20])
        XCTAssertTrue(model.canUndo)

        model.resizeCanvas(width: 100_000, height: -3)
        XCTAssertEqual([model.canvasWidth, model.canvasHeight], [PixelEditorModel.maxCanvasSide, 1])

        model.undo()
        XCTAssertEqual([model.canvasWidth, model.canvasHeight], [48, 20])
        model.save(synchronously: true)
        let reloaded = PixelStore.load(from: package).document
        XCTAssertEqual([reloaded.width, reloaded.height], [48, 20])

        model.undo()
        XCTAssertEqual([model.canvasWidth, model.canvasHeight], [32, 32])
        model.close()
    }
}
