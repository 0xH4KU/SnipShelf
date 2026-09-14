import CoreGraphics

/// One continuous brush stroke on a cutout, in source-image pixels.
final class MaskBrush {
    let context: CGContext
    private let original: CGImage
    private let origin: CGPoint
    private let diameter: CGFloat
    private let restoring: Bool
    private var previous: CGPoint

    init(image: CGImage, original: CGImage, origin: CGPoint, start: CGPoint,
         diameter: CGFloat, restoring: Bool) throws {
        guard image.width == original.width, image.height == original.height,
              origin.x.isFinite, origin.y.isFinite, start.x.isFinite, start.y.isFinite,
              diameter.isFinite, (1...256).contains(diameter) else {
            throw ShelfError("The brush does not match this selection.")
        }
        context = try ImageCore.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        self.original = original; self.origin = origin; self.diameter = diameter
        self.restoring = restoring; previous = start
    }

    func paint(to point: CGPoint) throws -> CGImage {
        guard point.x.isFinite, point.y.isFinite else { throw ShelfError("The brush position is invalid.") }
        func local(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - origin.x, y: CGFloat(context.height) - (p.y - origin.y))
        }
        let from = local(previous), to = local(point)
        let path = CGMutablePath()
        let brush: CGPath
        if hypot(to.x - from.x, to.y - from.y) < 0.001 {
            path.addEllipse(in: CGRect(x: to.x - diameter / 2, y: to.y - diameter / 2, width: diameter, height: diameter))
            brush = path
        } else {
            path.move(to: from); path.addLine(to: to)
            brush = path.copy(strokingWithWidth: diameter, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        context.saveGState()
        context.addPath(brush); context.clip()
        let rect = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        if restoring {
            // Copy the original lasso crop, so repeated passes never accumulate source alpha.
            context.setBlendMode(.copy); context.draw(original, in: rect)
        } else { context.clear(rect) }
        context.restoreGState()
        previous = point
        // ponytail: source-size raster snapshots; tile large cutouts if measured brush latency requires it.
        guard let image = context.makeImage() else { throw ShelfError("The brush stroke could not be rendered.") }
        return image
    }
}
