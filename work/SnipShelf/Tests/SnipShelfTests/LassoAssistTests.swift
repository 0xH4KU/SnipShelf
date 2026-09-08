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
    func testSnapRadiusHysteresisAndCornerBridge() throws {
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 100), CGPoint(x: 20, y: 100)]
        let map = ContourMap(contours: [points])
        let first = try XCTUnwrap(map.nearest(to: CGPoint(x: 90, y: 24), radius: 6))
        XCTAssertEqual(first.point, CGPoint(x: 90, y: 20))
        XCTAssertNil(map.nearest(to: CGPoint(x: 60, y: 50), radius: 6))
        XCTAssertNotNil(map.nearest(to: CGPoint(x: 90, y: 27), radius: 6, previous: first))
        let next = try XCTUnwrap(map.nearest(to: CGPoint(x: 97, y: 30), radius: 6, previous: first))
        XCTAssertEqual(map.bridge(from: first, to: next, radius: 6), [CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 30)])
        let opposite = try XCTUnwrap(map.nearest(to: CGPoint(x: 60, y: 100), radius: 6))
        let across = try XCTUnwrap(map.nearest(to: CGPoint(x: 60, y: 20), radius: 6))
        XCTAssertEqual(map.bridge(from: across, to: opposite, radius: 6), [opposite.point])
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
    @MainActor func testCanvasSnapBypassAndLateDetection() async throws {
        _ = NSApplication.shared
        let context = try ImageCore.context(width: 40, height: 40)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let map = ContourMap(contours: [[CGPoint(x: 3, y: 3), CGPoint(x: 33, y: 3), CGPoint(x: 33, y: 33), CGPoint(x: 3, y: 33)]])
        for (bypass, late, expected) in [(false, false, 30), (true, false, 32), (false, true, 32)] {
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
