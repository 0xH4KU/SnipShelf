import XCTest
import AppKit
@testable import SnipShelf

final class SnipLabTests: XCTestCase {
    @MainActor func testLabRepeatsRealCanvasStrokesAndPreservesSettingsAcrossImages() async throws {
        _ = NSApplication.shared
        let suite = "org.snipshelf.tests.lab." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let lab = SnipLabController(preferences: preferences)
        lab.show()
        let window = try XCTUnwrap(lab.window)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        let model = try XCTUnwrap(lab.model)
        XCTAssertFalse(model.isScreen)
        XCTAssertNil(model.reviewReady, "The lab must not hide the canvas in a capture-review window")
        XCTAssertEqual(model.smoothing, 0.55)
        XCTAssertTrue(model.subjectMaskEnabled)
        model.subjectMaskEnabled = false
        model.smoothing = 0; model.snapEnabled = false; model.snapRadius = 18

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let canvas = try XCTUnwrap(descendants(XCTUnwrap(window.contentView)).compactMap { $0 as? CanvasNSView }.first)
        let stroke = [CGPoint(x: 150, y: 150), CGPoint(x: 550, y: 150), CGPoint(x: 550, y: 440), CGPoint(x: 150, y: 440)]
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let rect = canvas.imageRect
            let location = canvas.convert(CGPoint(x: rect.minX + point.x * rect.width / 1200,
                                                 y: rect.minY + point.y * rect.height / 900), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for trial in 0..<3 {
            canvas.mouseDown(with: event(.leftMouseDown, stroke[0]))
            for point in stroke.dropFirst() { canvas.mouseDragged(with: event(.leftMouseDragged, point)) }
            canvas.mouseUp(with: event(.leftMouseUp, stroke[0]))
            XCTAssertTrue(model.reviewing)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)),
                           try ImageCore.png(ImageCore.crop(model.session.image, points: canvas.points)))
            if trial == 1 {
                model.continueSelection(); canvas.refresh()
                XCTAssertTrue(model.selecting)
                model.undoSelection(); canvas.refresh()
                XCTAssertTrue(model.reviewing)
            }
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: trial == 2 ? 53 : 36)!)
            canvas.refresh()
            XCTAssertFalse(model.hasOutline)
            XCTAssertTrue(canvas.points.isEmpty)
            XCTAssertTrue(lab.model === model, "Repeat trials reuse the frozen source and analysis")
        }
        model.mode = .polygon
        lab.showImage(try SnipShelfTests().image(), name: "Another image")
        let replacement = try XCTUnwrap(lab.model)
        XCTAssertFalse(replacement === model)
        XCTAssertEqual(replacement.mode, .polygon)
        XCTAssertEqual(replacement.smoothing, 0)
        XCTAssertFalse(replacement.snapEnabled)
        XCTAssertEqual(replacement.snapRadius, 18)
        XCTAssertFalse(replacement.subjectMaskEnabled)
        lab.openImage(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png"))
        XCTAssertTrue(lab.model === replacement, "An unreadable file must preserve the current trial")
        XCTAssertNotNil(replacement.error)
    }
}
