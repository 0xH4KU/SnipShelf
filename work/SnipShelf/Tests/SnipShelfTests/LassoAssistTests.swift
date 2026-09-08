import XCTest
import AppKit
@testable import SnipShelf

final class LassoAssistTests: XCTestCase {
    func testSteadinessSuppressesJitterWithoutDelayingFastMotion() {
        var filter = LassoStabilizer(), retina = LassoStabilizer()
        var rawEnergy: CGFloat = 0, smoothEnergy: CGFloat = 0
        for i in 0..<100 {
            let p = CGPoint(x: CGFloat(i) * 0.8, y: i % 2 == 0 ? 1 : -1)
            let a = filter.append(p, strength: 0.55, pixelsPerPoint: 1)
            XCTAssertLessThanOrEqual(hypot(a.x - p.x, a.y - p.y), 1)
            let b = retina.append(CGPoint(x: p.x * 2, y: p.y * 2), strength: 0.55, pixelsPerPoint: 2)
            XCTAssertEqual(a.x, b.x / 2, accuracy: 0.001)
            XCTAssertEqual(a.y, b.y / 2, accuracy: 0.001)
            if i > 10 { rawEnergy += p.y * p.y; smoothEnergy += a.y * a.y }
        }
        XCTAssertLessThan(smoothEnergy, rawEnergy * 0.4)
        XCTAssertEqual(filter.append(CGPoint(x: 150, y: 40), strength: 0.55, pixelsPerPoint: 1), CGPoint(x: 150, y: 40))
        XCTAssertEqual(filter.append(CGPoint(x: 151, y: 41), strength: 0, pixelsPerPoint: 1), CGPoint(x: 151, y: 41))
        filter.reset()
        XCTAssertEqual(filter.append(.zero, strength: 1, pixelsPerPoint: 1), .zero)
    }
    func testPolygonSnapRadiusHysteresis() throws {
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 100), CGPoint(x: 20, y: 100)]
        let map = ContourMap(contours: [points])
        let first = try XCTUnwrap(map.nearest(to: CGPoint(x: 90, y: 24), radius: 6))
        XCTAssertEqual(first.point, CGPoint(x: 90, y: 20))
        XCTAssertNil(map.nearest(to: CGPoint(x: 60, y: 50), radius: 6))
        XCTAssertNotNil(map.nearest(to: CGPoint(x: 90, y: 27), radius: 6, previous: first))
        let next = try XCTUnwrap(map.nearest(to: CGPoint(x: 97, y: 30), radius: 6, previous: first))
        XCTAssertEqual(next.point, CGPoint(x: 100, y: 30))
        XCTAssertNil(map.nearest(to: .zero, radius: 0))
    }
    func testVisionDetectsTransparentSilhouettesAndFlipsCoordinates() throws {
        for white in [false, true] {
            let context = try ImageCore.context(width: 256, height: 256)
            context.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: 50, y: 120, width: 140, height: 100))
            let map = try ContourMap.detect(in: XCTUnwrap(context.makeImage()))
            XCTAssertFalse(map.isEmpty)
            let left = try XCTUnwrap(map.nearest(to: CGPoint(x: 54, y: 80), radius: 8))
            XCTAssertEqual(left.point.x, 50, accuracy: 2)
            let top = try XCTUnwrap(map.nearest(to: CGPoint(x: 100, y: 39), radius: 8))
            XCTAssertEqual(top.point.y, 36, accuracy: 2)
            XCTAssertNil(map.nearest(to: CGPoint(x: 100, y: 210), radius: 8))
        }
    }
    func testPolygonLocalContourTrackingDoesNotCrossANarrowShape() throws {
        let map = ContourMap(contours: [[CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 200), CGPoint(x: 0, y: 200)]])
        var held = try XCTUnwrap(map.nearest(to: CGPoint(x: 0, y: 90), radius: 6))
        for y: CGFloat in [100, 110, 105, 95] {
            let next = try XCTUnwrap(map.nearest(to: CGPoint(x: 7, y: y), radius: 6, previous: held))
            XCTAssertEqual(next.point, CGPoint(x: 0, y: y))
            held = next
        }
        // A deliberate pull beyond release can cross to the other side.
        XCTAssertEqual(map.nearest(to: CGPoint(x: 13, y: 95), radius: 6, previous: held)?.point.x, 8)
    }

    func testPixelFallbackTracksABorderThroughSmallPointerDrift() throws {
        let context = try ImageCore.context(width: 200, height: 200)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in [101, 105] { context.fill(CGRect(x: x, y: 0, width: 1, height: 200)) }
        let pixels = try XCTUnwrap(PixelEdges(context.makeImage()!))
        for radius: CGFloat in [10, 48] {
            var pointer = CGPoint(x: 100, y: 30)
            var held = try XCTUnwrap(pixels.candidates(to: pointer, radius: radius).first)
            let edgeX = held.point.x
            for i in 1...32 {
                let next = CGPoint(x: 100 + CGFloat(i) * 0.25, y: 30 + CGFloat(i) * 2)
                held = try XCTUnwrap(pixels.candidates(to: next, radius: radius, previous: held,
                                                    movement: CGPoint(x: next.x - pointer.x, y: next.y - pointer.y)).first)
                XCTAssertEqual(held.point.x, edgeX)
                pointer = next
            }
            XCTAssertTrue(pixels.candidates(to: CGPoint(x: 130 + radius * 2, y: pointer.y), radius: radius, previous: held).isEmpty)
        }
    }

    func testFreehandHelpIsSmallDirectionalAndYieldsToAmbiguity() {
        for scale: CGFloat in [1, 2, 3.5] {
            let border = [CGPoint(x: 20, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 200), CGPoint(x: 20, y: 200)]
            let scaled = border.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            let map = ContourMap(contours: [scaled, scaled])
            for i in 0...80 {
                let p = CGPoint(x: (18 + CGFloat(i) / 10) * scale, y: 50 * scale)
                let guided = map.nudged(p, movement: CGPoint(x: 0, y: 2 * scale), pixelsPerPoint: scale)
                XCTAssertLessThanOrEqual(hypot(guided.x - p.x, guided.y - p.y), 1.1 * scale)
                XCTAssertEqual(guided.y, p.y)
                XCTAssertEqual(map.nudged(p, movement: CGPoint(x: 2 * scale, y: 0), pixelsPerPoint: scale), p,
                               "Crossing a border must remain freehand")
            }
            let near = CGPoint(x: 21 * scale, y: 50 * scale)
            XCTAssertLessThan(map.nudged(near, movement: CGPoint(x: 0, y: 2 * scale), pixelsPerPoint: scale).x, near.x)
            XCTAssertEqual(map.nudged(near, movement: .zero, pixelsPerPoint: scale), near)
            let barelyMoving = map.nudged(near, movement: CGPoint(x: 0, y: 0.001 * scale), pixelsPerPoint: scale)
            XCTAssertLessThan(abs(barelyMoving.x - near.x), 0.003 * scale, "Slow motion must not toggle a full correction")
            let competing = ContourMap(contours: [scaled, scaled.map { CGPoint(x: $0.x + 5 * scale, y: $0.y) }])
            let between = CGPoint(x: 22.5 * scale, y: 50 * scale)
            XCTAssertEqual(competing.nudged(between, movement: CGPoint(x: 0, y: 2 * scale), pixelsPerPoint: scale), between)
        }
        let dense = ContourMap(contours: Array(repeating: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)], count: 200))
        let start = Date()
        for i in 0..<10_000 {
            let p = CGPoint(x: 1, y: CGFloat(i % 40))
            XCTAssertEqual(dense.nudged(p, movement: CGPoint(x: 0, y: 1), pixelsPerPoint: 1), p)
        }
        print("Dense freehand guidance: 10,000 updates in \(Date().timeIntervalSince(start)) seconds")
    }

    @MainActor func testFreehandCanvasFollowsPointerAcrossBordersAndCorners() async throws {
        _ = NSApplication.shared
        let context = try ImageCore.context(width: 200, height: 200)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 20, through: 180, by: 5) { context.fill(CGRect(x: x, y: 0, width: 1, height: 200)) }
        let border = [CGPoint(x: 40, y: 20), CGPoint(x: 160, y: 20), CGPoint(x: 160, y: 180), CGPoint(x: 40, y: 180)]
        let map = ContourMap(contours: [border, border.map { CGPoint(x: $0.x + 5, y: $0.y) }])
        for bypass in [false, true] {
            let model = CanvasModel(image: context.makeImage()!, isScreen: true, complete: { _ in XCTFail("Review must not save") }, cancel: {})
            model.edgeMap = map; model.smoothing = 0.55
            let view = CanvasNSView(model: model)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            defer { window.close() }
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: 200 - p.y), modifierFlags: bypass ? [.option] : [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let start = CGPoint(x: 42, y: 30)
            view.mouseDown(with: event(.leftMouseDown, start))
            let stroke = (0..<100).map { CGPoint(x: 43 + sin(CGFloat($0) / 5) * 9, y: 31 + CGFloat($0)) }
                + [CGPoint(x: 42, y: 180), CGPoint(x: 90, y: 150), CGPoint(x: 80, y: 80), CGPoint(x: 150, y: 40)]
            for point in stroke {
                let count = view.points.count
                view.mouseDragged(with: event(.leftMouseDragged, point))
                let actual = try XCTUnwrap(view.points.last)
                XCTAssertLessThanOrEqual(hypot(actual.x - point.x, actual.y - point.y), bypass ? 1 : 2.1)
                XCTAssertLessThanOrEqual(view.points.count - count, 1, "Never insert contour vertices into a freehand stroke")
            }
            let beforeTab = view.points
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "\t",
                                               charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!)
            XCTAssertEqual(view.points, beforeTab)
            view.mouseUp(with: event(.leftMouseUp, start))
            XCTAssertTrue(model.reviewing)
            XCTAssertNil(model.error)
            let expected = try ImageCore.crop(model.session.image, points: view.points)
            XCTAssertEqual(try ImageCore.png(try XCTUnwrap(model.reviewImage)), try ImageCore.png(expected))
        }
    }
    @MainActor func testCanvasSnapBypassAndLateDetection() async throws {
        _ = NSApplication.shared
        let context = try ImageCore.context(width: 40, height: 40)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let map = ContourMap(contours: [[CGPoint(x: 3, y: 3), CGPoint(x: 33, y: 3), CGPoint(x: 33, y: 33), CGPoint(x: 3, y: 33)]])
        for (bypass, late, expected) in [(false, false, 32), (true, false, 32), (false, true, 32)] {
            var output: CGImage?
            let model = CanvasModel(image: context.makeImage()!, isScreen: false, complete: { output = $0 }, cancel: {})
            model.smoothing = 0
            if !late { model.edgeMap = map }
            let view = CanvasNSView(model: model)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
            defer { window.close() }
            func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 400 - y), modifierFlags: bypass ? [.option] : [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, 23, 23))
            if late { model.edgeMap = map }
            for p in [CGPoint(x: 337, y: 23), CGPoint(x: 337, y: 337), CGPoint(x: 23, y: 337)] {
                view.mouseDragged(with: event(.leftMouseDragged, p.x, p.y))
            }
            view.mouseUp(with: event(.leftMouseUp, 23, 23))
            XCTAssertNil(output)
            XCTAssertTrue(model.reviewing)
            model.confirm()
            XCTAssertEqual(output?.width, expected)
            XCTAssertEqual(output?.height, expected)
        }
    }
}
