import CoreGraphics

/// Page-box and rotation handling shared by on-screen rendering and export.
enum PDFGeometry {
    private static func box(of page: CGPDFPage) -> CGRect {
        let crop = page.getBoxRect(.cropBox)
        if crop.width > 1, crop.height > 1 { return crop }
        let media = page.getBoxRect(.mediaBox)
        return media.width > 1 && media.height > 1 ? media : CGRect(x: 0, y: 0, width: 612, height: 792)
    }

    private static func rotation(of page: CGPDFPage) -> Int {
        ((Int(page.rotationAngle) % 360) + 360) % 360
    }

    /// Size of the page as a reader sees it (crop box, rotation applied).
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let b = box(of: page)
        return rotation(of: page) % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// Draws `page` so that it exactly fills `dest`.
    /// `ctx` must use Core Graphics' native orientation (y pointing up).
    static func draw(_ page: CGPDFPage, in ctx: CGContext, dest: CGRect) {
        let b = box(of: page)
        let shown = displaySize(of: page)
        ctx.saveGState()
        ctx.translateBy(x: dest.minX, y: dest.minY)
        ctx.scaleBy(x: dest.width / shown.width, y: dest.height / shown.height)
        switch rotation(of: page) {
        case 90:
            ctx.translateBy(x: 0, y: shown.height)
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: shown.width, y: shown.height)
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: shown.width, y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.clip(to: b)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}
