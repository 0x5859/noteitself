import XCTest

/// End-to-end checks that drive the real touch pipeline in the simulator.
/// Screenshots are attached to the test result and, when the environment
/// variable NOTEITSELF_SHOT_DIR is set (pass TEST_RUNNER_NOTEITSELF_SHOT_DIR to
/// xcodebuild), also written there as PNG files.
final class EditorUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let folder = ProcessInfo.processInfo.environment["NOTEITSELF_SHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// A one-finger drag in window-relative coordinates.
    private func drag(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
        point(x0, y0).press(forDuration: 0.05, thenDragTo: point(x1, y1), withVelocity: 900, thenHoldForDuration: 0.05)
    }

    /// The drawing surface, falling back to the window for other editors.
    private var surface: XCUIElement {
        let canvas = app.otherElements["canvas"]
        return canvas.exists ? canvas : app.windows.firstMatch
    }

    private func waitForEditor() {
        XCTAssertTrue(app.buttons["Pen"].waitForExistence(timeout: 15), "editor toolbar did not appear")
    }

    func testNotebookDrawingErasingLayersAndPages() {
        app.launchArguments = ["-new", "notebook"]
        app.launch()
        waitForEditor()

        // With no Pencil seen yet, one finger draws.
        drag(0.15, 0.20, 0.85, 0.20)
        drag(0.15, 0.26, 0.85, 0.30)
        drag(0.20, 0.16, 0.55, 0.42)
        shot("10-pen")

        app.buttons["Highlighter"].tap()
        drag(0.12, 0.20, 0.88, 0.20)
        app.buttons["Pencil"].tap()
        drag(0.15, 0.48, 0.85, 0.46)
        app.buttons["Brush"].tap()
        drag(0.15, 0.54, 0.85, 0.56)
        app.buttons["Marker"].tap()
        app.buttons["Colour 3"].tap()
        drag(0.15, 0.62, 0.85, 0.62)
        shot("11-brushes")

        // Precise eraser: a vertical swipe cuts a gap in every line it crosses.
        app.buttons["Eraser"].tap()
        drag(0.50, 0.12, 0.50, 0.70)
        shot("12-erased")

        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        app.buttons["Undo"].tap()
        shot("13-undo-erase")
        XCTAssertTrue(app.buttons["Redo"].isEnabled)
        app.buttons["Redo"].tap()

        // Two-finger tap undoes.
        surface.twoFingerTap()
        shot("14-two-finger-undo")

        // Tapping the active tool opens its settings.
        app.buttons["Eraser"].tap()
        XCTAssertTrue(app.buttons["Stroke"].waitForExistence(timeout: 5))
        shot("15-eraser-settings")
        app.buttons["Stroke"].tap()
        point(0.5, 0.92).tap()   // dismiss the popover
        drag(0.30, 0.44, 0.30, 0.60)
        shot("16-stroke-eraser")
        // Put the saved preference back for later runs.
        app.buttons["Eraser"].tap()
        XCTAssertTrue(app.buttons["Precise"].waitForExistence(timeout: 5))
        app.buttons["Precise"].tap()
        point(0.5, 0.92).tap()

        app.buttons["Layers"].tap()
        XCTAssertTrue(app.buttons["Add layer"].waitForExistence(timeout: 5))
        app.buttons["Add layer"].tap()
        shot("17-layers")
        point(0.5, 0.92).tap()

        app.buttons["Pen"].tap()
        app.buttons["Colour 2"].tap()
        drag(0.2, 0.75, 0.8, 0.80)

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Add Page"].waitForExistence(timeout: 5))
        shot("18-menu")
        app.buttons["Add Page"].tap()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))
        drag(0.2, 0.3, 0.8, 0.5)
        shot("19-second-page")

        surface.pinch(withScale: 0.45, velocity: -1)
        shot("20-zoomed-out")

        app.buttons["More"].tap()
        app.buttons["Export PDF"].tap()
        sleep(3)
        shot("21-share-sheet")
        point(0.5, 0.95).tap()
        sleep(1)

        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
        sleep(1)
        shot("22-library")
    }

    func testPenSettingsOfferPaperFeel() {
        app.launchArguments = ["-new", "notebook"]
        app.launch()
        waitForEditor()
        app.buttons["Pencil"].tap()
        app.buttons["Pen"].tap()
        app.buttons["Pen"].tap()   // the active tool opens its settings
        XCTAssertTrue(app.staticTexts["Paper feel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Smoothing"].exists)
        XCTAssertTrue(app.switches["Natural ink"].exists)
        shot("70-pen-settings")
        point(0.5, 0.92).tap()

        // Curved strokes through the paper-feel pipeline with real touches.
        drag(0.2, 0.30, 0.8, 0.34)
        drag(0.2, 0.40, 0.5, 0.52)
        drag(0.5, 0.52, 0.8, 0.40)
        point(0.5, 0.62).tap()
        shot("71-paper-feel-strokes")
        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    }

    func testOneFingerScrollModeAndReopen() {
        app.launchArguments = ["-new", "notebook"]
        app.launch()
        waitForEditor()
        drag(0.2, 0.3, 0.8, 0.3)

        app.buttons["More"].tap()
        app.buttons["Add Page"].tap()
        XCTAssertTrue(app.staticTexts["2 / 2"].waitForExistence(timeout: 5))

        // Make one finger scroll instead of draw.
        app.buttons["More"].tap()
        app.buttons["Pencil & Touch"].tap()
        app.buttons["One Finger"].tap()
        app.buttons["Scroll"].tap()

        // Dragging down now scrolls back to the first page and leaves no ink.
        drag(0.5, 0.3, 0.5, 0.9)
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Redo"].isEnabled)
        shot("50-scrolled-back")

        // Switch paper style.
        app.buttons["More"].tap()
        app.buttons["Paper"].tap()
        app.buttons["Lined"].tap()
        shot("51-lined")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("52-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)

        // Restore the default so later tests can draw with a finger.
        app.buttons["More"].tap()
        app.buttons["Pencil & Touch"].tap()
        app.buttons["One Finger"].tap()
        app.buttons["Draw"].tap()

        // Leave and come back: the ink and the paper style are still there.
        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10))
        sleep(1)
        shot("53-library-after-relaunch")
    }

    func testInfiniteCanvasAndImageTracing() {
        app.launchArguments = ["-new", "canvas", "-demoImage"]
        app.launch()
        waitForEditor()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), "image strip did not appear")
        shot("30-image-inserted")

        // The image layer is selected: dragging moves it instead of drawing.
        drag(0.5, 0.5, 0.62, 0.42)
        shot("31-image-moved")
        app.buttons["Done"].tap()

        // Trace on the drawing layer above the image.
        drag(0.42, 0.34, 0.78, 0.34)
        drag(0.78, 0.34, 0.78, 0.52)
        drag(0.78, 0.52, 0.42, 0.52)
        drag(0.42, 0.52, 0.42, 0.34)
        shot("32-traced")

        surface.pinch(withScale: 3, velocity: 2)
        shot("33-zoomed-in")
        surface.pinch(withScale: 0.15, velocity: -2)
        shot("34-zoomed-out")

        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
    }

    func testPixelArt() {
        app.launchArguments = ["-new", "pixel"]
        app.launch()
        XCTAssertTrue(app.buttons["Fill"].waitForExistence(timeout: 15), "pixel toolbar did not appear")
        shot("60-pixel-empty")

        // A closed box, then fill its inside with another colour.
        drag(0.30, 0.40, 0.70, 0.40)
        drag(0.70, 0.40, 0.70, 0.60)
        drag(0.70, 0.60, 0.30, 0.60)
        drag(0.30, 0.60, 0.30, 0.40)
        drag(0.35, 0.45, 0.65, 0.55)
        shot("61-pixel-drawn")

        app.buttons["Colour"].tap()
        sleep(1)
        shot("62-pixel-palette")
        point(0.5, 0.95).tap()

        app.buttons["Fill"].tap()
        point(0.62, 0.43).tap()
        shot("63-pixel-filled")

        app.buttons["Eraser"].tap()
        drag(0.5, 0.35, 0.5, 0.65)
        shot("64-pixel-erased")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        app.buttons["Undo"].tap()

        surface.pinch(withScale: 2, velocity: 2)
        shot("65-pixel-zoomed")

        app.buttons["Layers"].tap()
        sleep(1)
        shot("66-pixel-layers")
        point(0.5, 0.95).tap()

        // Canvas size: a preset, then one step wider, so it is no longer square.
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Canvas Size (32 × 32)"].waitForExistence(timeout: 5))
        app.buttons["Canvas Size (32 × 32)"].tap()
        XCTAssertTrue(app.buttons["64 by 64"].waitForExistence(timeout: 5), "size panel did not appear")
        XCTAssertFalse(app.buttons["Resize Canvas"].isEnabled, "nothing to apply yet")
        app.buttons["64 by 64"].tap()
        app.steppers["Width"].buttons["Increment"].tap()
        app.buttons["Anchor top left"].tap()
        shot("66b-pixel-canvas-size")
        app.buttons["Resize Canvas"].tap()
        sleep(1)
        shot("66c-pixel-resized")

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Canvas Size (65 × 64)"].waitForExistence(timeout: 5), "canvas was not resized")
        sleep(1)
        shot("67-pixel-menu")
        app.buttons["Export PNG"].tap()
        sleep(3)
        shot("68-pixel-share")
        point(0.5, 0.97).tap()
        sleep(1)

        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
        sleep(1)
        shot("69-library")
    }

    func testPDFAnnotation() throws {
        guard let pdf = ProcessInfo.processInfo.environment["NOTEITSELF_PDF"], !pdf.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_NOTEITSELF_PDF to a PDF path")
        }
        app.launchArguments = ["-importPDF", pdf]
        app.launch()
        waitForEditor()
        sleep(2)
        shot("40-pdf")

        app.buttons["Highlighter"].tap()
        drag(0.2, 0.30, 0.8, 0.30)
        app.buttons["Pen"].tap()
        app.buttons["Colour 3"].tap()
        drag(0.2, 0.40, 0.6, 0.44)
        drag(0.6, 0.44, 0.7, 0.36)
        shot("41-pdf-annotated")

        surface.pinch(withScale: 2.5, velocity: 2)
        sleep(2)
        shot("42-pdf-zoomed")

        app.buttons["More"].tap()
        app.buttons["Export PDF"].tap()
        sleep(3)
        shot("43-pdf-share")
        point(0.5, 0.95).tap()
        sleep(1)
        app.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 5))
        sleep(1)
        shot("44-library")
    }
}
