import CoreGraphics
import PaletteKit

enum PaletteExample: String, CaseIterable {
    case stillLife = "Still Life", smallAccent = "Small Accent", cutout = "Transparent Cutout", monochrome = "One Color"

    func image() throws -> CGImage {
        guard let canvas = CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8, bytesPerRow: 960 * 4,
                                     space: PaletteAnalysis.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PaletteError(message: "The example could not be drawn.")
        }
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { canvas.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)) }
        if self == .monochrome {
            color(0.18, 0.44, 0.36); canvas.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        } else {
            if self != .cutout {
                color(0.95, 0.93, 0.87); canvas.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
                color(0.88, 0.85, 0.77); canvas.fill(CGRect(x: 0, y: 0, width: 960, height: 160))
            }
            color(0.16, 0.37, 0.30)
            canvas.addPath(CGPath(roundedRect: CGRect(x: 290, y: 100, width: 300, height: 390), cornerWidth: 100, cornerHeight: 100, transform: nil)); canvas.fillPath()
            color(0.20, 0.42, 0.35)
            canvas.fillEllipse(in: CGRect(x: 335, y: 350, width: 210, height: 150))
            color(0.23, 0.46, 0.38)
            canvas.fillEllipse(in: CGRect(x: 370, y: 390, width: 140, height: 100))
            color(0.89, 0.33, 0.12)
            let size: CGFloat = self == .smallAccent ? 90 : 210
            canvas.fillEllipse(in: CGRect(x: 630, y: 125, width: size, height: size))
        }
        guard let image = canvas.makeImage() else { throw PaletteError(message: "The example could not be rendered.") }
        return image
    }
}
