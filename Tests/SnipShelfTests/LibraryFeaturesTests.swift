import XCTest
import AppKit
import SwiftUI
@testable import SnipShelf

final class LibraryFeaturesTests: XCTestCase {
    @MainActor func testSearchSpansGroupsAndKeepsPreviewAndTextEditingInContext() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root), image = try SnipShelfTests().image()
        let group = try store.createFolder(name: "品牌參考")
        let loose = try store.add(image, name: "Café Button")
        let member = try store.add(image, name: "Button detail", folderID: group.id)
        let other = try store.add(image, name: "Poster", folderID: group.id)
        store.selection = loose.id
        store.browsingStates[nil, default: .init()].scrollOrigin = CGPoint(x: 0, y: 80)
        store.searchText = "  CAFE  "
        XCTAssertEqual(store.visibleClips.map(\.id), [loose.id])
        store.searchText = "品牌"
        XCTAssertEqual(Set(store.visibleClips.map(\.id)), [member.id, other.id])
        store.searchText = "Button"
        XCTAssertEqual(Set(store.visibleClips.map(\.id)), [member.id, loose.id])
        let app = AppController(store: store)
        app.shelf.install(content: ShelfView(app: app), key: app.handleKey)
        defer { app.previewClip = nil; app.shelf.panel.close() }
        app.previewClip = member
        XCTAssertEqual(store.searchText, "Button")
        XCTAssertNil(store.currentFolderID)
        XCTAssertEqual(Set(app.previewClips.map(\.id)), [member.id, loose.id])
        app.movePreview(1)
        XCTAssertEqual(app.previewClip?.id, loose.id)
        app.previewClip = nil
        try await Task.sleep(for: .milliseconds(100))
        func collection(_ view: NSView) -> ShelfCollection.CollectionView? {
            (view as? ShelfCollection.CollectionView) ?? view.subviews.lazy.compactMap(collection).first
        }
        let grid = try XCTUnwrap(collection(app.shelf.panel.contentView!))
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 2, "Search results contain clips, including members of other groups")
        grid.updateLayout(for: 590)
        XCTAssertEqual(app.shelfColumns, 4)
        XCTAssertEqual((grid.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize.height, 191)
        let field = NSTextField(string: "Button")
        app.shelf.panel.contentView!.addSubview(field)
        app.shelf.panel.makeKeyAndOrderFront(nil)
        field.selectText(nil)
        XCTAssertTrue(app.shelf.panel.firstResponder is NSTextView)
        for (code, text, flags): (UInt16, String, NSEvent.ModifierFlags) in [(51, "", []), (0, "a", .command), (9, "v", .command), (8, "c", .command)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: app.shelf.panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!
            XCTAssertFalse(app.handleKey(event), "Search editing must reach the native text field")
        }
        XCTAssertEqual(store.clips.count, 3)
        store.selectedIDs = [member.id]
        try store.renameClip(member.id, name: "Renamed")
        XCTAssertTrue(store.selectedIDs.isEmpty, "Renamed results must not leave hidden clips selected")
        store.undo()
        XCTAssertEqual(store.searchText, "Button")
        XCTAssertEqual(store.selectedIDs, [member.id])
        store.delete([member.id]); store.undo()
        XCTAssertEqual(store.searchText, "Button")
        XCTAssertTrue(store.visibleClips.contains(member))
        _ = try store.add(image, name: "Does not match search")
        XCTAssertEqual(store.selectedIDs, [member.id], "An unrelated import cannot select a hidden result")
        store.searchText = ""
        XCTAssertEqual(store.selectedIDs, [loose.id])
        XCTAssertEqual(store.browsingStates[nil]?.scrollOrigin.y, 80)
        store.openFolder(group.id)
        store.selection = member.id
        store.searchText = "Café"
        store.searchText = ""
        XCTAssertEqual(store.currentFolderID, group.id)
        XCTAssertEqual(store.selectedIDs, [member.id])
    }

    @MainActor func testRecentlyDeletedSurvivesRelaunchAndPurgeCannotBeUndone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ShelfStore(root: root), image = try SnipShelfTests().image()
        let folder = try original.createFolder(name: "Keep this group")
        let a = try original.add(image, name: "A", folderID: folder.id)
        let b = try original.add(image, name: "B")
        let bytes = try Data(contentsOf: original.url(for: a))
        original.delete([a.id, b.id])
        let store = ShelfStore(root: root)
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertEqual(Set(store.deleted.map(\.id)), [a.id, b.id])
        XCTAssertEqual(try Data(contentsOf: store.url(for: a)), bytes)
        store.restoreDeleted([a.id])
        XCTAssertEqual(store.clips, [a])
        store.undo()
        XCTAssertTrue(store.clips.isEmpty)
        store.dissolveFolder(folder.id)
        XCTAssertTrue(store.deleted.allSatisfy { $0.clip.folderID == nil })
        store.undo()
        XCTAssertEqual(store.deleted.first { $0.id == a.id }?.clip.folderID, folder.id)
        store.restoreDeleted([a.id])
        store.delete([a.id])
        let index = root.appendingPathComponent("index.json"), saved = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.permanentlyDelete([a.id]))
        XCTAssertEqual(Set(store.deleted.map(\.id)), [a.id, b.id])
        XCTAssertEqual(try Data(contentsOf: store.url(for: a)), bytes)
        try FileManager.default.removeItem(at: index); try saved.write(to: index)
        try store.permanentlyDelete([a.id])
        while !store.undoHistory.isEmpty { store.undo() }
        XCTAssertFalse(store.clips.contains { $0.id == a.id })
        XCTAssertFalse(store.deleted.contains { $0.id == a.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: a).path))
        XCTAssertEqual(ShelfStore(root: root).deleted.map(\.id), [b.id])
    }

    @MainActor func testBackupRoundTripValidationAndPreviousLibraryRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library"), store = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        let folder = try store.createFolder(name: "Saved group")
        let a = try store.add(image, name: "Original", folderID: folder.id)
        let arranged = try store.add(image, name: "Arranged", folderID: folder.id)
        XCTAssertTrue(store.reorder([a.id, arranged.id], in: folder.id))
        let b = try store.add(image, name: "Deleted")
        store.delete([b.id])
        let snapshot = store.clips, trash = store.deleted, png = try Data(contentsOf: store.url(for: a))
        let backup = directory.appendingPathComponent("Saved.snipshelfbackup")
        try await store.backup(to: backup)
        try await store.backup(to: backup) // Replacing an existing backup must be complete, too.
        XCTAssertEqual(try ShelfBackup.readIndex(at: backup).clips, snapshot)
        XCTAssertEqual(try ShelfBackup.readIndex(at: backup).itemOrder, [a.id, arranged.id])
        XCTAssertFalse(store.isReadOnly)
        let later = try store.add(image, name: "Added after backup")
        try store.renameFolder(folder.id, name: "Changed")
        let beforeRestore = store.clips
        let recovery = try await store.restoreBackup(from: backup)
        XCTAssertEqual(store.clips, snapshot); XCTAssertEqual(store.deleted, trash)
        XCTAssertEqual(store.folders, [folder]); XCTAssertTrue(store.undoHistory.isEmpty)
        XCTAssertEqual(store.clips(in: folder.id).map(\.id), [a.id, arranged.id])
        XCTAssertEqual(try Data(contentsOf: store.url(for: a)), png)
        XCTAssertEqual(ShelfStore(root: root).clips, snapshot)
        let previous = try ShelfBackup.readIndex(at: recovery)
        XCTAssertEqual(previous.clips, beforeRestore)
        XCTAssertTrue(previous.clips.contains(later))
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("\(later.id).png")), png)

        let broken = directory.appendingPathComponent("Broken.snipshelfbackup")
        try FileManager.default.copyItem(at: backup, to: broken)
        try FileManager.default.removeItem(at: broken.appendingPathComponent("\(a.id).png"))
        let unchanged = try Data(contentsOf: root.appendingPathComponent("index.json"))
        do { try await store.restoreBackup(from: broken); XCTFail("A missing image must reject the whole restore") } catch {}
        XCTAssertEqual(store.clips, snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), unchanged)
        XCTAssertFalse(store.isReadOnly)
        try FileManager.default.createSymbolicLink(at: broken.appendingPathComponent("\(a.id).png"), withDestinationURL: store.url(for: a))
        do { try await store.restoreBackup(from: broken); XCTFail("Backups must not follow asset symlinks") } catch {}
        do { try await store.backup(to: root.appendingPathComponent("Nested.snipshelfbackup")); XCTFail("Backups cannot overwrite their own source") } catch {}
        XCTAssertEqual(try Data(contentsOf: store.url(for: a)), png)
        let legacy = ShelfStore.Index(version: 2, clips: snapshot, folders: [folder])
        try JSONEncoder().encode(legacy).write(to: broken.appendingPathComponent("index.json"))
        try FileManager.default.removeItem(at: broken.appendingPathComponent("\(a.id).png"))
        try png.write(to: broken.appendingPathComponent("\(a.id).png"))
        try await store.restoreBackup(from: broken)
        XCTAssertEqual(store.clips, snapshot); XCTAssertTrue(store.deleted.isEmpty)
        try JSONEncoder().encode(ShelfStore.Index(version: 99, clips: [], folders: [])).write(to: broken.appendingPathComponent("index.json"))
        do { try await store.restoreBackup(from: broken); XCTFail("Future indexes must not replace current data") } catch {}
        XCTAssertEqual(store.clips, snapshot)
    }

    @MainActor func testRectangleRetainsPixelsAndContinuousCaptureUsesChosenGroup() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests.rectangle." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let image = try SnipShelfTests().image(width: 100, height: 100)
        let model = CanvasModel(image: image, isScreen: false, preferences: preferences,
            subjectCutout: { _, _ in XCTFail("Rectangle capture must not run background removal by default"); return nil }, complete: { _ in }, cancel: {})
        XCTAssertTrue(model.subjectMaskEnabled)
        model.mode = .rectangle
        XCTAssertFalse(model.subjectMaskEnabled)
        model.mode = .lasso
        XCTAssertTrue(model.subjectMaskEnabled)
        model.mode = .rectangle
        let view = CanvasNSView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for reverse in [false, true] {
            let a = CGPoint(x: 40, y: 80), b = CGPoint(x: 320, y: 360)
            view.mouseDown(with: mouse(.leftMouseDown, reverse ? b : a))
            view.mouseDragged(with: mouse(.leftMouseDragged, reverse ? a : b))
            view.mouseUp(with: mouse(.leftMouseUp, reverse ? a : b))
            let crop = try XCTUnwrap(model.reviewImage)
            XCTAssertEqual(crop.width, 70); XCTAssertEqual(crop.height, 70)
            let expected = try ImageCore.crop(image, points: SnipShelfTests().rect(10, 20, 70, 70))
            XCTAssertEqual(try ImageCore.png(crop), try ImageCore.png(expected))
            for (x, y) in [(0, 0), (69, 0), (0, 69), (69, 69)] { XCTAssertEqual(SnipShelfTests().color(crop, x, y).alphaComponent, 1) }
            model.reset(); view.refresh()
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 40, y: 40)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 41, y: 41)))
        XCTAssertFalse(model.reviewing)
        let app = AppController(store: ShelfStore(root: root), preferences: preferences)
        let group = try app.store.createFolder(name: "Capture destination")
        app.presentCanvas(image: image, frame: CGRect(x: 100, y: 100, width: 640, height: 480), screenCapture: false, name: "Rectangle")
        let capture = try XCTUnwrap(app.captureModel)
        defer { capture.cancel() }
        XCTAssertEqual(capture.mode, .rectangle); XCTAssertFalse(capture.subjectMaskEnabled)
        app.captureFolderID = group.id
        for _ in 0..<2 {
            try capture.prepareReview(points: SnipShelfTests().rect(10, 10, 70, 70))
            capture.confirm(keepSelecting: true)
            XCTAssertTrue(app.captureModel === capture)
            XCTAssertFalse(capture.reviewing)
            XCTAssertFalse(capture.selecting)
            XCTAssertNil(capture.previousOutline, "A saved selection must not be resurrected by refinement undo")
        }
        XCTAssertEqual(app.store.clips.count, 2)
        XCTAssertTrue(app.store.clips.allSatisfy { $0.folderID == group.id })
        capture.confirm()
        XCTAssertEqual(app.store.clips.count, 2)
    }

    @MainActor func testPinnedReferenceZoomPanAndExportRemainIndependent() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let clip = try store.add(SnipShelfTests().image(width: 1800, height: 1200), name: "Pin")
        let app = AppController(store: store)
        app.openReference(.clip(clip.id))
        defer { app.closeReference(.clip(clip.id)) }
        try await Task.sleep(for: .milliseconds(150))
        let window = try XCTUnwrap(app.referenceWindows[.clip(clip.id)])
        func scroll(_ view: NSView) -> PreviewImage.ImageScrollView? {
            (view as? PreviewImage.ImageScrollView) ?? view.subviews.lazy.compactMap(scroll).first
        }
        let viewport = try XCTUnwrap(scroll(window.contentView!))
        let picture = try XCTUnwrap(viewport.documentView as? ReferenceImageView)
        XCTAssertEqual(picture.clip?.id, clip.id)
        XCTAssertTrue(picture.app === app)
        let original = try Data(contentsOf: store.url(for: clip)), boardCount = NSPasteboard(name: .drag).changeCount
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        viewport.keyDown(with: key(.keyDown, 18, "1", .command))
        viewport.layoutSubtreeIfNeeded()
        XCTAssertEqual(viewport.magnification, 1)
        viewport.keyDown(with: key(.keyDown, 49, " "))
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let before = viewport.contentView.bounds.origin
        picture.mouseDown(with: mouse(.leftMouseDown, 100))
        picture.mouseDragged(with: mouse(.leftMouseDragged, 125))
        picture.mouseUp(with: mouse(.leftMouseUp, 125))
        viewport.keyUp(with: key(.keyUp, 49, " "))
        XCTAssertFalse(viewport.spaceDown)
        XCTAssertNotEqual(viewport.contentView.bounds.origin, before)
        XCTAssertEqual(NSPasteboard(name: .drag).changeCount, boardCount)
        XCTAssertFalse(app.isDraggingClips)
        XCTAssertEqual(try Data(contentsOf: store.url(for: clip)), original)
        viewport.keyDown(with: key(.keyDown, 29, "0", .command))
        viewport.layoutSubtreeIfNeeded()
        XCTAssertLessThan(viewport.magnification, 1)
        app.toggleReferences(); XCTAssertFalse(window.isVisible)
        app.toggleReferences(); XCTAssertTrue(window.isVisible)
    }
}
