import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ShelfError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CaptureSession {
    let image: CGImage
    /// All selection coordinates are measured from the top-left, in image pixels.
    func pixelPoint(_ point: CGPoint, in displayedRect: CGRect) -> CGPoint {
        CGPoint(x: (point.x - displayedRect.minX) * CGFloat(image.width) / displayedRect.width,
                y: (point.y - displayedRect.minY) * CGFloat(image.height) / displayedRect.height)
    }
}

enum ImageCore {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let maxPixels = 100_000_000

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ShelfError("This file could not be opened as an image.")
        }
        return try decode(source)
    }

    static func load(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ShelfError("The clipboard does not contain a readable image.")
        }
        return try decode(source)
    }

    private static func decode(_ source: CGImageSource) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= maxPixels / height else {
            throw ShelfError("Choose an image smaller than 100 megapixels.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShelfError("This image format could not be decoded. Try PNG, JPEG, WebP, or HEIC.")
        }
        return try sRGB(image)
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= maxPixels / height,
              let context = CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ShelfError("There is not enough memory to create this image.")
        }
        return context
    }

    static func sRGB(_ image: CGImage) throws -> CGImage {
        let context = try context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let output = context.makeImage() else { throw ShelfError("The image could not be rendered.") }
        return output
    }

    static func crop(_ image: CGImage, points: [CGPoint]) throws -> CGImage {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ShelfError("Draw a closed area with at least three points.")
        }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        let rect = path.boundingBoxOfPath.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 3, rect.height >= 3 else {
            throw ShelfError("The selection is too small. Draw a larger area.")
        }
        let context = try context(width: Int(rect.width), height: Int(rect.height))
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -rect.minX, ty: rect.maxY)
        guard let mask = path.copy(using: &transform) else { throw ShelfError("The selection could not be created.") }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.addPath(mask)
        context.clip(using: .evenOdd)
        context.draw(image, in: CGRect(x: -rect.minX, y: rect.maxY - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        // A bow-tie can have zero signed area but visible even-odd lobes. Inspect coverage instead.
        guard let memory = context.data else { throw ShelfError("The selection could not be rendered.") }
        let bytes = memory.assumingMemoryBound(to: UInt8.self)
        var alphaSum: Int = 0
        for y in 0..<context.height {
            for x in 0..<context.width { alphaSum += Int(bytes[y * context.bytesPerRow + x * 4 + 3]) }
            if alphaSum >= 9 * 255 { break }
        }
        guard alphaSum >= 9 * 255, let result = context.makeImage() else {
            throw ShelfError("The selection contains too few visible pixels.")
        }
        return result
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ShelfError("PNG export is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShelfError("The PNG could not be encoded.") }
        return data as Data
    }

    static func thumbnail(_ image: CGImage, maxSize: CGFloat = 320) throws -> CGImage {
        let scale = min(1, maxSize / CGFloat(max(image.width, image.height)))
        let context = try context(width: max(1, Int(CGFloat(image.width) * scale)),
                                  height: max(1, Int(CGFloat(image.height) * scale)))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let result = context.makeImage() else { throw ShelfError("The preview could not be created.") }
        return result
    }
}
