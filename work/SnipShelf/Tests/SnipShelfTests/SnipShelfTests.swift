import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
@testable import SnipShelf

final class SnipShelfTests: XCTestCase {
    func image(width: Int = 40, height: Int = 40) throws -> CGImage {
        let c = try ImageCore.context(width: width, height: height)
        c.setFillColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        c.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return c.makeImage()!
    }
    func color(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
    }
    func testPixelMappingAndCropOrientation() throws {
        let source = try image()
        let session = CaptureSession(image: source)
        XCTAssertEqual(session.pixelPoint(CGPoint(x: 20, y: 25), in: CGRect(x: 10, y: 15, width: 20, height: 20)), CGPoint(x: 20, y: 20))
        XCTAssertEqual(session.pixelPoint(CGPoint(x: 30, y: 35), in: CGRect(x: 10, y: 15, width: 40, height: 40)), CGPoint(x: 20, y: 20))
        let top = try ImageCore.crop(source, points: rect(5, 3, 10, 10))
        XCTAssertEqual(top.width, 10); XCTAssertEqual(top.height, 10)
        XCTAssertGreaterThan(color(top, 5, 5).blueComponent, 0.9)
        let bottom = try ImageCore.crop(source, points: rect(5, 25, 10, 10))
        XCTAssertGreaterThan(color(bottom, 5, 5).redComponent, 0.9)
        let decoded = try ImageCore.load(ImageCore.png(top))
        XCTAssertGreaterThan(color(decoded, 5, 5).blueComponent, 0.9)
        XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
    }
    func testConcaveAndSelfIntersectingSelections() throws {
        let source = try image()
        let concave = try ImageCore.crop(source, points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 30), CGPoint(x: 0, y: 30)])
        XCTAssertGreaterThan(color(concave, 5, 20).alphaComponent, 0.99)
        XCTAssertLessThan(color(concave, 20, 20).alphaComponent, 0.01)
        let bowtie = try ImageCore.crop(source, points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30), CGPoint(x: 0, y: 30), CGPoint(x: 30, y: 0)])
        XCTAssertGreaterThan(color(bowtie, 15, 4).alphaComponent, 0.99)
        XCTAssertLessThan(color(bowtie, 2, 15).alphaComponent, 0.01)
        let twice = rect(0, 0, 30, 30) + rect(0, 0, 30, 30)
        XCTAssertThrowsError(try ImageCore.crop(source, points: twice))
    }
    func testInvalidSelectionsAndAntialiasing() throws {
        let source = try image()
        for points in [[], [CGPoint.zero], rect(1, 1, 1, 1), rect(100, 100, 20, 20), [CGPoint(x: CGFloat.infinity, y: 0), .zero, CGPoint(x: 3, y: 3)]] {
            XCTAssertThrowsError(try ImageCore.crop(source, points: points))
        }
        let triangle = try ImageCore.crop(source, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 30.7, y: 2.3), CGPoint(x: 3.1, y: 30.4)])
        var partial = false
        for y in 0..<triangle.height {
            for x in 0..<triangle.width {
                let a = color(triangle, x, y).alphaComponent
                if a > 0.01 && a < 0.99 { partial = true }
            }
        }
        XCTAssertTrue(partial)
        let again = try ImageCore.crop(triangle, points: rect(0, 0, CGFloat(triangle.width), CGFloat(triangle.height)))
        XCTAssertLessThan(color(again, 29, 29).alphaComponent, 0.01)
    }
    func testOrientationAndUnsupportedData() throws {
        let source = try image(width: 60, height: 30)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let rotated = try ImageCore.load(data as Data)
        XCTAssertEqual(rotated.width, 30); XCTAssertEqual(rotated.height, 60)
        XCTAssertThrowsError(try ImageCore.load(Data("not an image".utf8)))
    }
    @MainActor func testPersistenceUndoAndMissingAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let a = try store.add(image(), name: "A")
        let b = try store.add(image(), name: "B")
        store.delete([a.id])
        let c = try store.add(image(), name: "C")
        store.undo()
        XCTAssertEqual(Set(store.clips.map(\.id)), [a.id, b.id, c.id])
        let restored = ShelfStore(root: root)
        XCTAssertEqual(restored.clips, store.clips)
        try FileManager.default.removeItem(at: restored.url(for: a))
        let withMissing = ShelfStore(root: root)
        XCTAssertEqual(withMissing.clips.count, 3)
        XCTAssertThrowsError(try ImageCore.load(withMissing.url(for: a)))
        XCTAssertNoThrow(try ImageCore.load(withMissing.url(for: b)))
        withMissing.delete(Set(withMissing.clips.map(\.id)))
        XCTAssertTrue(withMissing.clips.isEmpty)
        withMissing.undo()
        XCTAssertEqual(withMissing.clips.count, 3)
    }
    @MainActor func testFailedWriteAndCorruptIndexPreserveData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let a = try store.add(image(), name: "Keep")
        let index = root.appendingPathComponent("index.json")
        let savedIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        store.receive(try image(), name: "Retry")
        XCTAssertNotNil(store.pendingImage)
        XCTAssertEqual(store.clips, [a])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: a).path))
        try FileManager.default.removeItem(at: index)
        try savedIndex.write(to: index)
        store.retryPending()
        XCTAssertNil(store.pendingImage); XCTAssertEqual(store.clips.count, 2)
        try Data("broken".utf8).write(to: index)
        let broken = ShelfStore(root: root)
        XCTAssertTrue(broken.isReadOnly)
        XCTAssertThrowsError(try broken.add(image(), name: "No overwrite"))
        XCTAssertEqual(try Data(contentsOf: index), Data("broken".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: a).path))
    }
    @MainActor func testOneHundredMixedSizeClips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        for i in 0..<100 {
            _ = try store.add(image(width: 100 + i * 7, height: 80 + i * 3), name: "Sample \(i)")
        }
        let reload = ShelfStore(root: root)
        XCTAssertEqual(reload.clips.count, 100)
        for clip in reload.clips {
            let thumbnail = try ImageCore.load(reload.thumbnailURL(for: clip))
            XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 320)
        }
    }
    @MainActor func testLassoCanvasEventFlow() async throws {
        _ = NSApplication.shared
        var completed: CGImage?
        let model = CanvasModel(image: try image(), isScreen: false, complete: { completed = $0 }, cancel: {})
        let view = CanvasNSView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        defer { window.close() }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 400 - y), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 20, 20))
        XCTAssertTrue(model.selecting)
        for point in [CGPoint(x: 300, y: 20), CGPoint(x: 300, y: 300), CGPoint(x: 20, y: 300)] {
            view.mouseDragged(with: event(.leftMouseDragged, point.x, point.y))
        }
        view.mouseUp(with: event(.leftMouseUp, 20, 20))
        XCTAssertNil(completed)
        XCTAssertTrue(model.reviewing)
        model.confirm()
        XCTAssertEqual(completed?.width, 28)
        XCTAssertEqual(completed?.height, 28)
        model.actualSize = true
        XCTAssertEqual(view.imageRect.width * window.backingScaleFactor, 40, accuracy: 0.01)
    }

    @MainActor func testShelfMoveAndDockState() async throws {
        _ = NSApplication.shared
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shelf = ShelfWindow(defaults: defaults)
        shelf.install(content: EmptyView(), key: { _ in false })
        shelf.panel.orderOut(nil)
        defer { shelf.panel.close() }
        let initial = shelf.panel.frame
        let start = CGPoint(x: initial.midX, y: initial.midY)
        shelf.beginMove(at: start)
        shelf.move(to: CGPoint(x: start.x - 100, y: start.y))
        shelf.endMove(wasClick: false)
        XCTAssertFalse(shelf.collapsed)
        XCTAssertEqual(shelf.panel.frame.minX, initial.minX - 100, accuracy: 1)
        let secondStart = CGPoint(x: shelf.panel.frame.midX, y: shelf.panel.frame.midY)
        shelf.beginMove(at: secondStart)
        shelf.move(to: CGPoint(x: secondStart.x + 130, y: secondStart.y))
        XCTAssertEqual(shelf.snapEdge, "right")
        shelf.endMove(wasClick: false)
        XCTAssertTrue(shelf.collapsed)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(shelf.panel.frame.width, 24, accuracy: 1)
        shelf.expand()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(shelf.collapsed)
        XCTAssertEqual(shelf.panel.frame.width, initial.width, accuracy: 1)
    }

}
