import XCTest
import AppKit
import SwiftUI
@testable import SnipShelf

final class ShelfOrganizationTests: XCTestCase {
    @MainActor func testHandleReordersPersistsAndCancelsWithoutExporting() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image(width: 40, height: 60)
        let folder = try store.createFolder(name: "Group")
        let a = try store.add(image, name: "A"), b = try store.add(image, name: "B")
        let member = try store.add(image, name: "Member", folderID: folder.id)
        let another = try store.add(image, name: "Another", folderID: folder.id)
        store.selection = b.id
        let app = AppController(store: store, preferences: preferences)
        let host = NSHostingView(rootView: ShelfCollection(app: app))
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 300, height: 450), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close(); app.referenceWindows.values.forEach { $0.close() } }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> ShelfCollection.CollectionView? {
            (view as? ShelfCollection.CollectionView) ?? view.subviews.lazy.compactMap(find).first
        }
        let grid = try XCTUnwrap(find(host))
        let coordinator = try XCTUnwrap(grid.dataSource as? ShelfCollection.Coordinator)
        func card(_ index: Int) throws -> ShelfCollection.CardView {
            try XCTUnwrap(grid.item(at: IndexPath(item: index, section: 0))?.view as? ShelfCollection.CardView)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let source = try card(0), destination = try card(2)
        let handle = source.dragHandle
        let start = handle.convert(CGPoint(x: 22, y: 11), to: nil)
        let release = destination.dragHandle.convert(CGPoint(x: 22, y: 11), to: nil)
        let hit = grid.hitTest(handle.convert(CGPoint(x: 22, y: 11), to: grid.superview))
        XCTAssertTrue(hit === handle, "The independent handle must receive pointer events")
        let board = NSPasteboard(name: .drag).changeCount
        let original = coordinator.entries.map(\.id)
        let expected = [b.id, a.id, folder.id]
        let inspect = Timer(timeInterval: 0.06, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTAssertEqual(coordinator.entries.map(\.id), expected, "The grid previews the new position during tracking")
                XCTAssertTrue(store.itemOrder.isEmpty, "Dragging must not write or add undo steps before release")
                NSApp.postEvent(try! mouse(.leftMouseUp, release), atStart: true)
            }
        }
        RunLoop.main.add(inspect, forMode: .common)
        NSApp.postEvent(try mouse(.leftMouseDragged, release), atStart: true)
        handle.mouseDown(with: try mouse(.leftMouseDown, start))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.orderedIDs(original), expected)
        XCTAssertEqual(ShelfStore(root: root).orderedIDs(original), expected)
        XCTAssertEqual(coordinator.entries.map(\.id), expected)
        XCTAssertEqual(source.alphaValue, 1, accuracy: 0.01)
        XCTAssertTrue(app.referenceWindows.isEmpty)
        XCTAssertEqual(NSPasteboard(name: .drag).changeCount, board)
        XCTAssertEqual(store.undoTitle, "Undo Reorder Items")
        XCTAssertNil(store.currentFolderID)
        XCTAssertEqual(store.selectedIDs, [b.id], "Reordering another item must preserve selection")

        let moved = try card(2)
        let again = moved.dragHandle.convert(CGPoint(x: 22, y: 11), to: nil)
        let back = try card(0).dragHandle.convert(CGPoint(x: 22, y: 11), to: nil)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.postEvent(escape, atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, back), atStart: true)
        moved.dragHandle.mouseDown(with: try mouse(.leftMouseDown, again))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(coordinator.entries.map(\.id), expected, "Escape restores the previewed order")
        XCTAssertEqual(store.orderedIDs(original), expected)
        let fresh = try store.add(image, name: "Fresh")
        store.undo()
        XCTAssertEqual(store.orderedIDs([folder.id, fresh.id, b.id, a.id]), [folder.id, fresh.id, b.id, a.id])
        XCTAssertTrue(store.clips.contains(fresh), "Undoing a reorder keeps later imports")
        XCTAssertTrue(store.reorder([member.id, another.id], in: folder.id))
        XCTAssertEqual(store.clips(in: folder.id).map(\.id), [member.id, another.id])
        XCTAssertFalse(store.reorder([a.id, member.id], in: folder.id), "A partial or mixed-folder ordering must be rejected")
        XCTAssertFalse(store.reorder([member.id, member.id], in: folder.id), "Repeated IDs must be rejected")
        let saved = store.itemOrder
        let index = root.appendingPathComponent("index.json")
        let bytes = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertFalse(store.reorder([another.id, member.id], in: folder.id))
        XCTAssertEqual(store.itemOrder, saved, "A failed atomic write must keep the previous arrangement")
        try FileManager.default.removeItem(at: index)
        try bytes.write(to: index)
    }

    @MainActor func testOrganizationUndoPreservesNewImagesAndFailedWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        let first = try store.createFolder(name: "First"), second = try store.createFolder(name: "Second")
        let loose = try store.add(image, name: "Loose")
        let member = try store.add(image, name: "Member", folderID: first.id)
        let bytes = try Data(contentsOf: store.url(for: loose))
        let beforeMove = store.clips
        XCTAssertTrue(store.move([loose.id, member.id], to: second.id))
        XCTAssertEqual(store.undoTitle, "Undo Move Clips")
        let imported = try store.add(image, name: "New import", folderID: second.id)
        let count = store.undoHistory.count
        XCTAssertFalse(store.move([member.id], to: second.id))
        XCTAssertEqual(store.undoHistory.count, count, "A no-op must not hide the last meaningful undo")
        store.undo()
        XCTAssertEqual(store.clips, [imported] + beforeMove)

        try store.renameClip(loose.id, name: "  白色按鈕  ")
        XCTAssertEqual(store.clips.first { $0.id == loose.id }?.name, "白色按鈕")
        XCTAssertEqual(ShelfStore(root: root).clips.first { $0.id == loose.id }?.name, "白色按鈕")
        XCTAssertThrowsError(try store.renameClip(loose.id, name: " \n "))
        XCTAssertEqual(try Data(contentsOf: store.url(for: loose)), bytes)
        store.undo()
        XCTAssertTrue(store.clips.contains(loose))

        store.openFolder(first.id)
        store.dissolveFolder(first.id)
        let afterDissolve = try store.add(image, name: "After dissolve")
        store.undo()
        XCTAssertEqual(store.folders, [first, second], "Undo restores the group's original position")
        XCTAssertEqual(store.currentFolderID, first.id)
        XCTAssertTrue(store.clips.contains(member))
        XCTAssertTrue(store.clips.contains(afterDissolve))

        let grouped = try store.createFolder(name: "Together", including: [loose.id, member.id])
        let late = try store.add(image, name: "Import into new group", folderID: grouped.id)
        store.openFolder(grouped.id)
        store.undo()
        XCTAssertEqual(store.folders, [first, second])
        XCTAssertTrue(store.clips.contains(loose) && store.clips.contains(member))
        XCTAssertNil(store.clips.first { $0.id == late.id }?.folderID, "Undoing a new group keeps later imports on the Shelf")

        store.delete([loose.id])
        store.collectUnusedFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: loose).path))
        let index = root.appendingPathComponent("index.json")
        let saved = try Data(contentsOf: index), savedClips = store.clips
        let undoCount = store.undoHistory.count
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.renameClip(member.id, name: "Cannot write"))
        store.undo()
        XCTAssertEqual(store.clips, savedClips)
        XCTAssertEqual(store.undoHistory.count, undoCount)
        XCTAssertNotNil(store.message)
        try FileManager.default.removeItem(at: index)
        try saved.write(to: index)
        store.undo()
        XCTAssertTrue(store.clips.contains(loose))
        XCTAssertTrue(store.clips.contains(imported))
        XCTAssertEqual(ShelfStore(root: root).clips, store.clips)
        XCTAssertEqual(try Data(contentsOf: store.url(for: loose)), bytes)
        store.openFolder(nil)
        let empty = try store.createFolder(name: "Temporary")
        store.selection = empty.id
        store.undo()
        XCTAssertNil(store.selectedFolderID, "Undo cannot leave a removed group selected")
    }

    @MainActor func testBrowsingRestoresSelectionAndScrollAcrossEmptyGroupsAndTucking() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let full = try store.createFolder(name: "Full"), empty = try store.createFolder(name: "Empty")
        let image = try SnipShelfTests().image(width: 30, height: 30)
        let loose = try (0..<32).map { try store.add(image, name: "Loose \($0)") }
        let members = try (0..<36).map { try store.add(image, name: "Member \($0)", folderID: full.id) }
        let app = AppController(store: store, preferences: preferences)
        app.shelf.install(content: ShelfView(app: app), key: app.handleKey)
        defer { app.shelf.panel.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(100))
            app.shelf.panel.contentView?.layoutSubtreeIfNeeded()
        }
        func collection(in view: NSView) -> ShelfCollection.CollectionView? {
            (view as? ShelfCollection.CollectionView) ?? view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        func grid() throws -> ShelfCollection.CollectionView {
            try XCTUnwrap(collection(in: try XCTUnwrap(app.shelf.panel.contentView)))
        }
        func scroll(to y: CGFloat) throws -> CGFloat {
            let scroll = try XCTUnwrap(try grid().enclosingScrollView)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            return scroll.contentView.bounds.minY
        }
        try await settle()
        store.selectedIDs = [loose[4].id, loose[5].id]
        try await settle()
        let rootY = try scroll(to: 520)
        XCTAssertGreaterThan(rootY, 500)
        app.openFolder(full.id)
        try await settle()
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(try grid().visibleRect.minY, 0, accuracy: 1)
        store.selectedIDs = [members[6].id, members[7].id]
        try await settle()
        let groupY = try scroll(to: 810)
        app.openFolder(empty.id)
        try await settle()
        app.openFolder(nil)
        try await settle()
        XCTAssertEqual(store.selectedIDs, [loose[4].id, loose[5].id])
        XCTAssertEqual(try grid().selectionIndexPaths.count, 2)
        XCTAssertEqual(try grid().visibleRect.minY, rootY, accuracy: 1)
        app.openFolder(full.id)
        try await settle()
        XCTAssertEqual(store.selectedIDs, [members[6].id, members[7].id])
        XCTAssertEqual(try grid().visibleRect.minY, groupY, accuracy: 1)
        app.shelf.collapse()
        try await Task.sleep(for: .milliseconds(260))
        app.shelf.expand()
        try await Task.sleep(for: .milliseconds(260))
        try await settle()
        XCTAssertEqual(try grid().visibleRect.minY, groupY, accuracy: 1)
        app.openFolder(nil)
        store.move([members[6].id], to: nil)
        store.delete([members[7].id])
        app.openFolder(full.id)
        try await settle()
        XCTAssertTrue(store.selectedIDs.isEmpty, "Restoration cannot select deleted or moved images")
        XCTAssertTrue(try grid().selectionIndexPaths.isEmpty)
        store.selection = members[0].id
        try await settle()
        let selectedY = try grid().visibleRect.minY
        XCTAssertGreaterThan(selectedY, groupY, "Selecting a lower item scrolls it into view")
        app.openFolder(nil)
        try await settle()
        app.openFolder(full.id)
        try await settle()
        XCTAssertEqual(try grid().visibleRect.minY, selectedY, accuracy: 1)
        store.openFolder(nil); store.selection = empty.id
        store.openFolder(full.id); store.openFolder(nil)
        XCTAssertEqual(store.selectedFolderID, empty.id, "The Shelf remembers a selected group as well as images")
    }

    @MainActor func testImageRenameAndReferenceBackgroundsUpdateNativeWindows() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image(width: 40, height: 40)
        let a = try store.add(image, name: "A"), b = try store.add(image, name: "B")
        let app = AppController(store: store, preferences: preferences)
        defer {
            app.previewClip = nil
            for panel in app.referenceWindows.values { panel.close() }
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        app.backdrop = 1
        app.openReference(.clip(a.id)); app.openReference(.clip(b.id))
        let aPanel = try XCTUnwrap(app.referenceWindows[.clip(a.id)])
        let bPanel = try XCTUnwrap(app.referenceWindows[.clip(b.id)])
        preferences.set(2, forKey: ReferenceTarget.clip(a.id).backgroundKey)
        app.previewClip = a
        let preview = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == a.name && $0 !== aPanel })
        try store.renameClip(a.id, name: "White icon")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(app.previewClip?.name, "White icon")
        XCTAssertEqual(preview.title, "White icon")
        XCTAssertEqual(aPanel.title, "White icon")
        func background(in panel: NSWindow) throws -> CGFloat {
            let view = try XCTUnwrap(panel.contentView)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)).redComponent
        }
        XCTAssertLessThan(try background(in: aPanel), 0.3)
        XCTAssertGreaterThan(try background(in: bPanel), 0.8)
        app.backdrop = 0
        app.closeReference(.clip(a.id)); app.openReference(.clip(a.id))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThan(try background(in: XCTUnwrap(app.referenceWindows[.clip(a.id)])), 0.3)
        XCTAssertGreaterThan(try background(in: bPanel), 0.8)
        XCTAssertTrue(app.clipMenu(a).items.contains { $0.title == "Rename Image…" })
        let undo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: preview.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(app.handlePreviewKey(undo))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(preview.title, "A")
        XCTAssertEqual(app.referenceWindows[.clip(a.id)]?.title, "A")
    }
}
