import Metal
import QuartzCore
import UIKit

/// The drawing surface: a Metal layer plus all pointer handling.
///
/// Input rules
///  - Apple Pencil always draws (or erases, or moves the selected image).
///  - Two fingers always pan and zoom; two-finger tap undoes, three-finger tap redoes.
///  - One finger scrolls, draws or erases depending on the finger mode.
///  - While the Pencil is down, fingers are ignored and navigation is off, so
///    a resting palm can neither draw nor scroll.
final class CanvasView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let session: EditorSession
    private(set) var renderer: Renderer?

    // Camera: view point = (world - origin) * zoom
    private var zoom: CGFloat = 1
    private var origin: CGPoint = .zero
    private var hasCamera = false
    private var lastSize: CGSize = .zero

    private var displayLink: CADisplayLink?
    private var needsBase = true
    private var needsPresent = true
    private var velocity: CGPoint = .zero
    private var decelerating = false

    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let undoTap = UITapGestureRecognizer()
    private let redoTap = UITapGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()

    private var inkTouch: UITouch?
    private var live: LiveStroke?
    private var pencilForce = PencilForce()
    private var eraseLast: CGPoint?
    private var erasePageOrigin: CGPoint = .zero
    private var imageDrag: ImageDrag?
    private var pencilDown = false
    private var navigationResume: DispatchWorkItem?

    private let cursorLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private var detailWork: DispatchWorkItem?
    private var visibleRange: Range<Int> = 0..<0

    private struct ImageDrag {
        let before: [Layer]
        let startFrame: CGRect
        let startPoint: CGPoint
        let corner: Int?
        let pageOrigin: CGPoint
    }

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isOpaque = true
        // Lets VoiceOver users (and UI tests) touch the canvas directly.
        isAccessibilityElement = true
        accessibilityIdentifier = "canvas"
        accessibilityLabel = "Canvas"
        accessibilityTraits = .allowsDirectInteraction

        if let device = MTLCreateSystemDefaultDevice() {
            metalLayer.device = device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.isOpaque = true
            // Present straight to the display instead of waiting for a Core
            // Animation transaction: one less frame between Pencil and ink.
            metalLayer.presentsWithTransaction = false
            renderer = Renderer(device: device)
            renderer?.textures.packageURL = session.document.url
            renderer?.textures.onChange = { [weak self] in self?.setNeedsBase() }
        }

        setUpGestures()
        setUpOverlays()
        session.canvas = self

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CanvasView, _: UITraitCollection) in
            view.setNeedsBase()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { displayLink?.invalidate() }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        contentScaleFactor = window.windowScene?.screen.scale ?? traitCollection.displayScale
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        let fps = Float(window.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsBase()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = contentScaleFactor
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0 else { return }
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        renderer?.resize(to: size)

        if !hasCamera {
            hasCamera = true
            resetCamera()
        } else if lastSize != bounds.size, lastSize != .zero {
            let centre = CGPoint(x: origin.x + lastSize.width / 2 / zoom, y: origin.y + lastSize.height / 2 / zoom)
            // A page that filled the width keeps filling it after rotation or
            // a Split View resize; otherwise the zoom is left alone.
            let oldFit = fitZoom(forWidth: lastSize.width)
            if !session.document.isInfinite, abs(zoom - oldFit) < oldFit * 0.02 {
                zoom = fitZoom
            }
            // Keep the centre of the view fixed.
            origin = CGPoint(x: centre.x - bounds.width / 2 / zoom, y: centre.y - bounds.height / 2 / zoom)
            clampCamera()
        }
        lastSize = bounds.size
        cursorLayer.frame = bounds
        selectionLayer.frame = bounds
        setNeedsBase()
        scheduleDetail()
    }

    // MARK: Camera

    private static let edgeMargin: CGFloat = 12

    private var visibleWorld: CGRect {
        CGRect(x: origin.x, y: origin.y, width: bounds.width / zoom, height: bounds.height / zoom)
    }

    private func world(from point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x / zoom, y: origin.y + point.y / zoom)
    }

    private func pagePoint(_ viewPoint: CGPoint, origin pageOrigin: CGPoint) -> CGPoint {
        let w = world(from: viewPoint)
        return CGPoint(x: w.x - pageOrigin.x, y: w.y - pageOrigin.y)
    }

    var viewState: ViewState { ViewState(x: Double(origin.x), y: Double(origin.y), zoom: Double(zoom)) }

    /// Visible part of a page, in that page's coordinates.
    func visibleRect(inPage index: Int) -> CGRect {
        let o = session.origin(ofPage: index)
        return visibleWorld.offsetBy(dx: -o.x, dy: -o.y)
    }

    private var fitZoom: CGFloat { fitZoom(forWidth: bounds.width) }

    /// Zoom at which the widest page fills a view of the given width.
    private func fitZoom(forWidth viewWidth: CGFloat) -> CGFloat {
        let width = session.contentBounds.isNull ? 0 : session.contentBounds.width
        guard width > 0, viewWidth > 0 else { return 1 }
        return viewWidth / (width + 2 * CanvasView.edgeMargin)
    }

    private var zoomLimits: ClosedRange<CGFloat> {
        if session.document.isInfinite { return 0.05...40 }
        let fit = fitZoom
        return (fit * 0.3)...max(fit * 8, 6)
    }

    private func resetCamera() {
        if let saved = session.document.manifest.view, saved.zoom > 0 {
            zoom = min(max(CGFloat(saved.zoom), zoomLimits.lowerBound), zoomLimits.upperBound)
            origin = CGPoint(x: saved.x, y: saved.y)
        } else if session.document.isInfinite {
            zoom = 1
            origin = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
        } else {
            zoom = fitZoom
            origin = CGPoint(x: -bounds.width / zoom / 2, y: -CanvasView.edgeMargin / zoom)
        }
        clampCamera()
    }

    /// Keeps a notebook's pages on screen; an unbounded canvas is left alone.
    private func clampCamera() {
        guard !session.document.isInfinite, !session.contentBounds.isNull else { return }
        let margin = CanvasView.edgeMargin / zoom
        let content = session.contentBounds.insetBy(dx: -margin, dy: -margin)
        let visible = CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
        if content.width <= visible.width {
            origin.x = content.midX - visible.width / 2
        } else {
            origin.x = min(max(origin.x, content.minX), content.maxX - visible.width)
        }
        if content.height <= visible.height {
            origin.y = content.midY - visible.height / 2
        } else {
            origin.y = min(max(origin.y, content.minY), content.maxY - visible.height)
        }
    }

    private func cameraChanged() {
        clampCamera()
        setNeedsBase()
        scheduleDetail()
    }

    func scroll(toPage index: Int) {
        guard session.pageFrames.indices.contains(index) else { return }
        origin.y = session.pageFrames[index].minY - CanvasView.edgeMargin / zoom
        cameraChanged()
    }

    /// Pages were added or removed.
    func layoutChanged() {
        clampCamera()
        setNeedsBase()
        scheduleDetail()
    }

    func toolsChanged() {
        pan.minimumNumberOfTouches = session.box.fingerMode == .pan ? 1 : 2
        if session.box.tool != .eraser, eraseLast == nil { hideCursor() }
    }

    // MARK: Frame loop

    func setNeedsBase() {
        needsBase = true
        wake()
    }

    private func wake() {
        displayLink?.isPaused = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if decelerating {
            let dt = CGFloat(max(0, min(link.targetTimestamp - link.timestamp, 0.05)))
            let before = origin
            origin.x -= velocity.x * dt / zoom
            origin.y -= velocity.y * dt / zoom
            let wanted = origin
            clampCamera()
            // Hitting an edge kills the motion along that axis.
            if abs(origin.x - wanted.x) > 1e-9 { velocity.x = 0 }
            if abs(origin.y - wanted.y) > 1e-9 { velocity.y = 0 }
            let decay = pow(0.998, dt * 1000)
            velocity.x *= decay
            velocity.y *= decay
            if hypot(velocity.x, velocity.y) < 6 { decelerating = false }
            if origin != before {
                needsBase = true
                scheduleDetail()
            }
        }

        guard needsBase || needsPresent else {
            if !decelerating { link.isPaused = true }
            return
        }
        drawFrame()
    }

    private var backdrop: MTLClearColor {
        traitCollection.userInterfaceStyle == .dark
            ? MTLClearColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
            : MTLClearColor(red: 0.925, green: 0.925, blue: 0.94, alpha: 1)
    }

    private func drawFrame() {
        guard let renderer, hasCamera else { return }
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0, renderer.matchesScene(size),
              let drawable = metalLayer.nextDrawable(),
              drawable.texture.width == Int(size.width), drawable.texture.height == Int(size.height),
              let commandBuffer = renderer.queue.makeCommandBuffer() else { return }

        let frame = FrameInfo(
            viewport: size,
            pixelsPerUnit: Double(zoom * contentScaleFactor),
            origin: origin,
            backdrop: backdrop
        )
        let (draws, active) = pageDraws()
        if needsBase {
            renderer.drawBase(in: commandBuffer, frame: frame, pages: draws)
            needsBase = false
        }
        var liveOpacity: Float = 1
        if let active, !active.page.layers.isEmpty {
            liveOpacity = active.page.layers[session.activeLayerIndex(in: active.page)].opacity
        }
        renderer.present(in: commandBuffer, target: drawable.texture, frame: frame,
                         live: live, liveOpacity: liveOpacity, activePage: active)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        needsPresent = false
        updateSelectionOverlay()
    }

    /// Visible pages for this frame, plus the page that owns the live stroke
    /// and upper layers.
    private func pageDraws() -> (all: [PageDraw], active: PageDraw?) {
        let document = session.document
        let visible = visibleWorld

        if document.isInfinite {
            guard let page = session.loadedPage(0) else { return ([], nil) }
            let draw = PageDraw(page: page, origin: .zero, rect: visible, clips: false,
                                upperStart: session.activeLayerIndex(in: page) + 1)
            return ([draw], draw)
        }

        let frames = session.pageFrames
        var first = Int.max, last = -1
        for (index, frame) in frames.enumerated() where frame.intersects(visible) {
            first = min(first, index)
            last = max(last, index)
        }
        guard last >= first else { return ([], nil) }

        // Outside of a stroke, the page nearest the middle of the screen is
        // the one layer and page commands act on.
        if inkTouch == nil {
            let centre = CGPoint(x: visible.midX, y: visible.midY)
            var best = first
            var bestDistance = CGFloat.infinity
            for index in first...last {
                let f = frames[index]
                let distance = centre.y < f.minY ? f.minY - centre.y : max(0, centre.y - f.maxY)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            session.setActivePage(best)
        }

        var draws: [PageDraw] = []
        var active: PageDraw?
        for index in first...last {
            guard let page = session.loadedPage(index) else { continue }
            let isActive = index == session.activePageIndex
            let draw = PageDraw(
                page: page, origin: frames[index].origin,
                rect: CGRect(origin: .zero, size: frames[index].size), clips: true,
                upperStart: isActive ? session.activeLayerIndex(in: page) + 1 : page.layers.count
            )
            draws.append(draw)
            if isActive { active = draw }
        }

        let range = first..<(last + 1)
        if range != visibleRange {
            visibleRange = range
            session.trimLoadedPages(keeping: range)
        }
        return (draws, active)
    }

    // MARK: Sharp PDF backgrounds

    private func scheduleDetail() {
        guard session.hasPDF else { return }
        detailWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestDetail() }
        detailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Once the view has settled, rasterise the visible PDF pages at exactly
    /// the current zoom, aligned to the pixel grid.
    private func requestDetail() {
        guard let renderer, hasCamera, bounds.width > 0 else { return }
        let ppu = zoom * contentScaleFactor
        let visible = visibleWorld
        let padded = visible.insetBy(dx: -visible.width * 0.08, dy: -visible.height * 0.08)
        let x = origin.x + ((padded.minX - origin.x) * ppu).rounded(.down) / ppu
        let y = origin.y + ((padded.minY - origin.y) * ppu).rounded(.down) / ppu
        let rect = CGRect(
            x: x, y: y,
            width: ((padded.maxX - x) * ppu).rounded(.up) / ppu,
            height: ((padded.maxY - y) * ppu).rounded(.up) / ppu
        )
        var placements: [TextureStore.PDFPlacement] = []
        for (index, frame) in session.pageFrames.enumerated() where frame.intersects(rect) {
            if let ref = session.document.pages[index].pdf {
                placements.append(TextureStore.PDFPlacement(ref: ref, frame: frame))
            }
        }
        renderer.textures.requestDetail(pages: placements, worldRect: rect, pixelsPerUnit: Double(ppu))
    }

    // MARK: Gestures

    private func setUpGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        pan.addTarget(self, action: #selector(onPan(_:)))
        pan.delegate = self
        pan.allowedTouchTypes = direct
        pan.maximumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all
        addGestureRecognizer(pan)

        pinch.addTarget(self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        pinch.allowedTouchTypes = direct
        addGestureRecognizer(pinch)

        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = direct
        undoTap.addTarget(self, action: #selector(onUndoTap))
        addGestureRecognizer(undoTap)

        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = direct
        redoTap.addTarget(self, action: #selector(onRedoTap))
        addGestureRecognizer(redoTap)

        hover.addTarget(self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        toolsChanged()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pan && other === pinch) || (gestureRecognizer === pinch && other === pan)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // A single finger that is dragging the selected image must not scroll.
        if gestureRecognizer === pan, imageDrag != nil, pan.numberOfTouches < 2 { return false }
        return true
    }

    private func setNavigationEnabled(_ enabled: Bool) {
        navigationResume?.cancel()
        navigationResume = nil
        // Includes the undo/redo taps: a palm lifting off can look like one.
        for recognizer in [pan, pinch, undoTap, redoTap] {
            recognizer.isEnabled = enabled
        }
    }

    @objc private func onPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            decelerating = false
            gesture.setTranslation(.zero, in: self)
        case .changed:
            let t = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            origin.x -= t.x / zoom
            origin.y -= t.y / zoom
            cameraChanged()
        case .ended:
            let v = gesture.velocity(in: self)
            if hypot(v.x, v.y) > 80 {
                velocity = v
                decelerating = true
                wake()
            }
        default:
            break
        }
    }

    @objc private func onPinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else {
            if gesture.state == .began { decelerating = false }
            return
        }
        let anchor = gesture.location(in: self)
        let fixed = world(from: anchor)
        let limits = zoomLimits
        zoom = min(max(zoom * gesture.scale, limits.lowerBound), limits.upperBound)
        gesture.scale = 1
        origin = CGPoint(x: fixed.x - anchor.x / zoom, y: fixed.y - anchor.y / zoom)
        cameraChanged()
    }

    @objc private func onUndoTap() { session.undo() }
    @objc private func onRedoTap() { session.redo() }

    @objc private func onHover(_ gesture: UIHoverGestureRecognizer) {
        guard eraseLast == nil else { return }
        let hovering = gesture.state == .began || gesture.state == .changed
        if hovering, session.box.tool == .eraser {
            showCursor(at: gesture.location(in: self))
        } else {
            hideCursor()
        }
    }

    // MARK: Apple Pencil double-tap and squeeze

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if #available(iOS 17.5, *) { return }   // handled by the newer callback
        session.perform(session.box.doubleTap)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        session.perform(session.box.doubleTap)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { session.perform(session.box.squeeze) }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        decelerating = false
        for touch in touches {
            switch touch.type {
            case .pencil:
                session.notePencilSeen()
                pencilDown = true
                setNavigationEnabled(false)
                // A resting palm may have started a finger gesture: undo it.
                if let current = inkTouch, current.type != .pencil { finishInk(cancelled: true) }
                guard inkTouch == nil else { continue }
                begin(touch, event: event, erase: session.box.tool == .eraser)
            case .direct:
                guard !pencilDown, inkTouch == nil else { continue }
                let fingers = event?.allTouches?.filter {
                    $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
                }.count ?? 1
                guard fingers == 1 else { continue }
                if session.activeImage != nil {
                    begin(touch, event: event, erase: false)
                    continue
                }
                switch session.box.fingerMode {
                case .pan: break
                case .draw: begin(touch, event: event, erase: session.box.tool == .eraser)
                case .erase: begin(touch, event: event, erase: true)
                }
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = inkTouch, touches.contains(touch) else { return }
        if imageDrag != nil {
            updateImageDrag(touch)
        } else if eraseLast != nil {
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                eraseStep(to: pagePoint(sample.preciseLocation(in: self), origin: erasePageOrigin))
            }
            showCursor(at: touch.preciseLocation(in: self))
        } else {
            feed(touch, event: event, predict: true)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches, event: event, cancelled: true)
    }

    private func end(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        if touches.contains(where: { $0.type == .pencil }) {
            pencilDown = false
            // Give navigation back a moment later so the hand settling
            // between strokes cannot scroll the page.
            let resume = DispatchWorkItem { [weak self] in self?.setNavigationEnabled(true) }
            navigationResume?.cancel()
            navigationResume = resume
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: resume)
        }
        guard let touch = inkTouch, touches.contains(touch) else { return }
        if !cancelled, live != nil { feed(touch, event: event, predict: false) }
        finishInk(cancelled: cancelled)
    }

    private func begin(_ touch: UITouch, event: UIEvent?, erase: Bool) {
        let location = touch.preciseLocation(in: self)
        guard let hit = session.pageHit(world(from: location)) else { return }
        session.setActivePage(hit.index)

        if session.activeImage != nil {
            beginImageDrag(touch, pageOrigin: hit.origin)
            return
        }

        if erase {
            inkTouch = touch
            session.beginErase(pageIndex: hit.index)
            erasePageOrigin = hit.origin
            let p = pagePoint(location, origin: hit.origin)
            eraseLast = p
            eraseStep(to: p)
            showCursor(at: location)
        } else if let spec = session.brushSpec(), let device = renderer?.device {
            inkTouch = touch
            let builder = StrokeBuilder(kind: spec.kind, radius: Float(spec.width / 2),
                                        smoothing: spec.smoothing, zoom: Double(zoom),
                                        paper: spec.paper, naturalInk: spec.naturalInk)
            live = LiveStroke(builder: builder, brush: spec.kind, color: spec.color,
                              pageIndex: hit.index, pageOrigin: hit.origin, device: device)
            pencilForce = PencilForce()
            feed(touch, event: event, predict: true)
        }
        wake()
    }

    private func feed(_ touch: UITouch, event: UIEvent?, predict: Bool) {
        guard let live else { return }
        // Coalesced touches carry every Pencil sample (240 Hz), not just the
        // one per display frame.
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let pressure: CGFloat = sample.type == .pencil
                ? pencilForce.pressure(force: sample.force,
                                       expectsUpdate: sample.estimatedPropertiesExpectingUpdates.contains(.force))
                : -1
            live.builder.add(InputSample(
                position: pagePoint(sample.preciseLocation(in: self), origin: live.pageOrigin),
                pressure: pressure, altitude: sample.altitudeAngle, time: sample.timestamp
            ))
        }
        // Predicted touches let the ink reach where the tip is about to be.
        var predicted: [CGPoint] = []
        if predict, let future = event?.predictedTouches(for: touch) {
            predicted = future.map { pagePoint($0.preciseLocation(in: self), origin: live.pageOrigin) }
        }
        live.sync(predicted: predicted)
        needsPresent = true
        wake()
    }

    private func finishInk(cancelled: Bool) {
        if let drag = imageDrag {
            session.endImageEdit(before: drag.before)
            imageDrag = nil
        } else if eraseLast != nil {
            if cancelled { session.cancelErase() } else { session.endErase() }
            eraseLast = nil
            hideCursor()
        } else if let stroke = live {
            live = nil
            if !cancelled {
                let points = stroke.builder.finish()
                if !points.isEmpty {
                    session.commit(Stroke(brush: stroke.brush, color: stroke.color, points: points),
                                   pageIndex: stroke.pageIndex)
                }
            }
        }
        inkTouch = nil
        setNeedsBase()
    }

    // MARK: Erasing

    private var eraserDiameter: CGFloat { CGFloat(session.box[.eraser].width) }

    private func eraseStep(to point: CGPoint) {
        guard let last = eraseLast else { return }
        // The eraser has a fixed size on screen: zoom in to erase finer detail.
        if session.erase(from: last, to: point, radius: eraserDiameter / 2 / zoom) {
            setNeedsBase()
        }
        eraseLast = point
    }

    // MARK: Positioning an image layer

    private func beginImageDrag(_ touch: UITouch, pageOrigin: CGPoint) {
        guard let image = session.activeImage else { return }
        let p = pagePoint(touch.preciseLocation(in: self), origin: pageOrigin)
        let f = image.frame
        let corners = [
            CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
            CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY),
        ]
        let reach = 28 / zoom
        let corner = corners.firstIndex { hypot($0.x - p.x, $0.y - p.y) < reach }
        guard corner != nil || f.contains(p), let before = session.beginImageEdit() else { return }
        inkTouch = touch
        imageDrag = ImageDrag(before: before, startFrame: f, startPoint: p, corner: corner, pageOrigin: pageOrigin)
    }

    private func updateImageDrag(_ touch: UITouch) {
        guard let drag = imageDrag else { return }
        let p = pagePoint(touch.preciseLocation(in: self), origin: drag.pageOrigin)
        let s = drag.startFrame
        var frame = s
        if let corner = drag.corner {
            // Scale uniformly around the opposite corner.
            let grabbed = [
                CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.maxX, y: s.minY),
                CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX, y: s.maxY),
            ][corner]
            let anchor = CGPoint(x: s.minX + s.maxX - grabbed.x, y: s.minY + s.maxY - grabbed.y)
            let before = hypot(grabbed.x - anchor.x, grabbed.y - anchor.y)
            let k = max(0.05, hypot(p.x - anchor.x, p.y - anchor.y) / max(before, 0.001))
            let w = s.width * k, h = s.height * k
            frame = CGRect(
                x: anchor.x <= s.minX ? anchor.x : anchor.x - w,
                y: anchor.y <= s.minY ? anchor.y : anchor.y - h,
                width: w, height: h
            )
        } else {
            frame.origin.x += p.x - drag.startPoint.x
            frame.origin.y += p.y - drag.startPoint.y
        }
        session.setImageFrame(frame)
        setNeedsBase()
    }

    // MARK: Overlays

    private func setUpOverlays() {
        let none: [String: CAAction] = [
            "path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
        ]
        for overlay in [cursorLayer, selectionLayer] {
            overlay.actions = none
            overlay.fillColor = nil
            overlay.isHidden = true
            layer.addSublayer(overlay)
        }
        cursorLayer.lineWidth = 1
        cursorLayer.strokeColor = UIColor.label.withAlphaComponent(0.55).cgColor
        cursorLayer.fillColor = UIColor.label.withAlphaComponent(0.06).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.001).cgColor
    }

    private func showCursor(at point: CGPoint) {
        let d = eraserDiameter
        cursorLayer.strokeColor = UIColor.label.withAlphaComponent(0.55).cgColor
        cursorLayer.fillColor = UIColor.label.withAlphaComponent(0.06).cgColor
        cursorLayer.path = CGPath(ellipseIn: CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d), transform: nil)
        cursorLayer.isHidden = false
    }

    private func hideCursor() {
        cursorLayer.isHidden = true
    }

    /// Outline and corner handles of the image layer being positioned.
    private func updateSelectionOverlay() {
        guard let image = session.activeImage else {
            if !selectionLayer.isHidden { selectionLayer.isHidden = true }
            return
        }
        let o = session.origin(ofPage: image.pageIndex)
        let rect = CGRect(
            x: (o.x + image.frame.minX - origin.x) * zoom,
            y: (o.y + image.frame.minY - origin.y) * zoom,
            width: image.frame.width * zoom, height: image.frame.height * zoom
        )
        let path = CGMutablePath()
        path.addRect(rect)
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)] {
            path.addEllipse(in: CGRect(x: corner.x - 6, y: corner.y - 6, width: 12, height: 12))
        }
        selectionLayer.path = path
        selectionLayer.isHidden = false
    }
}

/// Breaks the retain cycle between a display link and its view.
private final class DisplayLinkProxy: NSObject {
    weak var view: CanvasView?

    init(_ view: CanvasView) {
        self.view = view
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick(link)
    }
}
