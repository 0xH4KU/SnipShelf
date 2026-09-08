import XCTest
import AppKit
@testable import SnipShelf

final class RevisionTests: XCTestCase {
    func testCloserBorderCanReplaceHeldContour() throws {
        let a = [CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 90), CGPoint(x: 0, y: 90), CGPoint(x: 0, y: 10)]
        let b = a.map { CGPoint(x: $0.x + 5, y: $0.y) }
        let map = ContourMap(contours: [a, b])
        let old = try XCTUnwrap(map.nearest(to: CGPoint(x: 20, y: 50), radius: 10))
        let next = try XCTUnwrap(map.nearest(to: CGPoint(x: 25, y: 50), radius: 10, previous: old))
        XCTAssertNotEqual(old.contour, next.contour)
        XCTAssertEqual(next.point.x, 25)
        XCTAssertGreaterThanOrEqual(map.candidates(to: CGPoint(x: 22, y: 50), radius: 10).count, 2)
    }
    func testPixelEdgesFindThinBrowserLikeLinesWithoutVision() throws {
        let context = try ImageCore.context(width: 400, height: 220)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 220))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 100, y: 20, width: 1, height: 180))
        let pixels = try XCTUnwrap(PixelEdges(context.makeImage()!))
        let hit = try XCTUnwrap(pixels.candidates(to: CGPoint(x: 104, y: 110), radius: 10).first)
        XCTAssertEqual(hit.point.x, 100, accuracy: 2)
        XCTAssertTrue(pixels.candidates(to: CGPoint(x: 300, y: 100), radius: 10).isEmpty)
    }
    func testContinueCanRetraceFromMiddleOfSegment() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        XCTAssertEqual(LassoPath.continuing(points, near: CGPoint(x: 50, y: 2), radius: 5), [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)])
        XCTAssertEqual(LassoPath.continuing(points, near: CGPoint(x: 200, y: 200), radius: 5), points + [CGPoint(x: 200, y: 200)])
    }
    @MainActor func testReviewDeleteContinueAndExactlyOnceConfirmation() async throws {
        let context = try ImageCore.context(width: 100, height: 100)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        var confirmations = 0
        let model = CanvasModel(image: context.makeImage()!, isScreen: true, complete: { _ in confirmations += 1 }, cancel: {})
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 10), CGPoint(x: 70, y: 70), CGPoint(x: 10, y: 70)]
        try model.prepareReview(points: points)
        XCTAssertEqual(confirmations, 0)
        XCTAssertTrue(model.reviewing)
        model.continueSelection()
        XCTAssertTrue(model.selecting); XCTAssertFalse(model.reviewing)
        model.confirm()
        XCTAssertEqual(confirmations, 0)
        try model.prepareReview(points: points)
        model.reset()
        model.confirm()
        XCTAssertEqual(confirmations, 0)
        try model.prepareReview(points: points)
        model.confirm(); model.confirm()
        XCTAssertEqual(confirmations, 1)
    }
    @MainActor func testBatchDeletionAndUndoPreserveNewClips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let context = try ImageCore.context(width: 20, height: 20)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = context.makeImage()!
        let clips = try (0..<4).map { try store.add(image, name: "Clip \($0)") }
        store.selectedIDs = [clips[0].id, clips[2].id]
        store.delete(store.selectedIDs)
        XCTAssertEqual(store.clips.count, 2)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.undoHistory.count, 1)
        let new = try store.add(image, name: "New")
        store.undo()
        XCTAssertEqual(store.clips.count, 5)
        XCTAssertTrue(store.clips.contains(new))
        XCTAssertEqual(store.selectedIDs, [clips[0].id, clips[2].id])
        store.delete([])
        XCTAssertTrue(store.undoHistory.isEmpty)
    }
    @MainActor func testScreenLassoGetsPixelAssistanceBeforeVisionFinishes() async throws {
        _ = NSApplication.shared
        let context = try ImageCore.context(width: 100, height: 100)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        var sizes: [Int] = []
        for bypass in [false, true] {
            let model = CanvasModel(image: context.makeImage()!, isScreen: true, complete: { _ in XCTFail("Must not save on mouse-up") }, cancel: {})
            model.smoothing = 0
            XCTAssertNil(model.edgeMap)
            XCTAssertNotNil(model.pixelEdges)
            let view = CanvasNSView(model: model)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
            defer { window.close() }
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: 400 - p.y), modifierFlags: bypass ? [.option] : [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let start = CGPoint(x: 74, y: 74)
            view.mouseDown(with: event(.leftMouseDown, start))
            for p in [CGPoint(x: 326, y: 74), CGPoint(x: 326, y: 326), CGPoint(x: 74, y: 326)] { view.mouseDragged(with: event(.leftMouseDragged, p)) }
            view.mouseUp(with: event(.leftMouseUp, start))
            sizes.append(try XCTUnwrap(model.reviewImage).width)
        }
        XCTAssertLessThan(sizes[0], sizes[1])
    }
}
