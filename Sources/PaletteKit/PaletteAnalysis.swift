import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Foundation
import Vision

package struct PaletteError: LocalizedError {
    package let message: String
    package init(message: String) { self.message = message }
    package var errorDescription: String? { message }
}

package struct PaletteSwatch: Equatable, Sendable {
    package var rgb: SIMD3<Double>
    package var fraction: Double
    package init(rgb: SIMD3<Double>, fraction: Double) { self.rgb = rgb; self.fraction = fraction }
    package var hex: String {
        String(format: "#%02X%02X%02X", Int((rgb.x * 255).rounded()), Int((rgb.y * 255).rounded()), Int((rgb.z * 255).rounded()))
    }
    package var percentage: String { fraction < 0.01 ? "<1%" : String(format: "%.0f%%", fraction * 100) }
    var lab: SIMD3<Double> {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = linear(rgb.x), g = linear(rgb.y), b = linear(rgb.z)
        // Oklab, public-domain conversion: https://bottosson.github.io/posts/oklab/
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    func distance(to other: PaletteSwatch) -> Double {
        let delta = lab - other.lab
        return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    }
}

package enum PaletteAnalysis {
    package static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let linearRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private static let renderer = CIContext(options: [.workingColorSpace: linearRGB, .cacheIntermediates: false])

    package static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PaletteError(message: "This file could not be opened as an image.")
        }
        return try decode(source)
    }
    package static func load(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PaletteError(message: "The clipboard does not contain a readable image.")
        }
        return try decode(source)
    }
    private static func decode(_ source: CGImageSource) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= 100_000_000 / height else {
            throw PaletteError(message: "Choose an image smaller than 100 megapixels.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PaletteError(message: "This image could not be decoded. Try PNG, JPEG, HEIC, or WebP.")
        }
        return image
    }

    package static func subject(in image: CGImage) throws -> CGImage {
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw PaletteError(message: "No subject found. Choose Whole Image to include the background.")
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let mask = CIImage(cvPixelBuffer: buffer)
        guard let alpha = renderer.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else {
            throw PaletteError(message: "The subject mask could not be rendered. Try Whole Image.")
        }
        try Task.checkCancellation()
        return try applying(mask: alpha, to: image)
    }

    package static func applying(mask: CGImage, to image: CGImage) throws -> CGImage {
        guard mask.width == image.width, mask.height == image.height,
              let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: image.width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PaletteError(message: "The subject mask could not be applied to this image. Try Whole Image.")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Apply only alpha: white hair and existing transparency keep their original colors and coverage.
        canvas.clip(to: bounds, mask: mask)
        canvas.draw(image, in: bounds)
        guard let cutout = canvas.makeImage() else { throw PaletteError(message: "The subject could not be rendered. Try Whole Image.") }
        return cutout
    }

    package static func colors(in image: CGImage, limit: Int = 3, mergeDistance: Double = 0.08) throws -> [PaletteSwatch] {
        guard (1...6).contains(limit), mergeDistance.isFinite, (0...0.3).contains(mergeDistance) else {
            throw PaletteError(message: "The palette settings are out of range.")
        }
        try Task.checkCancellation()
        // ponytail: 384px sampling and 16 candidates bound cost; increase these if tiny accents need finer sampling.
        let scale = min(1, 384.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let sample = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PaletteError(message: "The image could not be prepared for analysis.")
        }
        sample.interpolationQuality = .high
        sample.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let sampledImage = sample.makeImage() else { throw PaletteError(message: "The image could not be sampled.") }
        let filter = CIFilter.kMeans()
        filter.inputImage = CIImage(cgImage: sampledImage)
        filter.extent = CGRect(x: 0, y: 0, width: width, height: height)
        filter.count = 16; filter.passes = 12; filter.perceptual = true
        guard let palette = filter.outputImage else { throw PaletteError(message: "Color analysis is unavailable.") }
        var pixels = [Float](repeating: 0, count: 16 * 4)
        // CIKMeans returns palette data: sRGB centroids and population in alpha.
        // A linear output space avoids applying another transfer curve to those values.
        renderer.render(palette, toBitmap: &pixels, rowBytes: 16 * 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 1),
                        format: .RGBAf, colorSpace: linearRGB)
        try Task.checkCancellation()
        var colors: [PaletteSwatch] = stride(from: 0, to: pixels.count, by: 4).compactMap { i in
            guard pixels[i + 3] > 0.00001, pixels[i..<i + 4].allSatisfy(\.isFinite) else { return nil }
            let channels = pixels[i..<i + 3].map { min(1, max(0, Double($0))) }
            return PaletteSwatch(rgb: SIMD3(channels[0], channels[1], channels[2]), fraction: Double(pixels[i + 3]))
        }
        let total = colors.reduce(0) { $0 + $1.fraction }
        guard total > 0 else { return [] }
        for i in colors.indices { colors[i].fraction /= total }
        colors.sort { $0.fraction == $1.fraction ? $0.hex < $1.hex : $0.fraction > $1.fraction }
        while colors.count > 1 {
            var closest: (Int, Int)?
            var distance = max(0.002, mergeDistance)
            for a in colors.indices {
                for b in colors.indices where b > a {
                    let candidate = colors[a].distance(to: colors[b])
                    if candidate < distance { distance = candidate; closest = (a, b) }
                }
            }
            guard let (a, b) = closest else { break }
            let weight = colors[a].fraction + colors[b].fraction
            colors[a].rgb = (colors[a].rgb * colors[a].fraction + colors[b].rgb * colors[b].fraction) / weight
            colors[a].fraction = weight
            colors.remove(at: b)
        }
        colors.sort { $0.fraction > $1.fraction }
        guard colors.count > limit else { return colors }

        // Keep the broadest areas, reserving one slot for a distinct smaller color.
        var selected = Array(colors.prefix(max(1, limit - 1)))
        if limit > 1 {
            let candidates = colors.dropFirst(selected.count)
            let accent = candidates.max { a, b in
                func score(_ color: PaletteSwatch) -> Double {
                    guard color.fraction >= 0.005 else { return 0 }
                    let contrast = selected.map { color.distance(to: $0) }.min() ?? 0
                    return contrast * contrast * pow(color.fraction, 0.25)
                }
                return score(a) < score(b)
            }!
            selected.append(accent)
        }
        for i in selected.indices { selected[i].fraction = 0 }
        for color in colors {
            let nearest = selected.indices.min { color.distance(to: selected[$0]) < color.distance(to: selected[$1]) }!
            selected[nearest].fraction += color.fraction
        }
        return selected.sorted { $0.fraction > $1.fraction }
    }
}
