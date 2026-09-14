import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import SnipShelf

final class InteractionTests: XCTestCase {
    @MainActor func testCaptureReviewRestoresDesktopAndKeepsSelectionUntilConfirmed() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let app = AppController(store: ShelfStore(root: root), preferences: preferences)
        let screen = try XCTUnwrap(NSScreen.main)
        let image = try SnipShelfTests().image(width: 900, height: 600)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func key(_ code: UInt16, in panel: NSWindow) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: panel.windowNumber, context: nil, characters: "",
                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        for screenCapture in [true, false] {
            app.presentCanvas(image: image, frame: screen.visibleFrame, screenCapture: screenCapture, name: "Review test")
            let model = try XCTUnwrap(app.captureModel)
            defer { model.cancel() }
            let editor = try XCTUnwrap(NSApp.windows.first { $0.title == "Crop a Copy" && $0.isVisible })
            try await Task.sleep(for: .milliseconds(80))
            let canvas = try XCTUnwrap(descendants(XCTUnwrap(editor.contentView)).compactMap { $0 as? CanvasNSView }.first)
            model.scale = 1.2; model.offset = CGPoint(x: 12, y: -18)
            model.smoothing = 0; model.snapEnabled = false
            let stroke = [CGPoint(x: 250, y: 200), CGPoint(x: 650, y: 200), CGPoint(x: 600, y: 320), CGPoint(x: 260, y: 300)]
            func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint) -> NSEvent {
                let rect = canvas.imageRect
                let location = canvas.convert(CGPoint(x: rect.minX + pixel.x * rect.width / 900,
                                                     y: rect.minY + pixel.y * rect.height / 600), to: nil)
                return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                         windowNumber: editor.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: mouse(.leftMouseDown, stroke[0]))
            for point in stroke.dropFirst() { canvas.mouseDragged(with: mouse(.leftMouseDragged, point)) }
            canvas.mouseUp(with: mouse(.leftMouseUp, stroke[0]))
            let outline = canvas.points
            XCTAssertGreaterThan(outline.count, 2)
            let bytes = try ImageCore.png(XCTUnwrap(model.reviewImage))
            var panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Capture Preview" && $0.isVisible })
            XCTAssertFalse(editor.isVisible)
            XCTAssertEqual(panel.level, .floating)
            XCTAssertLessThanOrEqual(panel.frame.width, 340)
            XCTAssertLessThan(panel.frame.height, 400)
            XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
            XCTAssertEqual(app.store.clips.count, screenCapture ? 0 : 1)
            app.refineCapture()
            canvas.refresh()
            XCTAssertTrue(editor.isVisible)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(canvas.points, outline)
            XCTAssertEqual(model.scale, 1.2)
            XCTAssertEqual(model.offset, CGPoint(x: 12, y: -18))
            model.undoSelection()
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), bytes)
            panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Capture Preview" && $0.isVisible })
            XCTAssertFalse(editor.isVisible)
            XCTAssertTrue(panel.performKeyEquivalent(with: key(36, in: panel)))
            model.confirm()
            XCTAssertNil(app.captureModel)
            XCTAssertEqual(app.store.clips.count, screenCapture ? 1 : 2, "Return saves exactly once")
        }
        for closeButton in [false, true] {
            app.presentCanvas(image: image, frame: screen.visibleFrame, screenCapture: true, name: "Cancel test")
            let model = try XCTUnwrap(app.captureModel)
            try model.prepareReview(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)])
            let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Capture Preview" && $0.isVisible })
            XCTAssertTrue(screen.visibleFrame.contains(panel.frame), "Corner selections must keep controls on screen")
            if closeButton { panel.performClose(nil) }
            else { XCTAssertTrue(panel.performKeyEquivalent(with: key(53, in: panel))) }
            XCTAssertNil(app.captureModel)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(app.store.clips.count, 2)
        }
    }

    @MainActor func testMenuBarStickerRendersAsATemplateAtBothDisplayScales() throws {
        _ = NSApplication.shared
        let icon = AppController.menuBarIcon()
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(icon.accessibilityDescription, "SnipShelf")
        for scale in [1, 2] {
            let size = 18 * scale
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
            let center = try XCTUnwrap(bitmap.colorAt(x: 9 * scale, y: 9 * scale))
            XCTAssertEqual(center.alphaComponent, 1)
            XCTAssertEqual(center.redComponent, 0)
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 12 * scale, y: 12 * scale)).alphaComponent, 0.5,
                              "The crease must be transparent so both menu-bar appearances show the fold")
        }
    }

    @MainActor func testInternalDropIsRejectedButExternalImageStillImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        let original = try store.add(image, name: "Original")
        let app = AppController(store: store, preferences: preferences)
        let provider = NSItemProvider(item: try ImageCore.png(image) as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = "原始圖片.v2.png"
        let unnamed = NSItemProvider(item: try ImageCore.png(image) as NSData, typeIdentifier: UTType.png.identifier)
        app.isDraggingClips = true
        XCTAssertFalse(app.acceptDrop([provider]))
        XCTAssertFalse(app.busy)
        XCTAssertEqual(store.clips, [original])
        app.isDraggingClips = false
        XCTAssertTrue(app.acceptDrop([provider, unnamed]))
        for _ in 0..<200 {
            if !app.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(app.busy)
        XCTAssertNil(store.message)
        XCTAssertEqual(store.clips.map(\.name), ["Dropped image", "原始圖片.v2", "Original"])
    }

    @MainActor func testShelfCardKeepsTransparentPixelsClear() async throws {
        _ = NSApplication.shared
        let source = try ImageCore.context(width: 40, height: 40)
        source.setFillColor(CGColor(srgbRed: 1, green: 0.3, blue: 0.1, alpha: 1))
        source.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        let card = ShelfCollection.CardView(frame: CGRect(x: 0, y: 0, width: 160, height: 153))
        card.picture.image = NSImage(cgImage: try XCTUnwrap(source.makeImage()), size: NSSize(width: 40, height: 40))
        card.layout()
        let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
        card.cacheDisplay(in: card.bounds, to: bitmap)
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / card.bounds.width),
                           y: Int(y * CGFloat(bitmap.pixelsHigh) / card.bounds.height))!.alphaComponent
        }
        XCTAssertLessThan(alpha(8, 8), 0.01, "The thumbnail well must not paint a checkerboard or solid background")
        XCTAssertGreaterThan(alpha(80, 63), 0.99, "The subject must still render")
    }

    @MainActor func testPreviewBackgroundPickerStaysInsetAfterFitAndResize() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let clip = try store.add(SnipShelfTests().image(width: 460, height: 460), name: "Fit layout regression")
        let app = AppController(store: store, preferences: preferences)
        app.previewClip = clip
        let window = try XCTUnwrap(NSApp.windows.first { $0 is ShelfPanel && $0.title == clip.name })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await Task.sleep(for: .milliseconds(150))
        for width: CGFloat in [560, 720, 900] {
            window.setContentSize(CGSize(width: width, height: 580))
            for command in ["1", "0", "0"] {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: command,
                                            charactersIgnoringModifiers: command, isARepeat: false, keyCode: command == "0" ? 29 : 18)!
                XCTAssertTrue(window.performKeyEquivalent(with: event))
                try await Task.sleep(for: .milliseconds(30))
                content.layoutSubtreeIfNeeded()
                let picker = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSegmentedControl }.first)
                let rect = picker.convert(picker.bounds, to: content)
                XCTAssertGreaterThanOrEqual(rect.minX, 19, "Picker must stay inside the 20-point toolbar inset")
                XCTAssertLessThanOrEqual(rect.maxX, content.bounds.maxX - 19)
                XCTAssertGreaterThanOrEqual(picker.bounds.width + 1, picker.intrinsicContentSize.width)
            }
        }
    }

    @MainActor func testNewClipSelectionAndFailedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        let old = try store.add(image, name: "Old")
        let fresh = try store.add(image, name: "Fresh")
        XCTAssertEqual(store.selectedClip, fresh)
        XCTAssertEqual(store.latestID, fresh.id)
        store.selection = old.id
        let index = root.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        store.receive(image, name: "Unsaved")
        XCTAssertEqual(store.selectedClip, old)
        XCTAssertNotNil(store.pendingImage)
    }

    @MainActor func testRefinementUndoRestoresTheRenderedOutlineAndPixels() async throws {
        _ = NSApplication.shared
        let model = CanvasModel(image: try SnipShelfTests().image(width: 100, height: 100), isScreen: false, complete: { _ in }, cancel: {})
        model.smoothing = 0; model.snapEnabled = false
        let view = CanvasNSView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        defer { window.close() }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 400 - y), modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, 40, 40))
        for p in [CGPoint(x: 320, y: 40), CGPoint(x: 320, y: 320), CGPoint(x: 40, y: 320)] {
            view.mouseDragged(with: mouse(.leftMouseDragged, p.x, p.y))
        }
        view.mouseUp(with: mouse(.leftMouseUp, 40, 40))
        let outline = view.points
        let original = try ImageCore.png(XCTUnwrap(model.reviewImage))
        model.continueSelection(); view.refresh()
        view.mouseDown(with: mouse(.leftMouseDown, 200, 40))
        view.mouseDragged(with: mouse(.leftMouseDragged, 240, 200))
        view.mouseUp(with: mouse(.leftMouseUp, 40, 40))
        XCTAssertNotEqual(view.points, outline)
        let undo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
        XCTAssertTrue(view.performKeyEquivalent(with: undo))
        XCTAssertEqual(view.points, outline)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), original)
        XCTAssertNil(model.previousOutline)
        model.reset(); view.refresh()
        XCTAssertTrue(view.points.isEmpty)
        model.undoSelection(); view.refresh()
        XCTAssertEqual(view.points, outline)
        XCTAssertTrue(model.reviewing)
        XCTAssertTrue(model.showCutout)
    }

    @MainActor func testEdgePullKeepsTrackingUntilReleaseOnBothSides() async throws {
        _ = NSApplication.shared
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let shelf = ShelfWindow(defaults: preferences)
        shelf.install(content: EmptyView(), key: { _ in false })
        defer { shelf.panel.close() }
        for edge in ["left", "right"] {
            shelf.edge = edge; shelf.collapse()
            try await Task.sleep(for: .milliseconds(260))
            let tab = shelf.panel.frame
            let start = CGPoint(x: tab.midX, y: tab.midY)
            let direction: CGFloat = edge == "left" ? 1 : -1
            shelf.beginMove(at: start)
            let opened = CGPoint(x: start.x + direction * 18, y: start.y)
            shelf.move(to: opened)
            XCTAssertFalse(shelf.collapsed)
            let first = shelf.panel.frame
            shelf.move(to: CGPoint(x: opened.x + direction * 5, y: opened.y - 10))
            XCTAssertEqual(shelf.panel.frame.minX, first.minX + direction * 5, accuracy: 0.1)
            XCTAssertEqual(shelf.panel.frame.minY, first.minY - 10, accuracy: 0.1)
            XCTAssertNil(shelf.snapEdge, "A short pull must not immediately tuck itself again")
            shelf.move(to: CGPoint(x: opened.x + direction * 70, y: opened.y - 10))
            XCTAssertEqual(shelf.panel.frame.minX, first.minX + direction * 70, accuracy: 0.1)
            shelf.endMove(wasClick: false)
            XCTAssertFalse(shelf.collapsed)
            XCTAssertFalse(preferences.bool(forKey: "shelfCollapsed"))
            let expanded = shelf.panel.frame
            let handle = CGPoint(x: expanded.midX, y: expanded.maxY - 14)
            let visible = shelf.screen.visibleFrame
            let dx = edge == "left" ? visible.minX + 12 - expanded.minX : visible.maxX - 12 - expanded.maxX
            shelf.beginMove(at: handle)
            shelf.move(to: CGPoint(x: handle.x + dx, y: handle.y))
            XCTAssertEqual(shelf.snapEdge, edge)
            XCTAssertFalse(shelf.collapsed, "The glass arrow is only a preview until release")
            XCTAssertEqual(shelf.panel.frame.size, expanded.size)
            shelf.move(to: handle)
            XCTAssertNil(shelf.snapEdge, "Pulling away restores the shelf before release")
            shelf.endMove(wasClick: false)
            XCTAssertFalse(shelf.collapsed)
        }
    }

    @MainActor func testPreviewNavigationAndKeyboardStayInPreview() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        for i in 0..<3 { try store.add(image, name: "Clip \(i)") }
        let app = AppController(store: store, preferences: preferences)
        app.previewClip = store.clips[0]
        defer { app.previewClip = nil }
        let window = try XCTUnwrap(NSApp.windows.first { $0 is ShelfPanel && $0.title == store.clips[0].name })
        XCTAssertTrue(window.styleMask.contains(.resizable))
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        XCTAssertNil(app.adjacentPreview(-1))
        XCTAssertTrue(app.handlePreviewKey(key(124)))
        XCTAssertEqual(app.previewClip, store.clips[1])
        XCTAssertEqual(store.selectedClip, store.clips[1])
        app.movePreview(1); app.movePreview(1)
        XCTAssertEqual(app.previewClip, store.clips[2])
        XCTAssertFalse(app.handlePreviewKey(key(51)), "Delete must not delete a shelf item behind the preview")
        XCTAssertEqual(store.clips.count, 3)
        XCTAssertTrue(app.handlePreviewKey(key(49)))
        XCTAssertNil(app.previewClip)
        XCTAssertFalse(window.isVisible)
        app.previewClip = store.clips[0]
        window.close()
        XCTAssertNil(app.previewClip)
    }

    @MainActor func testNativePreviewFitAndActualPixels() async throws {
        _ = NSApplication.shared
        let image = NSImage(cgImage: try SnipShelfTests().image(width: 2400, height: 1600), size: NSSize(width: 2400, height: 1600))
        let host = NSHostingView(rootView: PreviewImage(image: image, actualSize: false, reset: 0, onKey: { _ in false }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
        func scrollIn(_ view: NSView) -> PreviewImage.ImageScrollView? {
            if let scroll = view as? PreviewImage.ImageScrollView { return scroll }
            return view.subviews.lazy.compactMap(scrollIn).first
        }
        let scroll = try XCTUnwrap(scrollIn(host))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(scroll.magnification, 1)
        let picture = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(picture.frame.width * scroll.magnification, scroll.contentSize.width)
        XCTAssertLessThanOrEqual(picture.frame.height * scroll.magnification, scroll.contentSize.height)
        host.rootView = PreviewImage(image: image, actualSize: true, reset: 1, onKey: { _ in false })
        host.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        XCTAssertEqual(picture.frame.width * window.backingScaleFactor, 2400, accuracy: 0.1)
        XCTAssertTrue(scroll.allowsMagnification)
        XCTAssertTrue(scroll.hasHorizontalScroller)
    }

    @MainActor func testRenderInterfaceWhenRequested() async throws {
        guard let destination = ProcessInfo.processInfo.environment["SNIPSHELF_RENDER_QA"] else { return }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let app = AppController(store: store, preferences: preferences)
        app.shelf.install(content: ShelfView(app: app), key: app.handleKey)
        defer { app.shelf.panel.close(); app.previewClip = nil }
        let context = try ImageCore.context(width: 900, height: 600)
        context.setFillColor(CGColor(srgbRed: 0.22, green: 0.55, blue: 0.44, alpha: 1))
        context.fillEllipse(in: CGRect(x: 160, y: 70, width: 490, height: 440))
        context.setFillColor(CGColor(srgbRed: 0.87, green: 0.91, blue: 0.73, alpha: 1))
        context.fillEllipse(in: CGRect(x: 350, y: 160, width: 240, height: 240))
        let artwork = try XCTUnwrap(context.makeImage())
        for name in ["Botanical study", "Shape & color", "Leaf detail", "Studio reference"] {
            try store.add(artwork, name: name)
        }
        let model = CanvasModel(image: artwork, isScreen: false, complete: { _ in }, cancel: {})
        try model.prepareReview(points: [CGPoint(x: 120, y: 90), CGPoint(x: 680, y: 90), CGPoint(x: 590, y: 530), CGPoint(x: 200, y: 470)])
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func render(_ view: NSView, size: CGSize, name: String, appearance: NSAppearance.Name) async throws {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            window.contentView = view; view.frame = CGRect(origin: .zero, size: size)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            defer { window.close() }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        for (appearance, suffix): (NSAppearance.Name, String) in [(.aqua, "light"), (.darkAqua, "dark")] {
            try await render(NSHostingView(rootView: CaptureReviewView(image: XCTUnwrap(model.reviewImage), refine: {}, confirm: {})),
                             size: CGSize(width: 340, height: 300), name: "capture-review-" + suffix, appearance: appearance)
            try await render(NSHostingView(rootView: ShelfView(app: app)), size: CGSize(width: 340, height: 440), name: "shelf-" + suffix, appearance: appearance)
            try await render(NSHostingView(rootView: SettingsView(app: app)), size: CGSize(width: 460, height: 360), name: "settings-" + suffix, appearance: appearance)
            model.showCutout = true
            try await render(NSHostingView(rootView: CaptureView(model: model)), size: CGSize(width: 960, height: 720), name: "cutout-" + suffix, appearance: appearance)
            model.showCutout = false
            try await render(NSHostingView(rootView: CaptureView(model: model)), size: CGSize(width: 960, height: 720), name: "original-" + suffix, appearance: appearance)
            for edge in ["left", "right"] {
                app.shelf.snapEdge = edge
                try await render(NSHostingView(rootView: ShelfView(app: app).background(Color(nsColor: .windowBackgroundColor))),
                                 size: CGSize(width: 340, height: 440), name: "docking-" + edge + "-" + suffix, appearance: appearance)
            }
            app.shelf.snapEdge = nil
        }
        app.previewClip = store.clips[0]
        try await Task.sleep(for: .milliseconds(300))
        let previewWindow = try XCTUnwrap(NSApp.windows.first { $0 is ShelfPanel && $0.title == store.clips[0].name })
        let view = try XCTUnwrap(previewWindow.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("preview.png"))
    }
}
