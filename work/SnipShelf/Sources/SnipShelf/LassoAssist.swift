import Foundation
import CoreGraphics
import Vision

/// A short adaptive tether: steadies slow motion without delaying deliberate fast strokes.
struct LassoStabilizer {
    private(set) var point: CGPoint?
    mutating func reset() { point = nil }
    mutating func append(_ input: CGPoint, strength: CGFloat, pixelsPerPoint: CGFloat) -> CGPoint {
        guard let previous = point, strength > 0 else { point = input; return input }
        let distance = hypot(input.x - previous.x, input.y - previous.y)
        let radius = (1 + 6 * min(1, strength)) * max(0.001, pixelsPerPoint)
        let weight = min(1, max(0.18, distance / radius))
        let result = CGPoint(x: previous.x + (input.x - previous.x) * weight,
                             y: previous.y + (input.y - previous.y) * weight)
        point = result
        return result
    }
}

struct ContourMap: Sendable {
    struct Hit: Sendable {
        let point: CGPoint
        let contour: Int
        let segment: Int
        let t: CGFloat
        let distance: CGFloat
    }
    private struct Segment: Sendable {
        let a: CGPoint
        let b: CGPoint
        let contour: Int
        let index: Int
    }
    private struct Cell: Hashable, Sendable { let x: Int; let y: Int }
    let contours: [[CGPoint]]
    private var segments: [Segment] = []
    private var cells: [Cell: [Int]] = [:]
    private let cellSize: CGFloat
    var isEmpty: Bool { segments.isEmpty }

    init(contours: [[CGPoint]], cellSize: CGFloat = 32) {
        self.contours = contours
        self.cellSize = max(1, cellSize)
        for (id, contour) in contours.enumerated() where contour.count > 2 {
            for i in contour.indices {
                let a = contour[i], b = contour[(i + 1) % contour.count]
                guard hypot(b.x - a.x, b.y - a.y) > 0.001 else { continue }
                let segmentID = segments.count
                segments.append(Segment(a: a, b: b, contour: id, index: i))
                // Walk the line rather than filling its bounding box (long diagonals stay cheap).
                let steps = max(1, Int(ceil(max(abs(b.x - a.x), abs(b.y - a.y)) / self.cellSize)))
                var touched = Set<Cell>()
                for step in 0...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let cell = cell(at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    // Cover adjacent cells at grid crossings too.
                    for dx in -1...1 { for dy in -1...1 { touched.insert(Cell(x: cell.x + dx, y: cell.y + dy)) } }
                }
                for cell in touched { cells[cell, default: []].append(segmentID) }
            }
        }
    }
    private func cell(at point: CGPoint) -> Cell { Cell(x: Int(floor(point.x / cellSize)), y: Int(floor(point.y / cellSize))) }

    func nearest(to point: CGPoint, radius: CGFloat, previous: Hit? = nil) -> Hit? {
        candidates(to: point, radius: radius, previous: previous).first
    }
    func candidates(to point: CGPoint, radius: CGFloat, previous: Hit? = nil) -> [Hit] {
        guard radius > 0, radius.isFinite, point.x.isFinite, point.y.isFinite else { return [] }
        let reach = radius * (previous == nil ? 1 : 1.25)
        let minCell = cell(at: CGPoint(x: point.x - reach, y: point.y - reach))
        let maxCell = cell(at: CGPoint(x: point.x + reach, y: point.y + reach))
        var candidates = Set<Int>()
        for x in minCell.x...maxCell.x { for y in minCell.y...maxCell.y { candidates.formUnion(cells[Cell(x: x, y: y)] ?? []) } }
        var hits: [Int: Hit] = [:]
        for id in candidates.sorted() {
            let s = segments[id]
            let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y
            let t = min(1, max(0, ((point.x - s.a.x) * dx + (point.y - s.a.y) * dy) / (dx * dx + dy * dy)))
            let projected = CGPoint(x: s.a.x + t * dx, y: s.a.y + t * dy)
            let distance = hypot(point.x - projected.x, point.y - projected.y)
            let hit = Hit(point: projected, contour: s.contour, segment: s.index, t: t, distance: distance)
            let allowed = s.contour == previous?.contour ? reach : radius
            if distance <= allowed && distance < (hits[s.contour]?.distance ?? .infinity) { hits[s.contour] = hit }
        }
        // Small preference, not a lock: a meaningfully closer border always wins.
        func score(_ hit: Hit) -> CGFloat { hit.distance - (hit.contour == previous?.contour ? radius * 0.15 : 0) }
        return hits.values.sorted { score($0) == score($1) ? $0.contour < $1.contour : score($0) < score($1) }
    }

    /// Follow intervening vertices, so sparse mouse events don't cut across a contour's corner.
    func bridge(from start: Hit?, to end: Hit, radius: CGFloat) -> [CGPoint] {
        guard let start, start.contour >= 0, start.contour == end.contour else { return [end.point] }
        let contour = contours[end.contour]
        if start.segment == end.segment { return [end.point] }
        let direct = hypot(end.point.x - start.point.x, end.point.y - start.point.y)
        let limit = direct * 1.6 + radius
        func route(forward: Bool) -> [CGPoint]? {
            if start.segment == end.segment && (forward ? end.t >= start.t : end.t <= start.t) { return [end.point] }
            var result: [CGPoint] = []
            var segment = start.segment
            var distance: CGFloat = 0
            var last = start.point
            for _ in 0..<contour.count {
                let vertex = forward ? (segment + 1) % contour.count : segment
                distance += hypot(contour[vertex].x - last.x, contour[vertex].y - last.y)
                if distance > limit { return nil }
                last = contour[vertex]
                result.append(last)
                segment = (segment + (forward ? 1 : contour.count - 1)) % contour.count
                if segment == end.segment { break }
            }
            return result + [end.point]
        }
        func length(_ points: [CGPoint]) -> CGFloat {
            zip([start.point] + points, points).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
        let routes = [route(forward: true), route(forward: false)].compactMap { $0 }
        // Don't take a distant detour around a U-shape when the user crosses its opening.
        guard let chosen = routes.min(by: { length($0) < length($1) }), length(chosen) <= limit else { return [end.point] }
        return chosen
    }

    static func detect(in image: CGImage) throws -> ContourMap {
        // ponytail: 1536px analysis bounds Vision cost; increase/adapt it if large-image fine edges need more precision.
        let small = try ImageCore.thumbnail(image, maxSize: 1536)
        var contours: [[CGPoint]] = []
        for darkOnLight in [true, false] {
            try Task.checkCancellation()
            let context = try ImageCore.context(width: small.width, height: small.height)
            context.setFillColor(CGColor(gray: darkOnLight ? 1 : 0, alpha: 1))
            let rect = CGRect(x: 0, y: 0, width: small.width, height: small.height)
            context.fill(rect); context.draw(small, in: rect)
            guard let flattened = context.makeImage() else { continue }
            let request = VNDetectContoursRequest()
            request.contrastAdjustment = 1
            request.detectsDarkOnLight = darkOnLight
            request.maximumImageDimension = 1536
            try VNImageRequestHandler(cgImage: flattened).perform([request])
            try Task.checkCancellation()
            guard let observation = request.results?.first else { continue }
            for i in 0..<observation.contourCount {
                let contour = try observation.contour(at: i).polygonApproximation(epsilon: 0.5 / 1536)
                let points = contour.normalizedPoints.map {
                    CGPoint(x: CGFloat($0.x) * CGFloat(image.width), y: (1 - CGFloat($0.y)) * CGFloat(image.height))
                }
                if points.count > 2 { contours.append(points) }
            }
        }
        return ContourMap(contours: contours, cellSize: max(16, CGFloat(max(image.width, image.height)) / 96))
    }
}

/// Local, full-resolution edge sampling remains available before (or without) Vision.
/// Includes alpha contrast so silhouettes on transparency work as well as browser pixels.
struct PixelEdges: @unchecked Sendable {
    private let data: CFData
    private let width: Int
    private let height: Int
    private let stride: Int
    init?(_ image: CGImage) {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.alphaInfo == .premultipliedLast || image.alphaInfo == .last,
              image.bitmapInfo.intersection(.byteOrderMask) != .byteOrder32Little,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= image.bytesPerRow * image.height else { return nil }
        self.data = data; width = image.width; height = image.height; stride = image.bytesPerRow
    }
    func candidates(to point: CGPoint, radius: CGFloat) -> [ContourMap.Hit] {
        guard point.x.isFinite, point.y.isFinite, radius.isFinite, radius > 0,
              width > 2, height > 2, let bytes = CFDataGetBytePtr(data) else { return [] }
        let left = max(1, Int(floor(point.x - radius))), right = min(width - 2, Int(ceil(point.x + radius)))
        let top = max(1, Int(floor(point.y - radius))), bottom = min(height - 2, Int(ceil(point.y + radius)))
        guard left <= right, top <= bottom else { return [] }
        // ponytail: cap the search grid at roughly 50×50 for zoomed-out huge images; local multiscale refinement if needed.
        let step = max(1, Int(radius / 24))
        var scored: [(CGFloat, ContourMap.Hit)] = []
        for y in Swift.stride(from: top, through: bottom, by: step) {
            for x in Swift.stride(from: left, through: right, by: step) {
                let dx = CGFloat(x) + 0.5 - point.x, dy = CGFloat(y) + 0.5 - point.y
                let distance = hypot(dx, dy)
                guard distance <= radius else { continue }
                var contrast = 0
                for channel in 0..<4 {
                    let horizontal = abs(Int(bytes[y * stride + (x + 1) * 4 + channel]) - Int(bytes[y * stride + (x - 1) * 4 + channel]))
                    let vertical = abs(Int(bytes[(y + 1) * stride + x * 4 + channel]) - Int(bytes[(y - 1) * stride + x * 4 + channel]))
                    contrast = max(contrast, horizontal, vertical)
                }
                guard contrast >= 24 else { continue }
                let hit = ContourMap.Hit(point: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), contour: -1,
                                         segment: y * width + x, t: 0, distance: distance)
                scored.append((distance / radius - CGFloat(contrast) / 255 * 0.2, hit))
            }
        }
        scored.sort { $0.0 == $1.0 ? $0.1.segment < $1.1.segment : $0.0 < $1.0 }
        var result: [ContourMap.Hit] = []
        for (_, hit) in scored {
            if result.allSatisfy({ hypot($0.point.x - hit.point.x, $0.point.y - hit.point.y) >= max(2, radius * 0.45) }) {
                result.append(hit)
                if result.count == 6 { break }
            }
        }
        return result
    }
}

/// Continue at any point on a segment, including between sparsely sampled corners.
enum LassoPath {
    static func continuing(_ points: [CGPoint], near point: CGPoint, radius: CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return points + [point] }
        var best: (Int, CGPoint, CGFloat)?
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.000001, dx * dx + dy * dy)))
            let projected = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = hypot(point.x - projected.x, point.y - projected.y)
            if distance <= radius && distance < (best?.2 ?? .infinity) { best = (i, projected, distance) }
        }
        guard let best else { return points + [point] }
        return Array(points.prefix(best.0 + 1)) + [best.1]
    }
}
