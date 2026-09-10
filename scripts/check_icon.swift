import Foundation
import CoreGraphics
import ImageIO

// Run after iconutil to check the packaged representations, not just the source PNG.
let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon.icns")
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
    fatalError("Cannot decode \(url.path)")
}
var sizes = Set<Int>()
for index in 0..<CGImageSourceGetCount(source) {
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
          image.width == image.height else { fatalError("Invalid icon representation \(index)") }
    let size = image.width
    sizes.insert(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for corner in [0, size - 1, size * (size - 1), size * size - 1] {
        guard pixels[corner * 4 + 3] == 0 else { fatalError("Opaque corner at \(size)px") }
    }
    let center = (size / 2 * size + size / 2) * 4
    guard pixels[center] > 180, pixels[center + 1] > 180,
          pixels[center + 2] > 150, pixels[center + 3] == 255 else {
        fatalError("Missing ivory sticker at \(size)px; check for stale artwork")
    }
}
guard sizes == [16, 32, 64, 128, 256, 512, 1024] else {
    fatalError("Incomplete icon sizes: \(sizes.sorted())")
}
print("Icon OK: all seven pixel sizes, transparent corners, ivory sticker. \(url.path)")
