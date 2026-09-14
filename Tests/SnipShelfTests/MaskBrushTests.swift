import XCTest
import AppKit
@testable import SnipShelf

final class MaskBrushTests: XCTestCase {
    func testRemovedPixelsMeasureAlphaLossWithoutMarkingExistingTransparency() throws {
        let helper = SnipShelfTests()
        let before = try ImageCore.context(width: 40, height: 30)
        before.setFillColor(CGColor(gray: 1, alpha: 1)); before.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        before.clear(CGRect(x: 4, y: 4, width: 6, height: 6))
        before.setBlendMode(.copy)
        before.setFillColor(CGColor(gray: 1, alpha: 0.5)); before.fill(CGRect(x: 15, y: 15, width: 10, height: 10))
        let original = try XCTUnwrap(before.makeImage())
        let after = try ImageCore.context(width: 40, height: 30)
        after.draw(original, in: CGRect(x: 0, y: 0, width: 40, height: 30))
        let unchanged = try XCTUnwrap(ImageCore.removedPixels(original: original, current: XCTUnwrap(after.makeImage())))
        for p in [(3, 3), (22, 10), (6, 23)] { XCTAssertEqual(helper.color(unchanged, p.0, p.1).alphaComponent, 0) }
        after.clear(CGRect(x: 28, y: 18, width: 8, height: 8))
        after.setBlendMode(.copy)
        after.setFillColor(CGColor(gray: 1, alpha: 0.25)); after.fill(CGRect(x: 15, y: 15, width: 5, height: 10))
        let removed = try XCTUnwrap(ImageCore.removedPixels(original: original, current: XCTUnwrap(after.makeImage())))
        XCTAssertEqual(helper.color(removed, 31, 7).alphaComponent, 1)
        XCTAssertEqual(helper.color(removed, 17, 10).alphaComponent, 0.25, accuracy: 0.01)
        XCTAssertEqual(helper.color(removed, 22, 10).alphaComponent, 0, "Unchanged semi-transparent pixels are not mask mistakes")
        XCTAssertEqual(helper.color(removed, 6, 23).alphaComponent, 0, "Existing holes must not be highlighted")
        XCTAssertEqual(helper.color(removed, 12, 20).alphaComponent, 0)
        XCTAssertThrowsError(try ImageCore.removedPixels(original: original, current: helper.image()))
    }

    @MainActor func testRemovedOverlayAlignsWithBrushChangesAndNeverChangesTheSavedImage() async throws {
        _ = NSApplication.shared
        let context = try ImageCore.context(width: 100, height: 100)
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.1, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        var saved: CGImage?
        let model = CanvasModel(image: try XCTUnwrap(context.makeImage()), isScreen: false,
            subjectCutout: { try ImageCore.crop($0, points: $1) }, complete: { saved = $0 }, cancel: {})
        try model.prepareReview(points: SnipShelfTests().rect(20, 20, 60, 60))
        await model.correctionTask?.value
        model.showCutout = false; model.maskTool = .erase; model.brushSize = 14
        let point = CGPoint(x: 35, y: 28)
        model.beginMaskStroke(at: point); model.endMaskStroke()
        let output = try ImageCore.png(XCTUnwrap(model.reviewImage))
        let view = CanvasNSView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        func render() throws -> NSBitmapImageRep {
            view.refresh()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        func color(_ bitmap: NSBitmapImageRep, _ p: CGPoint) -> NSColor {
            let rect = view.imageRect
            let x = (rect.minX + p.x * rect.width / 100) * CGFloat(bitmap.pixelsWide) / view.bounds.width
            let y = (rect.minY + p.y * rect.height / 100) * CGFloat(bitmap.pixelsHigh) / view.bounds.height
            return bitmap.colorAt(x: Int(x), y: Int(y))!.usingColorSpace(.sRGB)!
        }
        for zoom: CGFloat in [1, 1.2] {
            model.scale = zoom; model.offset = CGPoint(x: 6, y: -12)
            model.showRemovedAreas = false
            let plain = try render()
            model.showRemovedAreas = true
            let marked = try render()
            XCTAssertGreaterThan(color(marked, point).blueComponent, color(plain, point).blueComponent + 0.2,
                "Removed areas must be visibly distinct on a red background")
            for kept in [CGPoint(x: 60, y: 30), CGPoint(x: 35, y: 72), CGPoint(x: 15, y: 50)] {
                XCTAssertEqual(color(marked, kept), color(plain, kept), "Kept pixels, mirrored coordinates and points outside the lasso must stay unchanged")
            }
            model.maskTool = .restore; model.beginMaskStroke(at: point)
            XCTAssertLessThan(color(try render(), point).blueComponent, 0.15, "Overlay must update during the stroke")
            model.cancelMaskStroke()
        }
        model.showCutout = true
        let cutout = try ImageCore.png(XCTUnwrap(render().cgImage))
        model.showRemovedAreas = false
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(render().cgImage)), cutout, "The Cutout view must stay free of overlay marks")
        model.subjectMaskEnabled = false; model.showCutout = false; model.showRemovedAreas = true
        let raw = try render()
        model.showRemovedAreas = false
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(render().cgImage)), try ImageCore.png(XCTUnwrap(raw.cgImage)))
        model.subjectMaskEnabled = true; model.showRemovedAreas = true
        model.confirm()
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(saved)), output)
    }

    func testBrushRestoresOriginalAlphaAndConnectsSparseEventsInsideTheLasso() throws {
        let helper = SnipShelfTests()
        let context = try ImageCore.context(width: 100, height: 80)
        context.draw(try helper.image(width: 100, height: 80), in: CGRect(x: 0, y: 0, width: 100, height: 80))
        context.clear(CGRect(x: 25, y: 50, width: 10, height: 10))
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.8, alpha: 0.4))
        context.fill(CGRect(x: 40, y: 50, width: 10, height: 10))
        let source = try XCTUnwrap(context.makeImage())
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10), CGPoint(x: 90, y: 35),
                      CGPoint(x: 60, y: 35), CGPoint(x: 60, y: 70), CGPoint(x: 10, y: 70)]
        let raw = try ImageCore.crop(source, points: points)
        let start = CGPoint(x: 5, y: 25), end = CGPoint(x: 95, y: 25)
        let erase = try MaskBrush(image: raw, original: raw, origin: CGPoint(x: 10, y: 10),
            start: start, diameter: 12, restoring: false)
        let erased = try erase.paint(to: end)
        for x in [10, 30, 50, 70] { XCTAssertEqual(helper.color(erased, x, 15).alphaComponent, 0) }
        XCTAssertEqual(helper.color(erased, 10, 3), helper.color(raw, 10, 3), "Pixels away from the brush must stay unchanged")
        let restore = try MaskBrush(image: erased, original: raw, origin: CGPoint(x: 10, y: 10),
            start: start, diameter: 12, restoring: true)
        _ = try restore.paint(to: end)
        _ = try restore.paint(to: start)
        let restored = try restore.paint(to: end)
        for x in [10, 20, 35, 60] {
            XCTAssertEqual(helper.color(restored, x, 15), helper.color(raw, x, 15), "Repeated restoration must preserve source color, transparency and partial alpha")
        }
        let outside = try MaskBrush(image: restored, original: raw, origin: CGPoint(x: 10, y: 10),
            start: CGPoint(x: 75, y: 55), diameter: 24, restoring: true)
        XCTAssertEqual(helper.color(try outside.paint(to: CGPoint(x: 75, y: 55)), 65, 45).alphaComponent, 0,
            "Restore must not add pixels outside a concave lasso")
        XCTAssertThrowsError(try restore.paint(to: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertThrowsError(try MaskBrush(image: raw, original: source, origin: .zero, start: .zero, diameter: 12, restoring: true))
    }

    @MainActor func testTouchUpsSurviveToggleUndoRefinementAndSave() async throws {
        let helper = SnipShelfTests(), source = try helper.image(width: 100, height: 100)
        let maskContext = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        maskContext.setFillColor(CGColor(gray: 1, alpha: 1)); maskContext.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        let mask = try XCTUnwrap(maskContext.makeImage())
        var outputs: [CGImage] = []
        let model = CanvasModel(image: source, isScreen: false,
            subjectCutout: { try ImageCore.crop($0, points: $1, mask: mask) }, complete: { outputs.append($0) }, cancel: {})
        let points = helper.rect(10, 10, 80, 80)
        try model.prepareReview(points: points)
        model.maskTool = .restore
        model.beginMaskStroke(at: CGPoint(x: 70, y: 30))
        XCTAssertFalse(model.paintingMask, "Pending subject recognition must not overwrite a brush stroke")
        await model.correctionTask?.value
        let baseline = try ImageCore.png(XCTUnwrap(model.reviewImage))
        model.brushSize = 14
        model.beginMaskStroke(at: CGPoint(x: 70, y: 30))
        XCTAssertTrue(model.paintingMask)
        model.confirm(); XCTAssertTrue(outputs.isEmpty)
        model.endMaskStroke()
        let restored = try ImageCore.png(XCTUnwrap(model.reviewImage))
        XCTAssertEqual(helper.color(model.reviewImage!, 60, 20), helper.color(source, 70, 30))
        model.maskTool = .erase
        model.beginMaskStroke(at: CGPoint(x: 25, y: 30)); model.endMaskStroke()
        let edited = try ImageCore.png(XCTUnwrap(model.reviewImage))
        XCTAssertEqual(helper.color(model.reviewImage!, 15, 20).alphaComponent, 0)
        model.undoSelection(); XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), restored)
        model.undoSelection(); XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), baseline)
        XCTAssertFalse(model.canUndoMask); XCTAssertTrue(model.canRedoMask)
        model.redoMaskStroke(); model.redoMaskStroke()
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited)

        model.beginMaskStroke(at: CGPoint(x: 35, y: 50))
        model.subjectMaskEnabled = false
        XCTAssertFalse(model.paintingMask)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), try ImageCore.png(ImageCore.crop(source, points: points)))
        model.subjectMaskEnabled = true
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited, "Toggling must preserve completed touch-ups and cancel an unfinished stroke")
        model.continueSelection()
        try model.prepareReview(points: helper.rect(12, 12, 76, 76))
        await model.correctionTask?.value
        model.undoSelection()
        XCTAssertEqual(model.reviewPoints, points)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited, "Outline undo must also restore the manually edited mask")
        model.reset(); model.undoSelection()
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited)
        model.maskTool = .erase; model.brushSize = 128
        model.beginMaskStroke(at: CGPoint(x: 10, y: 50))
        model.paintMaskStroke(to: CGPoint(x: 90, y: 50)); model.endMaskStroke()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited, "A fully empty brush result must be reverted")
        model.confirm(); model.confirm()
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(outputs.first)), edited)
        XCTAssertFalse(model.canUndoMask); XCTAssertFalse(model.canRedoMask)
    }

    @MainActor func testReviewCanvasBrushMappingPanAndKeyboardUndoAtDifferentZooms() async throws {
        _ = NSApplication.shared
        let helper = SnipShelfTests()
        for zoom: CGFloat in [1, 2] { for cutout in [false, true] {
            var saved: CGImage?
            let source = try helper.image(width: 100, height: 100)
            let model = CanvasModel(image: source, isScreen: false,
                subjectCutout: { try ImageCore.crop($0, points: $1) }, complete: { saved = $0 }, cancel: { XCTFail("Escape should leave touch-up first") })
            try model.prepareReview(points: helper.rect(10, 10, 80, 80))
            await model.correctionTask?.value
            model.scale = zoom; model.offset = CGPoint(x: 17, y: -11); model.showCutout = cutout
            model.maskTool = .erase; model.brushSize = 10
            let view = CanvasNSView(model: model)
            let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; view.frame = frame
            defer { window.close() }
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                let rect = view.imageRect
                let location = view.convert(CGPoint(x: rect.minX + point.x * rect.width / 100,
                                                    y: rect.minY + point.y * rect.height / 100), to: nil)
                return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, characters: code == 6 ? "z" : "",
                    charactersIgnoringModifiers: code == 6 ? "z" : "", isARepeat: false, keyCode: code)!
            }
            let original = try ImageCore.png(XCTUnwrap(model.reviewImage))
            view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 30)))
            view.keyDown(with: key(36)); XCTAssertNil(saved)
            view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 50, y: 30)))
            view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 50, y: 30)))
            XCTAssertEqual(helper.color(model.reviewImage!, 30, 20).alphaComponent, 0)
            XCTAssertEqual(helper.color(model.reviewImage!, 30, 30), helper.color(source, 40, 40))
            let edited = try ImageCore.png(XCTUnwrap(model.reviewImage))
            view.keyDown(with: key(6, .command))
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), original)
            XCTAssertTrue(view.performKeyEquivalent(with: key(6, [.command, .shift])))
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited)
            let startOffset = model.offset
            view.keyDown(with: key(49))
            view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 40, y: 40)))
            view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 45, y: 45)))
            view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 45, y: 45)))
            view.keyUp(with: key(49, type: .keyUp))
            XCTAssertEqual(model.offset.x - startOffset.x, 15 * zoom, accuracy: 0.001)
            XCTAssertEqual(model.offset.y - startOffset.y, 15 * zoom, accuracy: 0.001)
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited, "Panning must not paint")
            view.keyDown(with: key(53))
            XCTAssertEqual(model.maskTool, .view); XCTAssertTrue(model.reviewing)
            view.keyDown(with: key(36))
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(saved)), edited)
        } }
    }
}
