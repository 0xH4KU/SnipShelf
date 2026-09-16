import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import SnipShelf

final class InteractionTests: XCTestCase {
    @MainActor func testShortcutKeyboardActivationAndCopyFeedback() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let store = ShelfStore(root: root)
        let app = AppController(store: store, preferences: preferences)
        let recorder = ShortcutRecorder.RecorderView(app: app)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = recorder
        let board = NSPasteboard.general
        let savedItems = (board.pasteboardItems ?? []).map { source in
            let item = NSPasteboardItem()
            for type in source.types { if let data = source.data(forType: type) { item.setData(data, forType: type) } }
            return item
        }
        defer {
            window.close()
            board.clearContents(); board.writeObjects(savedItems)
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        func key(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        recorder.keyDown(with: try key(49))
        XCTAssertTrue(recorder.recording, "Space must activate the focused shortcut button")
        XCTAssertNil(store.message, "Activation must not try to register Space as a shortcut")
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key(53)))
        XCTAssertFalse(recorder.recording)
        XCTAssertEqual(recorder.title, app.shortcutLabel)
        XCTAssertEqual(recorder.accessibilityValue() as? String, app.shortcutLabel)
        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertTrue(recorder.recording)
        window.makeFirstResponder(nil)
        XCTAssertFalse(recorder.recording, "Leaving the control cancels recording")

        let first = try store.add(SnipShelfTests().image(), name: "First")
        let second = try store.add(SnipShelfTests().image(), name: "Second")
        app.copy(first)
        XCTAssertEqual(app.copiedClipID, first.id)
        XCTAssertNotNil(board.data(forType: .png))
        try await Task.sleep(for: .milliseconds(600))
        app.copy(second)
        XCTAssertEqual(app.copiedClipID, second.id)
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertEqual(app.copiedClipID, second.id, "An earlier copy must not clear the latest feedback")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(app.copiedClipID)
        XCTAssertNil(app.status)
    }

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
            XCTAssertTrue(model.fluidDrawing)
            XCTAssertTrue(model.showRemovedAreas)
            let editor = try XCTUnwrap(NSApp.windows.first { $0.title == "Crop a Copy" && $0.isVisible })
            XCTAssertFalse(editor.hidesOnDeactivate, "An unfinished selection must stay reachable when focus changes")
            try await Task.sleep(for: .milliseconds(80))
            var canvas = try XCTUnwrap(descendants(XCTUnwrap(editor.contentView)).compactMap { $0 as? CanvasNSView }.first)
            let sourceCanvas = canvas
            model.scale = 1.2; model.offset = CGPoint(x: 12, y: -18)
            model.smoothing = 0; model.snapEnabled = false; model.subjectMaskEnabled = false
            let stroke = [CGPoint(x: 250, y: 200), CGPoint(x: 650, y: 200), CGPoint(x: 600, y: 320), CGPoint(x: 260, y: 300)]
            func mouse(_ type: NSEvent.EventType, _ pixel: CGPoint) -> NSEvent {
                let rect = canvas.imageRect
                let location = canvas.convert(CGPoint(x: rect.minX + pixel.x * rect.width / 900,
                                                     y: rect.minY + pixel.y * rect.height / 600), to: nil)
                return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                         windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: mouse(.leftMouseDown, stroke[0]))
            for point in stroke.dropFirst() { canvas.mouseDragged(with: mouse(.leftMouseDragged, point)) }
            canvas.mouseUp(with: mouse(.leftMouseUp, stroke[0]))
            let outline = canvas.points
            XCTAssertGreaterThan(outline.count, 2)
            let bytes = try ImageCore.png(XCTUnwrap(model.reviewImage))
            let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Capture Preview" && $0.isVisible })
            XCTAssertFalse(editor.isVisible)
            XCTAssertEqual(panel.level, .floating)
            XCTAssertFalse(panel.hidesOnDeactivate, "The review must remain visible alongside the desktop")
            XCTAssertLessThanOrEqual(panel.frame.width, 440)
            XCTAssertLessThan(panel.frame.height, 600)
            XCTAssertTrue(panel.styleMask.contains(.resizable))
            XCTAssertFalse(panel.isMovableByWindowBackground, "Painting must not drag the preview window")
            XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
            XCTAssertEqual(app.store.clips.count, screenCapture ? 0 : 1)
            panel.orderOut(nil)
            app.capture()
            XCTAssertTrue(panel.isVisible, "Capture must bring back the pending review instead of silently ignoring the action")
            XCTAssertTrue(app.captureModel === model)
            app.refineCapture()
            canvas.refresh()
            XCTAssertTrue(editor.isVisible)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(canvas.points, outline)
            XCTAssertEqual(model.scale, 1.2)
            XCTAssertEqual(model.offset, CGPoint(x: 12, y: -18))
            editor.orderOut(nil)
            app.capture()
            XCTAssertTrue(editor.isVisible, "Refining must bring back the source editor, not the hidden review")
            model.undoSelection()
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), bytes)
            XCTAssertTrue(panel === NSApp.windows.first { $0.title == "Capture Preview" && $0.isVisible })
            XCTAssertFalse(editor.isVisible)
            model.subjectMaskEnabled = true
            await model.correctionTask?.value
            let reviewFrame = panel.frame
            model.showCutout = false; model.maskTool = .restore
            try await Task.sleep(for: .milliseconds(80))
            panel.layoutIfNeeded()
            canvas = try XCTUnwrap(descendants(XCTUnwrap(panel.contentView)).compactMap { $0 as? CanvasNSView }.first)
            canvas.refresh()
            XCTAssertTrue(canvas.reviewOnly)
            XCTAssertFalse(editor.isVisible, "Touch-up tools must never reopen the screen-sized source editor")
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.frame, reviewFrame)
            XCTAssertTrue(model.reviewing)
            XCTAssertFalse(model.showCutout)
            XCTAssertEqual(model.maskTool, .restore)
            XCTAssertEqual(model.reviewPoints, outline)
            XCTAssertEqual(model.scale, 1.2)
            XCTAssertEqual(model.offset, CGPoint(x: 12, y: -18))
            XCTAssertTrue(try descendants(XCTUnwrap(editor.contentView)).contains { $0 === sourceCanvas })
            XCTAssertTrue(try canvas.bounds.contains(canvas.convert(panel.convertFromScreen(XCTUnwrap(canvas.reviewScreenRect)), from: nil)),
                          "The preview must fit the selected region instead of the whole screenshot")
            model.reviewScale = 1.4; model.reviewOffset = CGPoint(x: 14, y: -8)
            let pointer = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            let pixel = model.session.pixelPoint(pointer, in: canvas.imageRect)
            canvas.zoom(by: 1.2, at: pointer)
            let zoomedPixel = model.session.pixelPoint(pointer, in: canvas.imageRect)
            XCTAssertEqual(pixel.x, zoomedPixel.x, accuracy: 0.001)
            XCTAssertEqual(pixel.y, zoomedPixel.y, accuracy: 0.001)
            XCTAssertEqual(model.scale, 1.2)
            XCTAssertEqual(model.offset, CGPoint(x: 12, y: -18), "Preview zoom must not move the source selection")
            // Restore source pixels first so the edit check does not depend on Vision recognizing this synthetic image.
            model.brushSize = 24
            canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 350, y: 240)))
            canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 240)))
            let restored = try ImageCore.png(XCTUnwrap(model.reviewImage))
            model.maskTool = .erase
            canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 350, y: 240)))
            canvas.keyDown(with: key(36, in: panel))
            XCTAssertTrue(app.captureModel === model, "Return during a stroke must not save")
            canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 400, y: 240)))
            canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 240)))
            let edited = try ImageCore.png(XCTUnwrap(model.reviewImage))
            XCTAssertNotEqual(edited, restored)
            model.undoSelection()
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), restored)
            XCTAssertTrue(panel.isVisible, "Brush undo must stay in the same preview")
            XCTAssertFalse(editor.isVisible)
            model.redoMaskStroke()
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited)
            model.subjectMaskEnabled = false
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), bytes)
            model.subjectMaskEnabled = true
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited)
            model.maskTool = .erase
            XCTAssertTrue(panel.performKeyEquivalent(with: key(53, in: panel)))
            XCTAssertEqual(model.maskTool, .view)
            XCTAssertTrue(app.captureModel === model, "Escape leaves the brush before cancelling capture")
            let offset = model.reviewOffset
            canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 350, y: 240)))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 360, y: 245)))
            canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 360, y: 245)))
            XCTAssertNotEqual(model.reviewOffset, offset, "View mode drags pan without painting")
            XCTAssertEqual(model.offset, CGPoint(x: 12, y: -18))
            XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited)
            panel.setContentSize(CGSize(width: 380, height: 460))
            let resizedFrame = panel.frame
            if screenCapture {
                app.refineCapture(); model.undoSelection()
                await model.correctionTask?.value
                XCTAssertTrue(panel === NSApp.windows.first { $0.title == "Capture Preview" && $0.isVisible })
                XCTAssertEqual(panel.frame, resizedFrame, "Refinement must retain the floating window's size and placement")
                XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), edited)
                XCTAssertTrue(panel.performKeyEquivalent(with: key(36, in: panel)))
            } else {
                canvas.keyDown(with: key(36, in: panel))
            }
            model.confirm()
            XCTAssertNil(app.captureModel)
            XCTAssertEqual(app.store.clips.count, screenCapture ? 1 : 2, "Return saves exactly once")
            XCTAssertEqual(try Data(contentsOf: app.store.url(for: XCTUnwrap(app.store.clips.first))), edited,
                           "The main app must save the edited cutout without the cyan guide")
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

    @MainActor func testCaptureShortcutsWorkAfterControlsTakeFocus() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let app = AppController(store: ShelfStore(root: root), preferences: preferences)
        let source = try SnipShelfTests().image(width: 100, height: 100)
        app.presentCanvas(image: source, frame: CGRect(x: 100, y: 100, width: 640, height: 480), screenCapture: false, name: "Shortcuts")
        let model = try XCTUnwrap(app.captureModel)
        defer { model.cancel() }
        try model.prepareReview(points: SnipShelfTests().rect(10, 10, 80, 80))
        await model.correctionTask?.value
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Capture Preview" && $0.isVisible })
        try await Task.sleep(for: .milliseconds(80))
        let slider = NSSlider(value: 24, minValue: 1, maxValue: 128, target: nil, action: nil)
        panel.contentView?.addSubview(slider)
        func key(_ text: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        func send(_ text: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            XCTAssertTrue(panel.makeFirstResponder(slider))
            panel.sendEvent(key(text, code, flags))
        }
        send("e", 14)
        XCTAssertEqual(model.maskTool, .erase)
        send("]", 30)
        XCTAssertEqual(model.brushSize, 26)
        send("［", 33) // A Chinese input source must not swallow the physical bracket key.
        XCTAssertEqual(model.brushSize, 24)
        send("r", 15)
        XCTAssertEqual(model.maskTool, .restore)
        send("v", 9)
        XCTAssertEqual(model.maskTool, .view)
        send("=", 24, .command)
        XCTAssertEqual(model.reviewScale, 1.25)
        send("+", 24, [.command, .shift])
        XCTAssertEqual(model.reviewScale, 1.5625)
        send("-", 27, .command)
        XCTAssertEqual(model.reviewScale, 1.25)
        send("1", 18, .command)
        XCTAssertTrue(model.reviewActualSize)
        send("0", 29, .command)
        XCTAssertFalse(model.reviewActualSize)
        XCTAssertEqual(model.reviewScale, 1)
        XCTAssertEqual(model.scale, 1, "Preview shortcuts must not move the source canvas")

        model.maskTool = .erase; model.brushSize = 10
        model.beginMaskStroke(at: CGPoint(x: 30, y: 40)); model.endMaskStroke()
        let firstStroke = try ImageCore.png(XCTUnwrap(model.reviewImage))
        model.beginMaskStroke(at: CGPoint(x: 60, y: 40)); model.endMaskStroke()
        let secondStroke = try ImageCore.png(XCTUnwrap(model.reviewImage))
        XCTAssertNotEqual(firstStroke, secondStroke)
        send("z", 6, .command)
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), firstStroke, "Undo must remove exactly one stroke even when a slider has focus")
        XCTAssertTrue(panel.makeFirstResponder(slider))
        XCTAssertTrue(panel.performKeyEquivalent(with: key("z", 6, [.command, .shift])))
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), secondStroke)

        model.beginMaskStroke(at: CGPoint(x: 45, y: 60))
        send("=", 24, .command); send("]", 30); send("r", 15); send("z", 6, .command)
        XCTAssertEqual(model.reviewScale, 1)
        XCTAssertEqual(model.brushSize, 10)
        XCTAssertEqual(model.maskTool, .erase)
        XCTAssertTrue(model.paintingMask)
        model.cancelMaskStroke()
        XCTAssertEqual(try ImageCore.png(XCTUnwrap(model.reviewImage)), secondStroke)
        XCTAssertTrue(app.store.clips.isEmpty)
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
        let image = NSImage(cgImage: try XCTUnwrap(source.makeImage()), size: NSSize(width: 40, height: 40))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for grouped in [false, true] {
                let card = ShelfCollection.CardView(frame: CGRect(x: 0, y: 0, width: 160, height: 153))
                card.appearance = NSAppearance(named: appearance)
                card.folderID = grouped ? UUID() : nil
                card.picture.image = image
                card.related.forEach { $0.image = image; $0.isHidden = !grouped }
                card.layout()
                let bitmap = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
                card.cacheDisplay(in: card.bounds, to: bitmap)
                func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                    bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / card.bounds.width),
                                   y: Int(y * CGFloat(bitmap.pixelsHigh) / card.bounds.height))!.alphaComponent
                }
                XCTAssertLessThan(alpha(8, 8), 0.01)
                for thumbnail in [card.picture] + card.related.filter({ !$0.isHidden }) {
                    let frame = thumbnail.convert(thumbnail.bounds, to: card)
                    XCTAssertLessThan(alpha(frame.minX + 2, frame.minY + 2), 0.01,
                                      "Every thumbnail must keep transparent pixels clear in \(appearance)")
                    XCTAssertGreaterThan(alpha(frame.midX, frame.midY), 0.99,
                                         "The subject must still render")
                }
                for frame in card.relatedFrames where !frame.isHidden {
                    XCTAssertGreaterThan(alpha(frame.frame.minX + 0.5, frame.frame.midY), 0.03,
                                         "The thumbnail outline must remain visible without an opaque fill")
                }
            }
        }
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
        model.smoothing = 0; model.snapEnabled = false; model.subjectMaskEnabled = false
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
            for width: CGFloat in [300, 450, 600] {
                shelf.panel.setContentSize(CGSize(width: width, height: 440))
                shelf.recoverScreen()
                let expanded = shelf.panel.frame
                let handle = CGPoint(x: expanded.midX, y: expanded.maxY - 14)
                let visible = shelf.screen.visibleFrame
                shelf.beginMove(at: handle)
                for (overflow, shouldDock): (CGFloat, Bool) in [(-12, false), (0, false), (width / 3 - 1, false),
                                                               (width / 3, true), (width / 3 + 12, true), (width / 3 - 1, false)] {
                    let dx = edge == "left" ? visible.minX - overflow - expanded.minX : visible.maxX + overflow - expanded.maxX
                    shelf.move(to: CGPoint(x: handle.x + dx, y: handle.y))
                    XCTAssertEqual(shelf.snapEdge, shouldDock ? edge : nil, "\(edge), width \(width), overflow \(overflow)")
                    XCTAssertFalse(shelf.collapsed, "The glass arrow is only a preview until release")
                    XCTAssertEqual(shelf.panel.frame.size, expanded.size)
                }
                shelf.endMove(wasClick: false)
                XCTAssertFalse(shelf.collapsed, "Retreating below one third must cancel docking")
                XCTAssertTrue(visible.contains(shelf.panel.frame))
            }
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
        let folder = try store.createFolder(name: "Shape references", including: Set(store.clips.prefix(3).map(\.id)))
        for (name, count) in [("Color studies", 5), ("Reference elements with a longer name", 8)] {
            let group = try store.createFolder(name: name)
            for index in 1...count { try store.add(artwork, name: "Study \(index)", folderID: group.id) }
        }
        store.latestID = nil; store.selection = nil
        let model = CanvasModel(image: artwork, isScreen: false, complete: { _ in }, cancel: {})
        try model.prepareReview(points: [CGPoint(x: 120, y: 90), CGPoint(x: 680, y: 90), CGPoint(x: 590, y: 530), CGPoint(x: 200, y: 470)])
        await model.correctionTask?.value
        model.maskTool = .restore
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = directory.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try Data(contentsOf: file).write(to: storage.appendingPathComponent(file.lastPathComponent), options: .atomic)
        }
        func render(_ view: NSView, size: CGSize, name: String, appearance: NSAppearance.Name, hover: Bool = false) async throws {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
            window.contentView = view; view.frame = CGRect(origin: .zero, size: size)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            defer { window.close() }
            if name.hasPrefix("capture-review") || name.hasPrefix("touch-up-small") {
                XCTAssertEqual(view.bounds.width, size.width, accuracy: 1, "Controls must fit the compact preview")
                XCTAssertEqual(view.bounds.height, size.height, accuracy: 1, "The cutout must fit the compact confirmation window")
            }
            if hover {
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let card = try XCTUnwrap(descendants(view).compactMap { $0 as? ShelfCollection.CardView }.first { $0.folderID != nil })
                card.setHovered(true)
                try await Task.sleep(for: .milliseconds(250))
                view.displayIfNeeded()
            }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        for (appearance, suffix): (NSAppearance.Name, String) in [(.aqua, "light"), (.darkAqua, "dark")] {
            for hover in [false, true] {
                let item = ShelfCollection.Item()
                item.configure(app: app, entry: .group(folder, store.clips.reversed().filter { $0.folderID == folder.id }))
                try await render(item.view, size: CGSize(width: 144, height: 153),
                                 name: "group-card-\(hover ? "hover" : "rest")-" + suffix, appearance: appearance, hover: hover)
            }
            try await render(NSHostingView(rootView: CaptureReviewView(model: model, refine: {})),
                             size: CGSize(width: 440, height: 540), name: "capture-review-" + suffix, appearance: appearance)
            try await render(NSHostingView(rootView: ShelfView(app: app)), size: CGSize(width: 340, height: 440), name: "shelf-" + suffix, appearance: appearance)
            try await render(NSHostingView(rootView: ShelfView(app: app)), size: CGSize(width: 340, height: 440), name: "shelf-hover-" + suffix, appearance: appearance, hover: true)
            try await render(NSHostingView(rootView: ShelfView(app: app)), size: CGSize(width: 300, height: 280), name: "shelf-small-" + suffix, appearance: appearance)
            let contrastShelf = ShelfView(app: app)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            let contrastAppearance: NSAppearance.Name = appearance == .darkAqua ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
            try await render(NSHostingView(rootView: contrastShelf), size: CGSize(width: 340, height: 440), name: "shelf-contrast-" + suffix, appearance: contrastAppearance)
            store.selectedIDs = Set(store.visibleClips.map(\.id))
            try await render(NSHostingView(rootView: contrastShelf), size: CGSize(width: 300, height: 280), name: "shelf-selected-small-" + suffix, appearance: appearance)
            store.selectedIDs = []
            store.openFolder(folder.id)
            try await render(NSHostingView(rootView: ShelfView(app: app)), size: CGSize(width: 340, height: 440), name: "folder-" + suffix, appearance: appearance)
            let emptyFolder = try store.createFolder(name: "Icon studies")
            store.openFolder(emptyFolder.id)
            try await render(NSHostingView(rootView: ShelfView(app: app)), size: CGSize(width: 300, height: 280), name: "folder-empty-small-" + suffix, appearance: appearance)
            store.dissolveFolder(emptyFolder.id)
            try await render(NSHostingView(rootView: SettingsView(app: app)), size: CGSize(width: 460, height: 360), name: "settings-" + suffix, appearance: appearance)
            model.showCutout = true
            try await render(NSHostingView(rootView: CaptureReviewView(model: model, refine: {})), size: CGSize(width: 440, height: 540), name: "cutout-" + suffix, appearance: appearance)
            model.showCutout = false
            try await render(NSHostingView(rootView: CaptureReviewView(model: model, refine: {})), size: CGSize(width: 440, height: 540), name: "original-" + suffix, appearance: appearance)
            try await render(NSHostingView(rootView: CaptureReviewView(model: model, refine: {})), size: CGSize(width: 360, height: 440), name: "touch-up-small-" + suffix, appearance: appearance)
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
