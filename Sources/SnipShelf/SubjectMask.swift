import CoreImage
import Vision

enum SubjectMask {
    static func cutout(_ image: CGImage, points: [CGPoint]) throws -> CGImage? {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        try Task.checkCancellation()
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
        let bounds = path.boundingBoxOfPath.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !bounds.isNull, bounds.width >= 3, bounds.height >= 3,
              let source = image.cropping(to: bounds) else { return nil }
        let localPoints = points.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
        // Give small screen selections the same analysis detail as standalone images.
        // Keep the rectangular source intact for recognition; apply the lasso only to the result.
        let handler = VNImageRequestHandler(cgImage: source)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first else { return nil }
        let instances = try selectedInstances(in: observation.instanceMask, points: localPoints,
            imageSize: CGSize(width: source.width, height: source.height))
        guard !instances.isEmpty else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        try Task.checkCancellation()
        let mask = CIImage(cvPixelBuffer: buffer)
        guard let alpha = CIContext().createCGImage(mask, from: mask.extent, format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()) else {
            throw ShelfError("The subject mask could not be rendered.")
        }
        // Apply only alpha to the original pixels, including any existing transparency.
        return try ImageCore.crop(source, points: localPoints, mask: alpha)
    }

    static func selectedInstances(in mask: CVPixelBuffer, points: [CGPoint], imageSize: CGSize) throws -> IndexSet {
        guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let memory = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let bytes = memory.assumingMemoryBound(to: UInt8.self)
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
        var votes: [Int: Int] = [:]
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let label = Int(bytes[y * stride + x])
                let point = CGPoint(x: (CGFloat(x) + 0.5) * imageSize.width / CGFloat(width),
                                    y: (CGFloat(y) + 0.5) * imageSize.height / CGFloat(height))
                if label > 0, path.contains(point, using: .evenOdd) { votes[label, default: 0] += 1 }
            }
        }
        // ponytail: choose the most-overlapped instance; merged foreground/background people still need manual refinement.
        guard let selected = votes.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { return [] }
        return IndexSet(integer: selected)
    }
}
