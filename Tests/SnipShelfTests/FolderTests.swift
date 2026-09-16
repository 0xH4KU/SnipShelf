import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import SnipShelf

final class FolderTests: XCTestCase {
    @MainActor func testGroupedGridPreviewCountsNavigationAndNativeDrops() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image(width: 80, height: 160)
        var groups: [(ShelfFolder, [Clip])] = []
        for count in [0, 1, 2, 3, 5, 8] {
            var clips: [Clip] = []
            for index in 0..<count { clips.append(try store.add(image, name: "Reference \(index)")) }
            groups.append((try store.createFolder(name: "Group \(count)", including: Set(clips.map(\.id))), clips))
        }
        let loose = try store.add(image, name: "Loose reference")
        store.latestID = nil; store.selection = nil
        let app = AppController(store: store, preferences: preferences)
        let host = NSHostingView(rootView: ShelfCollection(app: app))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 750), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { app.previewClip = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func findCollection(_ view: NSView) -> ShelfCollection.CollectionView? {
            (view as? ShelfCollection.CollectionView) ?? view.subviews.lazy.compactMap(findCollection).first
        }
        let collection = try XCTUnwrap(findCollection(host))
        func card(_ index: Int) throws -> ShelfCollection.CardView {
            try XCTUnwrap(collection.item(at: IndexPath(item: index, section: 0))?.view as? ShelfCollection.CardView)
        }
        func point(_ index: Int) throws -> CGPoint { try card(index).convert(CGPoint(x: 35, y: 35), to: nil) }
        func key(_ code: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 7, "Groups and loose references share one grid")
        for (index, pair) in groups.enumerated() {
            let tile = try card(index), count = pair.1.count
            tile.layout()
            XCTAssertEqual(tile.caption.stringValue, pair.0.name)
            XCTAssertEqual(tile.more.stringValue, count > 3 ? "+\(count - 3)" : "")
            XCTAssertEqual(tile.more.isHidden, count <= 3)
            XCTAssertEqual(tile.related.filter { !$0.isHidden }.count, min(2, max(0, count - 1)))
            XCTAssertFalse(tile.recent, "A group must not gain a saved-clip border when latestID is nil")
            if let first = pair.1.first { XCTAssertTrue(tile.picture.image === store.thumbnail(for: first)) }
            let boxes = [tile.picture.frame] + tile.relatedFrames.filter { !$0.isHidden }.map(\.frame)
                + (tile.more.isHidden ? [] : [tile.more.frame])
            for (i, box) in boxes.enumerated() {
                XCTAssertTrue(tile.bounds.contains(box), "References must fit the minimum shelf width")
                XCTAssertTrue(boxes.dropFirst(i + 1).allSatisfy { !box.intersects($0) }, "References and +N must not overlap")
            }
        }
        let hovered = try card(3)
        hovered.updateTrackingAreas()
        XCTAssertTrue(hovered.trackingAreas.contains { $0.options.contains(.activeAlways) }, "The floating shelf must hover even while another app is active")
        let previews: [NSView] = [hovered.picture] + hovered.relatedFrames
        let resting = previews.map(\.frame), countFrame = hovered.more.frame
        func hoverEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: try point(3), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        hovered.mouseEntered(with: try hoverEvent(.mouseEntered))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(hovered.picture.frame, resting[0].offsetBy(dx: -1, dy: -3))
        XCTAssertEqual(hovered.relatedFrames[0].frame, resting[1].offsetBy(dx: 2, dy: -2))
        XCTAssertEqual(hovered.relatedFrames[1].frame, resting[2].offsetBy(dx: 2, dy: 2))
        XCTAssertEqual(hovered.more.frame, countFrame)
        XCTAssertTrue(previews.allSatisfy { hovered.bounds.contains($0.frame) })
        XCTAssertNil(store.selection, "Hover must not select or open the group")
        hovered.mouseExited(with: try hoverEvent(.mouseExited))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(previews.map(\.frame), resting)
        let coordinator = try XCTUnwrap(collection.dataSource as? ShelfCollection.Coordinator)
        XCTAssertNil(coordinator.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)))
        let writer = try XCTUnwrap(coordinator.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: 6, section: 0)) as? NSPasteboardItem)
        XCTAssertEqual(writer.string(forType: .fileURL), store.url(for: loose).absoluteString)
        let open = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: try point(5), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        collection.mouseDown(with: open)
        XCTAssertEqual(store.currentFolderID, groups[5].0.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 8)
        store.selection = store.visibleClips[0].id
        XCTAssertTrue(app.handleKey(try key(49, " ")))
        XCTAssertEqual(app.previewClips.count, 8)
        app.openFolder(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(app.handleKey(try key(124)))
        XCTAssertEqual(store.selectedFolderID, groups[0].0.id)
        XCTAssertTrue(app.handleKey(try key(36, "\r")))
        XCTAssertEqual(store.currentFolderID, groups[0].0.id)
        app.openFolder(nil)
        try await Task.sleep(for: .milliseconds(100))

        let board = NSPasteboard(name: .init("org.snipshelf.tests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([writer]))
        let drag = GroupDraggingInfo(window: window, board: board, location: try point(3))
        let originalImage = try card(3).picture.image
        let originalCount = store.clips.count
        app.isDraggingClips = true; app.draggedClipIDs = [loose.id]
        XCTAssertEqual(collection.draggingEntered(drag), .move)
        XCTAssertTrue(try card(3).dropTargeted)
        XCTAssertTrue(collection.performDragOperation(drag))
        XCTAssertFalse(try card(3).dropTargeted)
        XCTAssertEqual(store.clips.count, originalCount, "Moving must not duplicate images")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try card(3).more.stringValue, "+1")
        XCTAssertTrue(try card(3).picture.image === originalImage, "Adding a newer reference keeps the main image")
        drag.draggingLocation = collection.convert(CGPoint(x: 2, y: 2), to: nil)
        XCTAssertEqual(collection.draggingUpdated(drag), [])
        XCTAssertFalse(collection.performDragOperation(drag), "Internal drops outside a group must not import duplicates")
        app.isDraggingClips = false; app.draggedClipIDs = []
        board.clearContents()
        let png = NSPasteboardItem(), jpeg = NSPasteboardItem()
        png.setData(try ImageCore.png(image), forType: .png)
        jpeg.setData(try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])), forType: .init(UTType.jpeg.identifier))
        XCTAssertTrue(board.writeObjects([png, jpeg]))
        drag.draggingLocation = try point(5)
        XCTAssertEqual(collection.draggingEntered(drag), .copy)
        XCTAssertTrue(collection.performDragOperation(drag))
        app.openFolder(groups[0].0.id)
        for _ in 0..<200 {
            if !app.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(app.busy)
        XCTAssertNil(store.message)
        XCTAssertEqual(store.clips.count, originalCount + 2)
        XCTAssertEqual(store.clips.prefix(2).map(\.folderID), [groups[5].0.id, groups[5].0.id])
        XCTAssertTrue(ShelfStore(root: root).clips.contains { $0.id == loose.id && $0.folderID == groups[3].0.id })
        app.openFolder(nil)
        store.selection = groups[5].0.id
        XCTAssertTrue(app.handleKey(try key(0, "a", modifiers: [.command])))
        XCTAssertNil(store.selectedFolderID)
        XCTAssertTrue(store.selectedIDs.isEmpty, "Select All does not select hidden group members")
        let dissolve = try XCTUnwrap(app.folderMenu(groups[5].0).items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(dissolve.action), to: dissolve.target, from: dissolve))
        XCTAssertEqual(store.visibleClips.count, 10)
        XCTAssertEqual(store.clips.count, originalCount + 2)
        XCTAssertNotNil(NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil))
    }

    @MainActor func testLegacyShelfGroupsMovesAndPersistsWithoutChangingImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        let a = try original.add(image, name: "A"), b = try original.add(image, name: "B")
        let index = root.appendingPathComponent("index.json")
        let legacy = try JSONEncoder().encode(ShelfStore.Index(version: 1, clips: original.clips))
        try legacy.write(to: index)
        let store = ShelfStore(root: root)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), legacy)
        let png = try Data(contentsOf: store.url(for: a))
        store.selectedIDs = [a.id, b.id]
        let folder = try store.createFolder(name: "  按鈕參考  ", including: store.selectedIDs)
        XCTAssertEqual(folder.name, "按鈕參考")
        XCTAssertTrue(store.visibleClips.isEmpty)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        store.openFolder(folder.id)
        XCTAssertEqual(store.visibleClips.map(\.id), [b.id, a.id])
        XCTAssertTrue(store.move([b.id], to: nil))
        XCTAssertEqual(store.visibleClips.map(\.id), [a.id])
        try store.renameFolder(folder.id, name: "Buttons")
        XCTAssertThrowsError(try store.createFolder(name: " buttons "))
        XCTAssertThrowsError(try store.renameFolder(folder.id, name: " \n "))
        let reload = ShelfStore(root: root)
        XCTAssertEqual(reload.folders, [ShelfFolder(id: folder.id, name: "Buttons")])
        XCTAssertEqual(reload.visibleClips.map(\.id), [b.id])
        reload.openFolder(folder.id)
        XCTAssertEqual(reload.visibleClips.map(\.id), [a.id])
        XCTAssertEqual(try Data(contentsOf: reload.url(for: a)), png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 5)
        XCTAssertEqual(try JSONDecoder().decode(ShelfStore.Index.self, from: Data(contentsOf: index)).version, 2)
    }

    @MainActor func testFolderWriteFailuresAndInvalidIndexesPreserveData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let clip = try store.add(SnipShelfTests().image(), name: "Keep")
        let folder = try store.createFolder(name: "Keep folder")
        store.openFolder(folder.id)
        let index = root.appendingPathComponent("index.json")
        let saved = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.createFolder(name: "No partial group", including: [clip.id]))
        XCTAssertThrowsError(try store.renameFolder(folder.id, name: "No partial rename"))
        XCTAssertFalse(store.move([clip.id], to: folder.id))
        store.dissolveFolder(folder.id)
        XCTAssertEqual(store.folders, [folder])
        XCTAssertEqual(store.clips, [clip])
        XCTAssertEqual(store.currentFolderID, folder.id)
        XCTAssertNotNil(store.message)
        try FileManager.default.removeItem(at: index)
        try saved.write(to: index)
        XCTAssertFalse(store.move([clip.id], to: UUID()))
        XCTAssertEqual(try Data(contentsOf: index), saved)
        var orphan = clip
        orphan.folderID = UUID()
        for invalid in [ShelfStore.Index(version: 2, clips: [orphan], folders: [folder]),
                        ShelfStore.Index(version: 2, clips: [clip], folders: [folder, folder]),
                        ShelfStore.Index(version: 2, clips: [clip]),
                        ShelfStore.Index(version: 3, clips: [clip], folders: [folder])] {
            let data = try JSONEncoder().encode(invalid)
            try data.write(to: index)
            let broken = ShelfStore(root: root)
            XCTAssertTrue(broken.isReadOnly)
            XCTAssertThrowsError(try broken.createFolder(name: "Do not overwrite"))
            XCTAssertEqual(try Data(contentsOf: index), data)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: clip).path))
        }
    }

    @MainActor func testDissolvingFolderAndUndoKeepClipsAndPendingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(root: root)
        let folder = try store.createFolder(name: "Shapes")
        store.openFolder(folder.id)
        let image = try SnipShelfTests().image()
        let a = try store.add(image, name: "A", folderID: folder.id)
        let b = try store.add(image, name: "B", folderID: folder.id)
        store.delete([a.id])
        store.openFolder(nil)
        store.undo()
        XCTAssertEqual(store.currentFolderID, folder.id)
        XCTAssertEqual(store.selectedIDs, [a.id])
        store.delete([a.id])
        let index = root.appendingPathComponent("index.json")
        let saved = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        store.receive(image, name: "Retry in folder", folderID: folder.id)
        XCTAssertNotNil(store.pendingImage)
        try FileManager.default.removeItem(at: index)
        try saved.write(to: index)
        store.openFolder(nil)
        store.retryPending()
        XCTAssertNil(store.pendingImage)
        XCTAssertEqual(store.clips.first?.folderID, folder.id)
        store.openFolder(folder.id)
        store.dissolveFolder(folder.id)
        store.undo()
        XCTAssertNil(store.currentFolderID)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(store.clips.allSatisfy { $0.folderID == nil })
        XCTAssertTrue(store.clips.contains { $0.id == a.id })
        XCTAssertTrue(store.clips.contains { $0.id == b.id })
        let late = try store.add(image, name: "Finished after dissolution", folderID: folder.id)
        XCTAssertNil(late.folderID)
        XCTAssertFalse(ShelfStore(root: root).isReadOnly)
        for clip in store.clips { XCTAssertNoThrow(try ImageCore.load(store.url(for: clip))) }
    }

    @MainActor func testFolderCollectionKeyboardPreviewAndMoveMenuUseVisibleClips() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        let a = try store.add(image, name: "A"), b = try store.add(image, name: "B")
        let outside = try store.add(image, name: "Outside")
        let folder = try store.createFolder(name: "Inside", including: [a.id, b.id])
        let app = AppController(store: store, preferences: preferences)
        app.openFolder(folder.id)
        let host = NSHostingView(rootView: ShelfCollection(app: app))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 340), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { app.previewClip = nil; window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        func findCollection(_ view: NSView) -> ShelfCollection.CollectionView? {
            (view as? ShelfCollection.CollectionView) ?? view.subviews.lazy.compactMap(findCollection).first
        }
        let collection = try XCTUnwrap(findCollection(host))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 2)
        let item = try XCTUnwrap(collection.item(at: IndexPath(item: 0, section: 0)))
        let point = item.view.convert(CGPoint(x: 30, y: 30), to: nil)
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        collection.mouseDown(with: doubleClick)
        XCTAssertEqual(app.previewClip?.id, b.id)
        XCTAssertEqual(app.previewClips.map(\.id), [b.id, a.id])
        app.movePreview(1); app.movePreview(1)
        XCTAssertEqual(app.previewClip?.id, a.id)
        app.previewClip = nil
        let selectAll = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(app.handleKey(selectAll))
        XCTAssertEqual(store.selectedIDs, [a.id, b.id])
        store.selection = b.id
        let menu = app.clipMenu(try XCTUnwrap(store.selectedClip))
        let move = try XCTUnwrap(menu.items.first { $0.title == "Move to" }?.submenu?.items.first)
        XCTAssertEqual(move.title, "Shelf")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(move.action), to: move.target, from: move))
        XCTAssertEqual(store.visibleClips.map(\.id), [a.id])
        app.openFolder(nil)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.visibleClips.map(\.id), [outside.id, b.id])
        XCTAssertTrue(app.handleKey(selectAll))
        store.delete(store.selectedIDs)
        XCTAssertEqual(store.clips.map(\.id), [a.id], "Select All and Delete must not affect clips inside folders")
    }

    @MainActor func testFolderDropsMoveActualDraggedClipsAndKeepAsyncImportDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image()
        let a = try store.add(image, name: "A"), b = try store.add(image, name: "B")
        let folder = try store.createFolder(name: "Drop here")
        let app = AppController(store: store, preferences: preferences)
        store.selectedIDs = [a.id, b.id]
        app.isDraggingClips = true; app.draggedClipIDs = [a.id]
        XCTAssertTrue(app.dropIntoFolder([], folderID: folder.id))
        XCTAssertEqual(store.visibleClips.map(\.id), [b.id])
        XCTAssertEqual(store.clips.count, 2, "An internal move must never import a duplicate PNG")
        XCTAssertFalse(app.acceptDrop([]))
        XCTAssertTrue(app.dropIntoFolder([], folderID: nil))
        app.isDraggingClips = false; app.draggedClipIDs = []
        let provider = NSItemProvider(item: try ImageCore.png(image) as NSData, typeIdentifier: UTType.png.identifier)
        XCTAssertTrue(app.dropIntoFolder([provider], folderID: folder.id))
        app.openFolder(nil)
        for _ in 0..<200 {
            if !app.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(app.busy)
        XCTAssertEqual(store.clips.count, 3)
        XCTAssertEqual(store.clips.first?.folderID, folder.id)
        XCTAssertEqual(store.visibleClips.count, 2)
        XCTAssertNil(store.message)
    }
}

@MainActor private final class GroupDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, board: NSPasteboard, location: NSPoint) {
        draggingDestinationWindow = window; draggingPasteboard = board; draggingLocation = location
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
