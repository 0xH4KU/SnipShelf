import XCTest
import AppKit
import CoreVideo
@testable import SnipShelf

final class SelectionCorrectionTests: XCTestCase {
    func testSubjectMaskPreservesSourcePixelsSoftAlphaHolesAndLassoBounds() throws {
        let helper = SnipShelfTests()
        let context = try ImageCore.context(width: 40, height: 30)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        context.clear(CGRect(x: 6, y: 22, width: 4, height: 4))
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.1, alpha: 0.5))
        context.fill(CGRect(x: 12, y: 22, width: 4, height: 4))
        let source = try XCTUnwrap(context.makeImage())
        var alpha = [UInt8](repeating: 0, count: 40 * 30)
        for y in 3..<22 { for x in 4..<28 { alpha[y * 40 + x] = 255 } }
        for y in 4..<8 { for x in 12..<16 { alpha[y * 40 + x] = 128 } }
        for y in 10..<14 { for x in 20..<24 { alpha[y * 40 + x] = 0 } }
        let mask = try XCTUnwrap(CGImage(width: 40, height: 30, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
            provider: XCTUnwrap(CGDataProvider(data: Data(alpha) as CFData)), decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let points = [CGPoint(x: 1, y: 1), CGPoint(x: 30, y: 1), CGPoint(x: 30, y: 15),
                      CGPoint(x: 18, y: 15), CGPoint(x: 18, y: 25), CGPoint(x: 1, y: 25)]
        let output = try ImageCore.crop(source, points: points, mask: mask)
        XCTAssertEqual(output.width, 29); XCTAssertEqual(output.height, 24)
        XCTAssertEqual(helper.color(output, 7, 9), helper.color(source, 8, 10), "White subject interiors must stay opaque and unchanged")
        XCTAssertEqual(helper.color(output, 6, 4).alphaComponent, 0, accuracy: 0.01, "Existing transparency must survive")
        XCTAssertEqual(helper.color(output, 12, 4).alphaComponent, 0.25, accuracy: 0.015, "Soft mask multiplies source alpha")
        XCTAssertEqual(helper.color(output, 12, 4).redComponent, 1, accuracy: 0.02)
        for point in [(1, 7), (20, 10), (24, 18)] {
            XCTAssertEqual(helper.color(output, point.0, point.1).alphaComponent, 0, accuracy: 0.01, "Background, holes, and points outside the lasso stay transparent")
        }
        XCTAssertThrowsError(try ImageCore.crop(helper.image(), points: points, mask: mask), "Misaligned masks must be rejected")
    }

    func testSubjectMaskChoosesTheOverlappingInstanceInImageCoordinates() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_OneComponent8, nil, &buffer), kCVReturnSuccess)
        let mask = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(mask, []), kCVReturnSuccess)
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(mask)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        for y in 0..<6 { for x in 0..<8 { bytes[y * stride + x] = 0 } }
        for y in 1..<3 { for x in 1..<3 { bytes[y * stride + x] = 1 } }
        for y in 3..<6 { for x in 4..<8 { bytes[y * stride + x] = 2 } }
        CVPixelBufferUnlockBaseAddress(mask, [])
        let size = CGSize(width: 80, height: 60)
        let helper = SnipShelfTests()
        XCTAssertEqual(try SubjectMask.selectedInstances(in: mask, points: helper.rect(0, 0, 35, 35), imageSize: size), IndexSet(integer: 1))
        XCTAssertEqual(try SubjectMask.selectedInstances(in: mask, points: helper.rect(0, 0, 80, 60), imageSize: size), IndexSet(integer: 2))
        XCTAssertTrue(try SubjectMask.selectedInstances(in: mask, points: helper.rect(50, 0, 20, 20), imageSize: size).isEmpty)
        XCTAssertTrue(try SubjectMask.selectedInstances(in: mask, points: [.zero], imageSize: size).isEmpty)
    }

    @MainActor func testSubjectMaskFallbackAndExistingPreferencePreserveTheSelection() async throws {
        let suite = "org.snipshelf.tests.mask." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "visionCorrection")
        let context = try ImageCore.context(width: 100, height: 100)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let source = try XCTUnwrap(context.makeImage())
        let model = CanvasModel(image: source, isScreen: false, preferences: preferences, complete: { _ in }, cancel: {})
        XCTAssertFalse(model.subjectMaskEnabled, "An existing opt-out must survive the algorithm change")
        let outline = SnipShelfTests().rect(10, 10, 70, 80)
        try model.prepareReview(points: outline)
        let original = try ImageCore.png(XCTUnwrap(model.reviewImage))
        XCTAssertNil(model.correctionTask)
        model.subjectMaskEnabled = true
        await model.correctionTask?.value
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), original, "An image without a subject must preserve the original selection")
        XCTAssertEqual(model.reviewPoints, outline)
    }

    @MainActor func testCorrectionToggleUndoAndLateCompletionPreserveTheChosenPixels() async throws {
        _ = NSApplication.shared
        let context = try ImageCore.context(width: 400, height: 300)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 100, y: 80, width: 200, height: 150))
        let image = try XCTUnwrap(context.makeImage())
        let outline = SnipShelfTests().rect(80, 50, 240, 200)
        let originalBytes = try ImageCore.png(ImageCore.crop(image, points: outline))
        // Keep lifecycle checks independent of changes to Vision's subject recognition.
        let maskContext = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        maskContext.setFillColor(CGColor(gray: 1, alpha: 1))
        maskContext.fill(CGRect(x: 100, y: 80, width: 200, height: 150))
        let mask = try XCTUnwrap(maskContext.makeImage())
        var outputs: [CGImage] = []
        let model = CanvasModel(image: image, isScreen: false,
            subjectCutout: { try ImageCore.crop($0, points: $1, mask: mask) },
            complete: { outputs.append($0) }, cancel: {})
        XCTAssertTrue(model.subjectMaskEnabled)
        var reviews = 0
        model.reviewReady = { reviews += 1 }
        try model.prepareReview(points: outline)
        XCTAssertTrue(model.correcting)
        model.confirm()
        XCTAssertTrue(outputs.isEmpty, "Return must not save a different result while the enabled correction is pending")
        await model.correctionTask?.value
        XCTAssertFalse(model.correcting)
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(reviews, 1, "Updating a correction must not recreate or move the review panel")
        let correctedPoints = model.reviewPoints
        let correctedBytes = try ImageCore.png(XCTUnwrap(model.reviewImage))
        XCTAssertNotEqual(correctedBytes, originalBytes)
        XCTAssertEqual(model.reviewImage!.width, 240)
        XCTAssertEqual(model.reviewImage!.height, 200)
        XCTAssertEqual(model.reviewOrigin, CGPoint(x: 80, y: 50))
        XCTAssertEqual(correctedPoints, outline, "Refinement must retain the user's editable lasso")
        let result = try XCTUnwrap(model.reviewImage)
        XCTAssertLessThan(SnipShelfTests().color(result, 5, 5).alphaComponent, 0.1)
        XCTAssertEqual(SnipShelfTests().color(result, 100, 100), SnipShelfTests().color(image, 180, 150))

        let view = CanvasNSView(model: model)
        for _ in 0..<3 {
            model.subjectMaskEnabled = false; view.refresh()
            XCTAssertFalse(model.subjectMaskEnabled)
            XCTAssertEqual(view.points, outline)
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), originalBytes)
            model.subjectMaskEnabled = true; view.refresh()
            XCTAssertTrue(model.subjectMaskEnabled)
            XCTAssertEqual(view.points, correctedPoints)
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), correctedBytes)
        }
        model.continueSelection(); view.refresh()
        XCTAssertEqual(view.points, correctedPoints)
        try model.prepareReview(points: SnipShelfTests().rect(82, 52, 236, 196))
        await model.correctionTask?.value
        model.undoSelection(); view.refresh()
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), correctedBytes)
        model.subjectMaskEnabled = false
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), originalBytes, "Undo must retain the original uncorrected stroke too")
        model.subjectMaskEnabled = true
        model.confirm(); model.confirm()
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(outputs.first)), correctedBytes)

        try model.prepareReview(points: outline)
        let pendingReset = model.correctionTask
        model.reset()
        await pendingReset?.value
        XCTAssertFalse(model.hasOutline, "A late result must not resurrect a cleared selection")
        try model.prepareReview(points: outline)
        let pendingSave = model.correctionTask
        model.subjectMaskEnabled = false
        model.confirm()
        await pendingSave?.value
        XCTAssertFalse(model.hasOutline)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(outputs.last)), originalBytes)
    }
}
