import AppKit
import ImageIO
import UniformTypeIdentifiers

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let shape = CGPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880), cornerWidth: 198, cornerHeight: 198, transform: nil)
        context.saveGState(); context.addPath(shape); context.clip()
        let colors = [CGColor(srgbRed: 0.16, green: 0.27, blue: 0.82, alpha: 1), CGColor(srgbRed: 0.47, green: 0.66, blue: 1, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 800, y: 980), options: [])
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.4)); context.setLineWidth(8); context.addPath(shape); context.strokePath()
        context.saveGState(); context.translateBy(x: 520, y: 505); context.rotate(by: -0.14)
        context.setFillColor(CGColor(gray: 1, alpha: 0.19))
        context.addPath(CGPath(roundedRect: CGRect(x: -182, y: -164, width: 380, height: 360), cornerWidth: 58, cornerHeight: 58, transform: nil)); context.fillPath()
        context.restoreGState()
        context.setFillColor(CGColor(gray: 1, alpha: 0.28))
        context.addPath(CGPath(roundedRect: CGRect(x: 267, y: 362, width: 354, height: 350), cornerWidth: 60, cornerHeight: 60, transform: nil)); context.fillPath()
        let lasso = CGMutablePath()
        lasso.move(to: CGPoint(x: 352, y: 370))
        lasso.addCurve(to: CGPoint(x: 717, y: 516), control1: CGPoint(x: 175, y: 413), control2: CGPoint(x: 343, y: 772))
        lasso.addCurve(to: CGPoint(x: 391, y: 377), control1: CGPoint(x: 866, y: 294), control2: CGPoint(x: 440, y: 257))
        lasso.addCurve(to: CGPoint(x: 388, y: 239), control1: CGPoint(x: 346, y: 453), control2: CGPoint(x: 284, y: 300))
        context.setLineWidth(40); context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.addPath(lasso); context.strokePath()
        let suffix = scale == 2 ? "@2x" : ""
        let url = destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(output) else { fatalError("Could not write icon") }
    }
}
