import Foundation
import CoreGraphics
import Vision

/// A short adaptive tether: steadies slow motion without delaying deliberate fast strokes.
struct LassoStabilizer {
    private(set) var point: CGPoint?
    private var previousInput: CGPoint?
    private var previousTime: TimeInterval?
    private var velocity = CGPoint.zero
    mutating func reset() { point = nil; previousInput = nil; previousTime = nil; velocity = .zero }
    mutating func append(_ input: CGPoint, strength: CGFloat, pixelsPerPoint: CGFloat, timestamp: TimeInterval? = nil) -> CGPoint {
        defer { previousInput = input; previousTime = timestamp }
        guard let previous = point, strength > 0 else { point = input; return input }
        let distance = hypot(input.x - previous.x, input.y - previous.y)
        // More room to suppress mouse jitter; lag stays below 1.8 pt at the default, 3 pt at full strength.
        let scale = max(0.001, pixelsPerPoint)
        let radius = (1 + 11 * min(1, strength)) * scale
        var weight = min(1, max(0.18, distance / radius))
        if let timestamp {
            guard let previousTime, let previousInput, timestamp.isFinite,
                  timestamp > previousTime, timestamp - previousTime <= 0.25 else {
                velocity = .zero; point = input; return input
            }
            let dt = CGFloat(timestamp - previousTime)
            let speedWeight = 1 - exp(-2 * .pi * 10 * dt)
            velocity.x += ((input.x - previousInput.x) / (dt * scale) - velocity.x) * speedWeight
            velocity.y += ((input.y - previousInput.y) / (dt * scale) - velocity.y) * speedWeight
            let speed = hypot(velocity.x, velocity.y)
            // Speed-adaptive low-pass filtering, measured in screen points and seconds.
            let cutoff = 5 - 3.5 * min(1, strength) + 0.025 * speed
            weight = 1 - exp(-2 * .pi * cutoff * dt)
            var quick = min(1, max(0, (speed - 180) / 540))
            quick = quick * quick * (3 - 2 * quick)
            weight += (1 - weight) * quick
            // ponytail: retain the existing lag ceiling; tune against physical devices in Lab before promoting.
            weight = max(weight, 1 - radius / (4 * max(distance, 0.000001)))
        }
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
    private let arcLengths: [[CGFloat]]
    private var segments: [Segment] = []
    private var cells: [Cell: [Int]] = [:]
    private let cellSize: CGFloat
    var isEmpty: Bool { segments.isEmpty }

    init(contours: [[CGPoint]], cellSize: CGFloat = 32) {
        self.contours = contours
        arcLengths = contours.map { points in
            var lengths: [CGFloat] = [0]
            for i in points.indices {
                let next = points[(i + 1) % points.count]
                lengths.append(lengths.last! + hypot(next.x - points[i].x, next.y - points[i].y))
            }
            return lengths
        }
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
        let reach = radius * (previous == nil ? 1 : 2)
        let minCell = cell(at: CGPoint(x: point.x - reach, y: point.y - reach))
        let maxCell = cell(at: CGPoint(x: point.x + reach, y: point.y + reach))
        var candidates = Set<Int>()
        for x in minCell.x...maxCell.x { for y in minCell.y...maxCell.y { candidates.formUnion(cells[Cell(x: x, y: y)] ?? []) } }
        var hits: [Int: Hit] = [:]
        var held: Hit?
        for id in candidates.sorted() {
            let s = segments[id]
            let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y
            let t = min(1, max(0, ((point.x - s.a.x) * dx + (point.y - s.a.y) * dy) / (dx * dx + dy * dy)))
            let projected = CGPoint(x: s.a.x + t * dx, y: s.a.y + t * dy)
            let distance = hypot(point.x - projected.x, point.y - projected.y)
            let hit = Hit(point: projected, contour: s.contour, segment: s.index, t: t, distance: distance)
            if distance <= radius && distance < (hits[s.contour]?.distance ?? .infinity) { hits[s.contour] = hit }
            if let previous, s.contour == previous.contour, distance <= reach {
                let lengths = arcLengths[s.contour]
                let start = lengths[previous.segment] + previous.t * (lengths[previous.segment + 1] - lengths[previous.segment])
                let end = lengths[s.index] + t * (lengths[s.index + 1] - lengths[s.index])
                let arc = abs(end - start)
                let direct = hypot(projected.x - previous.point.x, projected.y - previous.point.y)
                // Stay on the local branch, even when another side of the same outline is closer.
                if min(arc, lengths.last! - arc) <= direct * 1.6 + radius,
                   distance < (held?.distance ?? .infinity) { held = hit }
            }
        }
        if let held { hits[held.contour] = held }
        return hits.values.sorted {
            if ($0.contour == held?.contour) != ($1.contour == held?.contour) { return $0.contour == held?.contour }
            return $0.distance == $1.distance ? $0.contour < $1.contour : $0.distance < $1.distance
        }
    }

    /// Freehand guidance never follows a contour: it only nudges toward an unambiguous, parallel edge.
    func nudged(_ point: CGPoint, movement: CGPoint, pixelsPerPoint scale: CGFloat) -> CGPoint {
        let travel = hypot(movement.x, movement.y)
        guard scale.isFinite, scale > 0, point.x.isFinite, point.y.isFinite,
              travel.isFinite, travel > 0 else { return point }
        let radius = 4 * scale
        let first = cell(at: CGPoint(x: point.x - radius, y: point.y - radius))
        let last = cell(at: CGPoint(x: point.x + radius, y: point.y + radius))
        guard last.x - first.x <= 8, last.y - first.y <= 8 else { return point }
        var nearby = Set<Int>()
        var entries = 0
        for x in first.x...last.x { for y in first.y...last.y {
            let ids = cells[Cell(x: x, y: y)] ?? []
            entries += ids.count
            // ponytail: dense regions yield to freehand after 256 index entries; no frame waits for exhaustive search.
            guard entries <= 256 else { return point }
            nearby.formUnion(ids)
        } }
        var best: (point: CGPoint, distance: CGFloat, alignment: CGFloat)?
        var otherDistance = CGFloat.infinity
        for id in nearby.sorted() {
            let segment = segments[id]
            let dx = segment.b.x - segment.a.x, dy = segment.b.y - segment.a.y
            let length = hypot(dx, dy)
            let t = ((point.x - segment.a.x) * dx + (point.y - segment.a.y) * dy) / (length * length)
            // Fade out near vertices instead of pulling the hand around a corner.
            guard t > 0, t < 1 else { continue }
            let projected = CGPoint(x: segment.a.x + t * dx, y: segment.a.y + t * dy)
            let distance = hypot(projected.x - point.x, projected.y - point.y)
            guard distance < radius else { continue }
            let alignment = abs(movement.x * dx + movement.y * dy) / (travel * length)
            let endFade = min(1, min(t, 1 - t) * length / (2 * scale))
            if let old = best, hypot(projected.x - old.point.x, projected.y - old.point.y) < 0.75 * scale {
                // Opposite-polarity Vision passes can describe the same physical border.
                continue
            }
            if distance < (best?.distance ?? .infinity) {
                otherDistance = min(otherDistance, best?.distance ?? .infinity)
                best = (projected, distance, max(0, (alignment - 0.8) / 0.2) * endFade)
            } else { otherDistance = min(otherDistance, distance) }
        }
        guard let best else { return point }
        let proximity = 1 - best.distance / radius
        let confidence = min(1, max(0, (otherDistance - best.distance) / (2 * scale)))
        let motionFade = min(1, travel / (0.5 * scale))
        let weight = proximity * proximity * (3 - 2 * proximity) * best.alignment * confidence * motionFade
        // Smooth falloff bounds correction to about one screen point, with no capture/release threshold.
        return CGPoint(x: point.x + (best.point.x - point.x) * weight,
                       y: point.y + (best.point.y - point.y) * weight)
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
    func candidates(to point: CGPoint, radius: CGFloat, previous: ContourMap.Hit? = nil,
                    movement: CGPoint = .zero) -> [ContourMap.Hit] {
        guard point.x.isFinite, point.y.isFinite, radius.isFinite, radius > 0,
              width > 2, height > 2, let bytes = CFDataGetBytePtr(data) else { return [] }
        let predicted = previous.flatMap { $0.contour < 0 ? CGPoint(x: $0.point.x + movement.x, y: $0.point.y + movement.y) : nil }
        let reach = radius * (predicted == nil ? 1 : 2)
        let left = max(1, Int(floor(point.x - reach))), right = min(width - 2, Int(ceil(point.x + reach)))
        let top = max(1, Int(floor(point.y - reach))), bottom = min(height - 2, Int(ceil(point.y + reach)))
        guard left <= right, top <= bottom else { return [] }
        // ponytail: bounded sampling (about 100×100 while held); local multiscale refinement if fine edges are missed.
        let step = max(1, Int(ceil(radius / 24)))
        var scored: [(CGFloat, ContourMap.Hit)] = []
        var held: (distance: CGFloat, hit: ContourMap.Hit)?
        // Keep the grid anchored to the image as the pointer moves.
        for y in Swift.stride(from: ((top + step - 1) / step) * step, through: bottom, by: step) {
            for x in Swift.stride(from: ((left + step - 1) / step) * step, through: right, by: step) {
                let dx = CGFloat(x) + 0.5 - point.x, dy = CGFloat(y) + 0.5 - point.y
                let distance = hypot(dx, dy)
                guard distance <= reach else { continue }
                var contrast = 0
                for channel in 0..<4 {
                    let horizontal = abs(Int(bytes[y * stride + (x + 1) * 4 + channel]) - Int(bytes[y * stride + (x - 1) * 4 + channel]))
                    let vertical = abs(Int(bytes[(y + 1) * stride + x * 4 + channel]) - Int(bytes[(y - 1) * stride + x * 4 + channel]))
                    contrast = max(contrast, horizontal, vertical)
                }
                guard contrast >= 24 else { continue }
                let hit = ContourMap.Hit(point: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), contour: -1,
                                         segment: y * width + x, t: 0, distance: distance)
                if distance <= radius { scored.append((distance / radius - CGFloat(contrast) / 255 * 0.2, hit)) }
                if let predicted {
                    let residual = hypot(hit.point.x - predicted.x, hit.point.y - predicted.y)
                    // ponytail: local prediction tracks simple pixel borders; complex junctions need contour topology.
                    if residual <= max(2, CGFloat(step) * 1.5), residual < (held?.distance ?? .infinity) { held = (residual, hit) }
                }
            }
        }
        scored.sort { $0.0 == $1.0 ? $0.1.segment < $1.1.segment : $0.0 < $1.0 }
        var result: [ContourMap.Hit] = held.map { [$0.hit] } ?? []
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
