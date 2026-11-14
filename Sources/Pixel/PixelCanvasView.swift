import UIKit

/// Full-screen pixel canvas. Each document layer is a `CALayer` whose contents
/// is that layer's bitmap, shown with nearest-neighbour magnification inside
/// `artLayer`, which is scaled and positioned for pan/zoom. Only the edited
/// layer's image is rebuilt per input event; nothing is drawn with `draw(_:)`.
final class PixelCanvasView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let model: PixelEditorModel

    private let shadowLayer = CALayer()
    private let artLayer = CALayer()
    private let checkerLayer = CALayer()
    private let gridLayer = CALayer()
    private let gridColumns = CAReplicatorLayer()
    private let gridRows = CAReplicatorLayer()
    private let columnLine = CALayer()
    private let rowLine = CALayer()
    private let hoverLayer = CALayer()
    private let hoverInnerLayer = CALayer()
    private var pixelLayers: [UUID: CALayer] = [:]

    private var artWidth = 0
    private var artHeight = 0
    private var scale: CGFloat = 1
    private var origin = CGPoint.zero
    private var fitScale: CGFloat = 1
    private var needsFit = true
    private var lastBoundsSize = CGSize.zero
    private var gridEnabled: Bool
    private static let minGridCell: CGFloat = 5

    private enum Input {
        case idle
        case drawing(UITouch)
        /// Multi-finger contact: ignore touches until every finger lifts.
        case blocked
    }
    private var input = Input.idle
    private var pencilTouch: UITouch?
    private var hoverPixel: PixelPoint?

    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    private lazy var undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
    private lazy var redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))

    init(model: PixelEditorModel) {
        self.model = model
        gridEnabled = model.showGrid
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        isMultipleTouchEnabled = true
        configureLayers()
        configureGestures()
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
            (view: PixelCanvasView, _: UITraitCollection) in
            view.applyAppearance()
        }
        model.canvas = self
        syncLayers()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureLayers() {
        shadowLayer.shadowColor = UIColor.black.cgColor
        shadowLayer.shadowOpacity = 0.14
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: 4)
        artLayer.anchorPoint = .zero
        checkerLayer.magnificationFilter = .nearest
        artLayer.addSublayer(checkerLayer)

        let gridColor = UIColor(white: 0.5, alpha: 0.4).cgColor
        columnLine.backgroundColor = gridColor
        rowLine.backgroundColor = gridColor
        gridColumns.addSublayer(columnLine)
        gridRows.addSublayer(rowLine)
        gridLayer.addSublayer(gridColumns)
        gridLayer.addSublayer(gridRows)

        hoverLayer.borderColor = UIColor(white: 0, alpha: 0.6).cgColor
        hoverInnerLayer.borderColor = UIColor(white: 1, alpha: 0.9).cgColor
        hoverLayer.addSublayer(hoverInnerLayer)
        hoverLayer.isHidden = true

        for sublayer in [shadowLayer, artLayer, gridLayer, hoverLayer] { layer.addSublayer(sublayer) }
    }

    private func configureGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGesture.minimumNumberOfTouches = 2
        panGesture.allowedScrollTypesMask = .continuous
        panGesture.allowedTouchTypes = direct
        pinchGesture.allowedTouchTypes = direct + [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        undoTap.numberOfTouchesRequired = 2
        redoTap.numberOfTouchesRequired = 3
        for tap in [undoTap, redoTap] { tap.allowedTouchTypes = direct }
        for gesture in [panGesture, pinchGesture, undoTap, redoTap] as [UIGestureRecognizer] {
            gesture.delegate = self
            gesture.delaysTouchesEnded = false
            addGestureRecognizer(gesture)
        }
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
    }

    // MARK: Model sync

    /// Mirrors the document's layer stack: order, visibility, opacity and (optionally) bitmaps.
    func syncLayers(rebuildImages: Bool = true) {
        let document = model.document
        withoutAnimation {
            if document.width != artWidth || document.height != artHeight {
                artWidth = document.width
                artHeight = document.height
                artLayer.bounds = CGRect(x: 0, y: 0, width: artWidth, height: artHeight)
                checkerLayer.frame = artLayer.bounds
                checkerLayer.contents = makeChecker()
                needsFit = true
                setNeedsLayout()
            }
            var stale = Set(pixelLayers.keys)
            for (index, layer) in document.layers.enumerated() {
                stale.remove(layer.id)
                let sublayer: CALayer
                if let existing = pixelLayers[layer.id], !rebuildImages {
                    sublayer = existing
                } else {
                    sublayer = pixelLayers[layer.id] ?? makePixelLayer()
                    pixelLayers[layer.id] = sublayer
                    sublayer.contents = PixelRaster.image(layer.pixels, width: artWidth, height: artHeight)
                }
                sublayer.frame = artLayer.bounds
                sublayer.opacity = Float(layer.opacity)
                sublayer.isHidden = !layer.isVisible
                artLayer.insertSublayer(sublayer, at: UInt32(index + 1))
            }
            for id in stale { pixelLayers.removeValue(forKey: id)?.removeFromSuperlayer() }
        }
        layoutHover()
    }

    func setGridVisible(_ visible: Bool) {
        gridEnabled = visible
        layoutArt()
    }

    func refreshHover() { layoutHover() }

    private func refreshActiveLayer() {
        guard let sublayer = pixelLayers[model.document.activeLayerID] else { return }
        withoutAnimation { sublayer.contents = model.activeLayerImage() }
    }

    private func makePixelLayer() -> CALayer {
        let sublayer = CALayer()
        sublayer.magnificationFilter = .nearest
        sublayer.minificationFilter = .linear
        return sublayer
    }

    private func makeChecker() -> CGImage? {
        guard artWidth > 0, artHeight > 0 else { return nil }
        let cell = max(1, max(artWidth, artHeight) / 16)
        let dark = traitCollection.userInterfaceStyle == .dark
        let light: UInt32 = dark ? PixelRGBA.pack(58, 58, 62, 255) : PixelRGBA.pack(255, 255, 255, 255)
        let shade: UInt32 = dark ? PixelRGBA.pack(46, 46, 50, 255) : PixelRGBA.pack(234, 234, 238, 255)
        var pixels = [UInt32](repeating: light, count: artWidth * artHeight)
        for y in 0..<artHeight {
            for x in 0..<artWidth where (x / cell + y / cell) % 2 == 1 { pixels[y * artWidth + x] = shade }
        }
        return PixelRaster.image(pixels, width: artWidth, height: artHeight, opaque: true)
    }

    private func applyAppearance() {
        withoutAnimation { checkerLayer.contents = makeChecker() }
        layoutArt()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyAppearance() }
    }

    /// One device pixel in points (guarded: the trait is 0 before the view joins a window).
    private var devicePixel: CGFloat { 1 / max(traitCollection.displayScale, 1) }

    // MARK: Layout and navigation

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if needsFit {
            fitToScreen()
        } else if bounds.size != lastBoundsSize {
            origin.x += (bounds.width - lastBoundsSize.width) / 2
            origin.y += (bounds.height - lastBoundsSize.height) / 2
            clampAndLayout()
        }
        lastBoundsSize = bounds.size
    }

    /// Centres the artwork below the toolbar at the largest cell size that fits and is a
    /// whole number of device pixels, so every cell renders the same width.
    func fitToScreen() {
        guard bounds.width > 0, bounds.height > 0, artWidth > 0 else {
            needsFit = true
            return
        }
        needsFit = false
        let margin: CGFloat = 32
        let area = bounds.inset(by: UIEdgeInsets(top: safeAreaInsets.top + 8 + Theme.barHeight + margin,
                                                 left: safeAreaInsets.left + margin,
                                                 bottom: safeAreaInsets.bottom + margin,
                                                 right: safeAreaInsets.right + margin))
        let pixel = devicePixel
        var fit = min(area.width / CGFloat(artWidth), area.height / CGFloat(artHeight))
        if fit >= pixel { fit = (fit / pixel).rounded(.down) * pixel }
        fitScale = max(fit, 0.05)
        scale = fitScale
        origin = CGPoint(x: ((area.midX - CGFloat(artWidth) * scale / 2) / pixel).rounded() * pixel,
                         y: ((area.midY - CGFloat(artHeight) * scale / 2) / pixel).rounded() * pixel)
        layoutArt()
    }

    private var minScale: CGFloat { fitScale / 4 }
    private var maxScale: CGFloat { max(fitScale * 2, 120) }

    private func clampAndLayout() {
        let keep: CGFloat = 48
        let width = CGFloat(artWidth) * scale, height = CGFloat(artHeight) * scale
        origin.x = min(max(origin.x, keep - width), bounds.width - keep)
        origin.y = min(max(origin.y, keep - height), bounds.height - keep)
        layoutArt()
    }

    private func layoutArt() {
        let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(artWidth) * scale, height: CGFloat(artHeight) * scale)
        withoutAnimation {
            artLayer.position = origin
            artLayer.transform = CATransform3DMakeScale(scale, scale, 1)
            shadowLayer.frame = rect
            shadowLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)

            let showGrid = gridEnabled && scale >= Self.minGridCell
            gridLayer.isHidden = !showGrid
            if showGrid {
                let hairline = devicePixel
                gridLayer.frame = rect
                gridColumns.frame = gridLayer.bounds
                gridRows.frame = gridLayer.bounds
                gridColumns.instanceCount = max(artWidth - 1, 0)
                gridColumns.instanceTransform = CATransform3DMakeTranslation(scale, 0, 0)
                columnLine.frame = CGRect(x: scale - hairline / 2, y: 0, width: hairline, height: rect.height)
                gridRows.instanceCount = max(artHeight - 1, 0)
                gridRows.instanceTransform = CATransform3DMakeTranslation(0, scale, 0)
                rowLine.frame = CGRect(x: 0, y: scale - hairline / 2, width: rect.width, height: hairline)
            }
        }
        layoutHover()
    }

    private func layoutHover() {
        guard let p = hoverPixel, case .idle = input else {
            withoutAnimation { hoverLayer.isHidden = true }
            return
        }
        let size = model.brushSize
        let offset = (size - 1) / 2
        let cells = CGRect(x: p.x - offset, y: p.y - offset, width: size, height: size)
            .intersection(CGRect(x: 0, y: 0, width: artWidth, height: artHeight))
        withoutAnimation {
            hoverLayer.isHidden = cells.isNull || cells.isEmpty
            guard !hoverLayer.isHidden else { return }
            hoverLayer.frame = CGRect(x: origin.x + cells.minX * scale, y: origin.y + cells.minY * scale,
                                      width: cells.width * scale, height: cells.height * scale)
            let line: CGFloat = 1
            hoverLayer.borderWidth = line
            hoverInnerLayer.borderWidth = line
            hoverInnerLayer.frame = hoverLayer.bounds.insetBy(dx: line, dy: line)
        }
    }

    private func pixel(at point: CGPoint) -> PixelPoint {
        PixelPoint(x: Int(((point.x - origin.x) / scale).rounded(.down)),
                   y: Int(((point.y - origin.y) / scale).rounded(.down)))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began { abandonFingerStroke() }
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            guard gesture.numberOfTouches != 1 else { return }
            origin.x += translation.x
            origin.y += translation.y
            clampAndLayout()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began { abandonFingerStroke() }
            let factor = gesture.scale
            gesture.scale = 1
            guard gesture.numberOfTouches != 1 else { return }
            let anchor = gesture.location(in: self)
            let newScale = min(max(scale * factor, minScale), maxScale)
            origin.x = anchor.x - (anchor.x - origin.x) * newScale / scale
            origin.y = anchor.y - (anchor.y - origin.y) * newScale / scale
            scale = newScale
            clampAndLayout()
        default:
            break
        }
    }

    @objc private func handleUndoTap() { model.undo() }
    @objc private func handleRedoTap() { model.redo() }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: hoverPixel = pixel(at: gesture.location(in: self))
        default: hoverPixel = nil
        }
        layoutHover()
    }

    private func cancelNavigation() {
        for gesture in [panGesture, pinchGesture, undoTap, redoTap] as [UIGestureRecognizer] {
            gesture.isEnabled = false
            gesture.isEnabled = true
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        pencilTouch == nil && touch.type != .pencil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Touch input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch.type == .pencil {
                pencilTouch = touch
                cancelNavigation()
                if case .drawing(let current) = input, current !== touch { model.cancelStroke() }
                beginStroke(touch)
                continue
            }
            guard pencilTouch == nil else { continue }  // palm rejection
            if case .blocked = input, otherActiveTouches(excluding: touches, in: event) == 0 { input = .idle }
            switch input {
            case .idle:
                let fingers = otherActiveTouches(excluding: [], in: event)
                // Honour the system "Only Draw with Apple Pencil" setting for finger touches.
                let pencilOnly = touch.type == .direct && UIPencilInteraction.prefersPencilOnlyDrawing
                if fingers <= 1 && !isNavigating && !pencilOnly { beginStroke(touch) } else { input = .blocked }
            case .drawing(let current) where current.type != .pencil:
                model.cancelStroke()
                input = .blocked
            case .drawing, .blocked:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard case .drawing(let touch) = input, touches.contains(touch) else { return }
        var changed = false
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            if model.continueStroke(to: pixel(at: sample.preciseLocation(in: self))) { changed = true }
        }
        if changed { refreshActiveLayer() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if case .drawing(let touch) = input, touches.contains(touch) {
            let point = pixel(at: touch.preciseLocation(in: self))
            if model.continueStroke(to: point) { refreshActiveLayer() }
            model.endStroke(at: point)
            input = .idle
        }
        finishTouches(touches, in: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if case .drawing(let touch) = input, touches.contains(touch) {
            model.cancelStroke()
            input = .idle
        }
        finishTouches(touches, in: event)
    }

    private func beginStroke(_ touch: UITouch) {
        input = .drawing(touch)
        layoutHover()
        if model.beginStroke(at: pixel(at: touch.preciseLocation(in: self))) { refreshActiveLayer() }
    }

    private func finishTouches(_ touches: Set<UITouch>, in event: UIEvent?) {
        if let pencil = pencilTouch, touches.contains(pencil) { pencilTouch = nil }
        if case .blocked = input, otherActiveTouches(excluding: touches, in: event) == 0 { input = .idle }
        layoutHover()
    }

    /// Cancels a finger stroke when navigation takes over.
    private func abandonFingerStroke() {
        if case .drawing(let touch) = input, touch.type != .pencil {
            model.cancelStroke()
            input = .blocked
        }
    }

    private var isNavigating: Bool {
        [panGesture.state, pinchGesture.state].contains { $0 == .began || $0 == .changed }
    }

    /// Non-pencil touches still on the screen, not counting `excluded`.
    private func otherActiveTouches(excluding excluded: Set<UITouch>, in event: UIEvent?) -> Int {
        event?.allTouches?.filter { touch in
            touch.type != .pencil && !excluded.contains(touch) && touch.phase != .ended && touch.phase != .cancelled
        }.count ?? 0
    }

    // MARK: UIPencilInteractionDelegate

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        model.performPencilAction(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        model.performPencilAction(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        model.performPencilAction(UIPencilInteraction.preferredSqueezeAction)
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
