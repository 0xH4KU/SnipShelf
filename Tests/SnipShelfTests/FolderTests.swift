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
        defer { app.previewClip = nil; for panel in app.referenceWindows.values { panel.close() }; window.close() }
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
        let sourceCard = try card(5)
        let start = sourceCard.dragHandle.convert(CGPoint(x: 22, y: 11), to: nil)
        @MainActor func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let open = try mouse(.leftMouseDown, start)
        let release = window.convertPoint(fromScreen: CGPoint(x: NSScreen.main!.visibleFrame.midX, y: NSScreen.main!.visibleFrame.midY))
        let dragBoard = NSPasteboard(name: .drag), boardChanges = dragBoard.changeCount
        let sourceFrame = window.convertToScreen(sourceCard.convert(sourceCard.bounds, to: nil))
        let liftedFrame = sourceFrame.offsetBy(dx: release.x - start.x, dy: release.y - start.y)
        // Inspect the actual tracking loop before allowing the mouse-up event through.
        var inspectedLift = false
        let inspection = Timer(timeInterval: 0.04, repeats: false) { _ in
            MainActor.assumeIsolated {
                let lift = NSApp.windows.compactMap { $0 as? ReferenceLiftWindow }.first { $0.isVisible }
                XCTAssertEqual(lift?.frame.minX ?? .nan, liftedFrame.minX, accuracy: 1, "The lifted card must retain the original grab offset")
                XCTAssertEqual(lift?.frame.minY ?? .nan, liftedFrame.minY, accuracy: 1)
                XCTAssertEqual(lift?.frame.size, liftedFrame.size)
                XCTAssertTrue(app.referenceWindows.isEmpty, "Full reference windows are created on release, not during tracking")
                XCTAssertFalse(lift?.canBecomeKey ?? true, "The drag preview must not steal focus")
                XCTAssertTrue(lift?.ignoresMouseEvents ?? false)
                inspectedLift = true
                NSApp.postEvent(try! mouse(.leftMouseUp, release), atStart: true)
            }
        }
        RunLoop.main.add(inspection, forMode: .common)
        NSApp.postEvent(try mouse(.leftMouseDragged, release), atStart: true)
        sourceCard.dragHandle.mouseDown(with: open)
        XCTAssertTrue(inspectedLift)
        let reference = try XCTUnwrap(app.referenceWindows[.group(groups[5].0.id)])
        var placed = NSWindow.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 340, height: 410), styleMask: reference.styleMask)
        placed.origin = CGPoint(x: liftedFrame.midX - placed.width / 2, y: liftedFrame.midY - placed.height / 2)
        placed = ShelfWindow.constrainedFrame(placed, to: NSScreen.main!.visibleFrame)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(reference.frame.width, liftedFrame.width, accuracy: 1, "The real window must begin at the card's size")
            XCTAssertEqual(reference.frame.height, liftedFrame.height, accuracy: 1)
            XCTAssertEqual(reference.frame.minX, liftedFrame.minX, accuracy: 1)
            XCTAssertEqual(reference.frame.maxY, liftedFrame.maxY, accuracy: 1)
        }
        XCTAssertNil(store.currentFolderID, "Dragging a group must not also browse into it")
        XCTAssertNil(store.selection)
        XCTAssertFalse(app.isDraggingClips)
        XCTAssertTrue(app.draggedClipIDs.isEmpty)
        XCTAssertEqual(dragBoard.changeCount, boardChanges, "Pulling out a window must not initiate a file drop")
        try await Task.sleep(for: .milliseconds(70))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertGreaterThan(reference.alphaValue, 0, "Opening must visibly progress while remaining interactive")
            XCTAssertLessThan(reference.alphaValue, 1, "Opening should crossfade instead of popping into view")
            XCTAssertGreaterThan(reference.frame.width, liftedFrame.width, "The card must visibly grow into the reference window")
            XCTAssertLessThan(reference.frame.width, placed.width)
            XCTAssertEqual(reference.frame.midX, liftedFrame.midX, accuracy: 1, "Expansion keeps the dropped card's center fixed")
            XCTAssertEqual(reference.frame.midY, liftedFrame.midY, accuracy: 1)
            let lift = try XCTUnwrap(NSApp.windows.compactMap { $0 as? ReferenceLiftWindow }.first { $0.isVisible })
            XCTAssertEqual(lift.frame.minX, reference.frame.minX, accuracy: 1)
            XCTAssertEqual(lift.frame.minY, reference.frame.minY, accuracy: 1)
            XCTAssertEqual(lift.frame.width, reference.frame.width, accuracy: 1, "The two surfaces must keep one continuous outline")
            XCTAssertEqual(lift.frame.height, reference.frame.height, accuracy: 1)
            let nextRelease = CGPoint(x: release.x + 30, y: release.y - 20)
            NSApp.postEvent(try mouse(.leftMouseUp, nextRelease), atStart: true)
            NSApp.postEvent(try mouse(.leftMouseDragged, nextRelease), atStart: true)
            sourceCard.dragHandle.mouseDown(with: open)
            XCTAssertEqual(reference.referenceTransition?.destinationFrame?.size, placed.size, "Regrabbing mid-expansion must preserve the intended full window size")
            placed = try XCTUnwrap(reference.referenceTransition?.destinationFrame)
        }
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(reference.frame.minX, placed.minX, accuracy: 1)
        XCTAssertEqual(reference.frame.maxY, placed.maxY, accuracy: 1)
        XCTAssertEqual(reference.frame.size, placed.size)
        XCTAssertEqual(reference.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(sourceCard.alphaValue, 1, accuracy: 0.01)
        XCTAssertFalse(NSApp.windows.contains { $0 is ReferenceLiftWindow && $0.isVisible }, "The transition must clean up its preview")
        app.closeReference(.group(groups[5].0.id))
        NSApp.postEvent(try mouse(.leftMouseUp, start), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, release), atStart: true)
        sourceCard.dragHandle.mouseDown(with: open)
        XCTAssertTrue(app.referenceWindows.isEmpty, "Releasing back on the source returns the card without opening a reference")
        XCTAssertNil(store.currentFolderID, "Returning a drag must not also trigger a click")
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(sourceCard.alphaValue, 1, accuracy: 0.01)
        let browse = try point(5)
        NSApp.postEvent(try mouse(.leftMouseUp, release), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, release), atStart: true)
        collection.mouseDown(with: try mouse(.leftMouseDown, browse))
        XCTAssertTrue(app.referenceWindows.isEmpty, "Dragging a group thumbnail must not take over the handle's gesture")
        XCTAssertNil(store.currentFolderID)
        NSApp.postEvent(try mouse(.leftMouseUp, browse), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, CGPoint(x: browse.x + 1, y: browse.y + 1)), atStart: true)
        collection.mouseDown(with: try mouse(.leftMouseDown, browse))
        XCTAssertEqual(store.currentFolderID, groups[5].0.id)
        XCTAssertTrue(app.referenceWindows.isEmpty, "A click with minor pointer jitter must only browse the group")
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
        XCTAssertEqual(try JSONDecoder().decode(ShelfStore.Index.self, from: Data(contentsOf: index)).version, 3)
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
        let late = try store.add(image, name: "Finished after dissolution", folderID: folder.id)
        XCTAssertNil(late.folderID)
        store.undo()
        XCTAssertEqual(store.currentFolderID, folder.id)
        XCTAssertEqual(store.folders, [folder])
        XCTAssertFalse(store.clips.contains { $0.id == a.id }, "The first undo restores dissolution, not the earlier deletion")
        store.undo()
        XCTAssertTrue(store.clips.contains { $0.id == a.id })
        XCTAssertTrue(store.clips.contains { $0.id == b.id })
        XCTAssertTrue(store.clips.contains(late))
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
        XCTAssertEqual(store.selectedIDs, [outside.id])
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

extension FolderTests {
    @MainActor func testCloseAllReferencesKeepsClipsAndWindowPositions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image(width: 240, height: 160)
        let a = try store.add(image, name: "First"), b = try store.add(image, name: "Second")
        let group = try store.createFolder(name: "References", including: [a.id])
        let originals = store.clips
        let app = AppController(store: store, preferences: preferences)
        app.shelf.install(content: EmptyView(), key: app.handleKey)
        defer {
            app.closeAllReferences(); app.previewClip = nil; app.shelf.panel.close()
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let action = NSMenuItem(title: "Close All Reference Windows", action: #selector(AppController.closeAllReferences), keyEquivalent: "w")
        XCTAssertFalse(app.validateMenuItem(action))
        func closeButton(_ panel: ShelfPanel) -> ReferenceCloseAllButton? {
            panel.titlebarAccessoryViewControllers.compactMap { ($0.view as? ReferenceTitlebarControls)?.button }.first
        }
        app.openReference(.group(group.id))
        let groupPanel = try XCTUnwrap(app.referenceWindows[.group(group.id)])
        XCTAssertNil(closeButton(groupPanel), "One reference needs only the native close button")
        app.openReference(.clip(a.id))
        XCTAssertEqual(closeButton(groupPanel)?.title, "Close All · 2")
        app.closeReference(.clip(a.id))
        XCTAssertNil(closeButton(groupPanel), "The titlebar must reclaim its space when only one reference remains")
        app.openReference(.group(group.id)); app.openReference(.clip(a.id))
        let card = ShelfCollection.CardView(frame: CGRect(x: 20, y: 40, width: 148, height: 173))
        card.picture.image = store.thumbnail(for: b)
        card.pinButton.app = app; card.pinButton.referenceTarget = .clip(b.id)
        app.shelf.panel.contentView!.addSubview(card)
        // performClick can run the opening timer during its simulated button press.
        XCTAssertTrue(card.pinButton.sendAction(card.pinButton.action, to: card.pinButton.target))
        let windows = app.referenceWindows
        let frames = windows.mapValues { $0.referenceTransition?.destinationFrame ?? $0.frame }
        XCTAssertTrue(windows.values.allSatisfy { closeButton($0)?.title == "Close All · 3" })
        XCTAssertNotNil(windows[.clip(b.id)]?.referenceTransition)
        app.previewClip = a
        app.toggleReferences()
        XCTAssertTrue(app.referencesHidden)
        XCTAssertTrue(app.validateMenuItem(action))
        XCTAssertTrue(NSApp.sendAction(#selector(AppController.closeAllReferences), to: app, from: action))
        XCTAssertTrue(app.referenceWindows.isEmpty, "Close hidden references as well as visible ones")
        XCTAssertTrue(app.referencePalettes.isEmpty)
        XCTAssertFalse(app.referencesHidden)
        XCTAssertFalse(app.validateMenuItem(action))
        XCTAssertTrue(windows.values.allSatisfy { !$0.isVisible })
        for (target, frame) in frames {
            XCTAssertEqual(NSRectFromString(try XCTUnwrap(preferences.string(forKey: target.frameKey))), frame)
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(NSApp.windows.contains { $0 is ReferenceLiftWindow && $0.isVisible }, "Closing during expansion must also dismiss its preview")
        XCTAssertTrue(app.referenceWindows.isEmpty, "Opening animations must not reopen closed windows")
        XCTAssertEqual(card.alphaValue, 1)
        XCTAssertEqual(store.clips, originals)
        XCTAssertTrue(originals.allSatisfy { FileManager.default.fileExists(atPath: store.url(for: $0).path) })
        XCTAssertEqual(app.previewClip?.id, a.id)
        XCTAssertTrue(app.shelf.panel.isVisible)

        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        app.shelf.panel.contentView!.addSubview(editor)
        for source in 0..<4 {
            app.openReference(.group(group.id)); app.openReference(.clip(a.id))
            let pin = try XCTUnwrap(app.referenceWindows[.clip(a.id)])
            XCTAssertEqual(pin.frame, frames[.clip(a.id)])
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: pin.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
            switch source {
            case 0:
                XCTAssertTrue(app.shelf.panel.makeFirstResponder(editor))
                XCTAssertTrue(app.shelf.panel.performKeyEquivalent(with: event), "Close all must work while editing Shelf search text")
            case 1: XCTAssertTrue(pin.performKeyEquivalent(with: event))
            case 2: XCTAssertTrue(app.handlePreviewKey(event))
            default:
                app.shelf.collapse()
                try await Task.sleep(for: .milliseconds(250))
                let button = try XCTUnwrap(closeButton(pin))
                XCTAssertEqual(button.title, "Close All · 2")
                XCTAssertTrue(button.acceptsFirstMouse(for: nil), "A floating window's button must work on the first click")
                pin.setContentSize(CGSize(width: 220, height: 300))
                try await Task.sleep(for: .milliseconds(60))
                pin.layoutIfNeeded()
                pin.contentView?.superview?.layoutSubtreeIfNeeded()
                let buttonFrame = button.convert(button.bounds, to: nil)
                let close = try XCTUnwrap(pin.standardWindowButton(.closeButton))
                XCTAssertGreaterThanOrEqual(buttonFrame.minY, pin.contentLayoutRect.maxY, "The action belongs in the titlebar")
                XCTAssertLessThanOrEqual(buttonFrame.maxX, pin.frame.width)
                XCTAssertGreaterThan(buttonFrame.minX, close.convert(close.bounds, to: nil).maxX, "Both close actions must fit in a narrow window")
                let controls = try XCTUnwrap(button.superview as? ReferenceTitlebarControls)
                XCTAssertLessThanOrEqual(controls.title.frame.maxX, button.frame.minX, "Long names must truncate before the action")
                XCTAssertTrue(app.shelf.collapsed)
                button.performClick(nil)
            }
            XCTAssertTrue(app.referenceWindows.isEmpty)
            XCTAssertEqual(app.previewClip?.id, a.id)
            XCTAssertTrue(app.shelf.panel.isVisible)
        }
        app.closeAllReferences() // Repeating the action with no windows is harmless.
    }

    @MainActor func testReferenceCascadeStaysBesideShelfAtScreenEdges() {
        let visible = CGRect(x: -1400, y: -60, width: 1400, height: 900)
        let minimum = CGSize(width: 300, height: 240)
        let size = CGSize(width: 340, height: 442)
        for shelf in [
            CGRect(x: -1380, y: 240, width: 340, height: 440),
            CGRect(x: -360, y: 240, width: 340, height: 440),
            CGRect(x: -1360, y: 500, width: 1320, height: 300),
            CGRect(x: -1360, y: -20, width: 1320, height: 300)
        ] {
            var opened: [CGRect] = []
            for _ in 0..<8 {
                let frame = AppController.initialReferenceFrame(size: size, minimumSize: minimum, beside: shelf, in: visible, occupied: opened)
                XCTAssertTrue(visible.contains(frame), "Cascades must stay on their display, including negative screen coordinates")
                XCTAssertFalse(frame.intersects(shelf.insetBy(dx: -11, dy: -11)), "Keep a gap even when cascading toward a screen edge")
                XCTAssertFalse(opened.contains(frame), "Available cascade positions must not be skipped or reused")
                opened.append(frame)
            }
            let vacant = opened.remove(at: 2)
            XCTAssertEqual(AppController.initialReferenceFrame(size: size, minimumSize: minimum, beside: shelf, in: visible, occupied: opened), vacant)
        }
        let smallScreen = CGRect(x: 0, y: 0, width: 760, height: 800)
        let shelf = CGRect(x: 210, y: 300, width: 340, height: 200)
        let compact = AppController.initialReferenceFrame(size: size, minimumSize: minimum, beside: shelf, in: smallScreen, occupied: [])
        XCTAssertTrue(smallScreen.contains(compact))
        XCTAssertFalse(compact.intersects(shelf))
        XCTAssertGreaterThanOrEqual(compact.width, minimum.width, "Prefer usable space above or below over an excessively narrow side")
        XCTAssertGreaterThanOrEqual(compact.height, minimum.height)
    }

    @MainActor func testNewReferencesOpenBesideShelfAndCascade() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let store = ShelfStore(root: root)
        let groups = try (0..<3).map { try store.createFolder(name: "Reference \($0)") }
        let app = AppController(store: store, preferences: preferences)
        app.shelf.install(content: EmptyView(), key: { _ in false })
        defer {
            for panel in app.referenceWindows.values { panel.close() }
            app.shelf.panel.close()
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let visible = app.shelf.panel.screen!.visibleFrame
        let shelfFrame = CGRect(x: visible.minX + 20, y: visible.maxY - 460, width: 340, height: 440)
        app.shelf.panel.setFrame(shelfFrame, display: true)
        app.openReference(.group(groups[0].id)) // Menus, toolbar buttons and keyboard shortcuts share this entry.
        let first = try XCTUnwrap(app.referenceWindows[.group(groups[0].id)])
        XCTAssertFalse(first.frame.intersects(shelfFrame), "A new reference must leave the Shelf uncovered")

        let card = ShelfCollection.CardView(frame: CGRect(x: 20, y: 40, width: 148, height: 173))
        card.folderID = groups[1].id
        card.pinButton.app = app
        card.pinButton.referenceTarget = .group(groups[1].id)
        app.shelf.panel.contentView!.addSubview(card)
        card.pinButton.performClick(nil)
        let second = try XCTUnwrap(app.referenceWindows[.group(groups[1].id)])
        let secondDestination = second.referenceTransition?.destinationFrame ?? second.frame
        app.openReference(.group(groups[2].id))
        let third = try XCTUnwrap(app.referenceWindows[.group(groups[2].id)])
        let destinations = [first.frame, secondDestination, third.frame]
        for frame in destinations {
            XCTAssertTrue(visible.contains(frame))
            XCTAssertGreaterThanOrEqual(frame.minX, shelfFrame.maxX + 12)
        }
        for (earlier, later) in zip(destinations, destinations.dropFirst()) {
            XCTAssertGreaterThan(later.minX, earlier.minX, "Each new reference should reveal the previous window's edge")
            XCTAssertLessThan(later.maxY, earlier.maxY, "Use the destination of a window that is still opening")
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(second.frame, secondDestination)
        let remembered = third.frame.offsetBy(dx: -20, dy: 12)
        third.setFrame(remembered, display: false)
        app.closeReference(.group(groups[2].id))
        app.openReference(.group(groups[2].id))
        XCTAssertEqual(app.referenceWindows[.group(groups[2].id)]?.frame, remembered, "Reopening must respect the user's saved position")
    }

    @MainActor func testGroupAndImageReferenceWindowsStayIndependent() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let store = ShelfStore(root: root)
        let image = try SnipShelfTests().image(width: 1800, height: 1200)
        let a = try store.add(image, name: "Material study"), b = try store.add(image, name: "Detail study")
        let c = try store.add(image, name: "Color study"), loose = try store.add(image, name: "Loose reference")
        let first = try store.createFolder(name: "Materials", including: [a.id, b.id])
        let second = try store.createFolder(name: "Colors", including: [c.id])
        let app = AppController(store: store, preferences: preferences)
        defer {
            for panel in app.referenceWindows.values { panel.close() }
            app.previewClip = nil
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        store.openFolder(second.id); store.selection = c.id
        for target in [ReferenceTarget.group(first.id), .group(second.id), .clip(a.id), .clip(b.id)] { app.openReference(target) }
        XCTAssertEqual(app.referenceWindows.count, 4)
        let firstPanel = try XCTUnwrap(app.referenceWindows[.group(first.id)])
        let secondPanel = try XCTUnwrap(app.referenceWindows[.group(second.id)])
        let pin = try XCTUnwrap(app.referenceWindows[.clip(a.id)])
        app.openReference(.clip(a.id))
        XCTAssertTrue(app.referenceWindows[.clip(a.id)] === pin, "Opening an existing pin focuses it")
        XCTAssertEqual(app.referenceWindows.count, 4)
        XCTAssertEqual(store.currentFolderID, second.id)
        XCTAssertEqual(store.selectedIDs, [c.id])
        XCTAssertTrue(app.referenceWindows.values.allSatisfy { $0.level == .floating && !$0.hidesOnDeactivate && $0.styleMask.contains(.resizable) })
        try await Task.sleep(for: .milliseconds(150))
        func collection(in view: NSView) -> ShelfCollection.CollectionView? {
            (view as? ShelfCollection.CollectionView) ?? view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let firstGrid = try XCTUnwrap(collection(in: try XCTUnwrap(firstPanel.contentView)))
        let secondGrid = try XCTUnwrap(collection(in: try XCTUnwrap(secondPanel.contentView)))
        let coordinator = try XCTUnwrap(firstGrid.dataSource as? ShelfCollection.Coordinator)
        XCTAssertEqual(coordinator.entries.compactMap(\.clip).map(\.id), [b.id, a.id])
        func key(_ code: UInt16, _ text: String = "", _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: firstPanel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(firstGrid.handleKey(try key(0, "a", .command)))
        XCTAssertEqual(coordinator.selectedIDs, [a.id, b.id])
        XCTAssertEqual(store.selectedIDs, [c.id], "Reference selection must not select hidden clips in the shelf")
        XCTAssertFalse(firstGrid.handleKey(try key(51)), "Delete in a reference must not delete the shelf selection")
        app.closeReference(.clip(b.id))
        let card = try XCTUnwrap(firstGrid.item(at: IndexPath(item: 0, section: 0))?.view as? ShelfCollection.CardView)
        card.layoutSubtreeIfNeeded()
        let pinPoint = card.pinButton.convert(CGPoint(x: card.pinButton.bounds.midX, y: card.pinButton.bounds.midY), to: firstGrid.superview)
        let hit = firstGrid.hitTest(pinPoint)
        XCTAssertTrue(hit === card.pinButton || hit?.isDescendant(of: card.pinButton) == true, "The collection must let the pin button receive pointer clicks")
        card.pinButton.performClick(nil)
        XCTAssertNotNil(app.referenceWindows[.clip(b.id)])
        XCTAssertNil(app.previewClip)
        XCTAssertEqual(store.selectedIDs, [c.id])
        try await Task.sleep(for: .milliseconds(320))

        let button = card.dragHandle
        let start = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: firstPanel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let existing = try XCTUnwrap(app.referenceWindows[.clip(b.id)])
        let count = store.clips.count, selection = store.selectedIDs
        let boardChanges = NSPasteboard(name: .drag).changeCount
        let destination = CGPoint(x: NSScreen.main!.visibleFrame.midX, y: NSScreen.main!.visibleFrame.midY)
        let release = firstPanel.convertPoint(fromScreen: destination)
        let cardFrame = firstPanel.convertToScreen(card.convert(card.bounds, to: nil))
        var dropFrame = cardFrame.offsetBy(dx: release.x - start.x, dy: release.y - start.y)
        NSApp.postEvent(try mouse(.leftMouseUp, release), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, release), atStart: true)
        button.mouseDown(with: try mouse(.leftMouseDown, start))
        XCTAssertTrue(app.referenceWindows[.clip(b.id)] === existing, "Dragging an existing pin repositions it without making a second window")
        try await Task.sleep(for: .milliseconds(60))
        var interruptedFrame = existing.frame
        let nextRelease = CGPoint(x: release.x + 45, y: release.y - 25)
        let releaseInspection = Timer(timeInterval: 0.04, repeats: false) { _ in
            MainActor.assumeIsolated {
                interruptedFrame = existing.frame
                NSApp.postEvent(try! mouse(.leftMouseUp, nextRelease), atStart: true)
            }
        }
        RunLoop.main.add(releaseInspection, forMode: .common)
        NSApp.postEvent(try mouse(.leftMouseDragged, nextRelease), atStart: true)
        button.mouseDown(with: try mouse(.leftMouseDown, start))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(existing.frame.minX, interruptedFrame.minX, accuracy: 2, "Retargeting must begin at the current on-screen position")
            XCTAssertEqual(existing.frame.minY, interruptedFrame.minY, accuracy: 2)
        }
        dropFrame = cardFrame.offsetBy(dx: nextRelease.x - start.x, dy: nextRelease.y - start.y)
        try await Task.sleep(for: .milliseconds(320))
        var placed = existing.frame
        placed.origin = CGPoint(x: dropFrame.midX - placed.width / 2, y: dropFrame.midY - placed.height / 2)
        placed = ShelfWindow.constrainedFrame(placed, to: NSScreen.main!.visibleFrame)
        XCTAssertEqual(existing.frame.minX, placed.minX, accuracy: 1)
        XCTAssertEqual(existing.frame.maxY, placed.maxY, accuracy: 1)
        XCTAssertEqual(app.referenceWindows.count, 4)
        XCTAssertEqual(store.clips.count, count)
        XCTAssertEqual(store.selectedIDs, selection)
        XCTAssertEqual(store.currentFolderID, second.id)
        XCTAssertEqual(store.clips.first { $0.id == b.id }?.folderID, first.id)
        XCTAssertFalse(app.isDraggingClips)
        XCTAssertTrue(app.draggedClipIDs.isEmpty)
        XCTAssertEqual(NSPasteboard(name: .drag).changeCount, boardChanges)
        let previousFrame = existing.frame
        let previousSavedFrame = preferences.string(forKey: ReferenceTarget.clip(b.id).frameKey)
        NSApp.postEvent(try key(53), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, CGPoint(x: release.x + 60, y: release.y + 40)), atStart: true)
        button.mouseDown(with: try mouse(.leftMouseDown, start))
        XCTAssertEqual(existing.frame, previousFrame, "Escape restores an existing reference's position")
        XCTAssertEqual(preferences.string(forKey: ReferenceTarget.clip(b.id).frameKey), previousSavedFrame)
        try await Task.sleep(for: .milliseconds(320))
        app.closeReference(.clip(b.id))
        app.toggleReferences()
        NSApp.postEvent(try key(53), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, release), atStart: true)
        button.mouseDown(with: try mouse(.leftMouseDown, start))
        XCTAssertNil(app.referenceWindows[.clip(b.id)], "Escape discards a new reference")
        XCTAssertTrue(app.referencesHidden, "Cancelling preserves the visibility of existing references")
        XCTAssertEqual(preferences.string(forKey: ReferenceTarget.clip(b.id).frameKey), previousSavedFrame)
        try await Task.sleep(for: .milliseconds(320))
        app.toggleReferences()
        // Inspect the transition before a simulated button press can finish it.
        XCTAssertTrue(card.pinButton.sendAction(card.pinButton.action, to: card.pinButton.target))
        XCTAssertNotNil(app.referenceWindows[.clip(b.id)], "The separate window button opens a reference on click")
        let opening = try XCTUnwrap(app.referenceWindows[.clip(b.id)])
        let openingDestination = try XCTUnwrap(opening.referenceTransition?.destinationFrame)
        app.closeReference(.clip(b.id))
        XCTAssertEqual(preferences.string(forKey: ReferenceTarget.clip(b.id).frameKey), NSStringFromRect(openingDestination), "Closing mid-expansion must remember the full window size")
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertNil(app.referenceWindows[.clip(b.id)], "Finishing an opening animation must not reopen a window closed during it")
        XCTAssertFalse(NSApp.windows.contains { $0 is ReferenceLiftWindow && $0.isVisible })
        app.openReference(.clip(b.id))
        XCTAssertEqual(app.referenceWindows[.clip(b.id)]?.frame, openingDestination)
        firstPanel.setFrameOrigin(firstPanel.frame.origin.applying(CGAffineTransform(translationX: 24, y: -32)))
        let savedFrame = firstPanel.frame
        app.toggleReferences()
        XCTAssertTrue(app.referenceWindows.values.allSatisfy { !$0.isVisible })
        app.toggleReferences()
        XCTAssertEqual(firstPanel.frame, savedFrame)
        app.closeReference(.group(first.id)); app.openReference(.group(first.id))
        XCTAssertEqual(app.referenceWindows[.group(first.id)]?.frame, savedFrame)

        store.openFolder(nil); store.selection = loose.id
        let board = NSPasteboard(name: .init(suite))
        defer { board.releaseGlobally() }
        let writer = try XCTUnwrap(app.clipPasteboardItem(b))
        XCTAssertEqual(writer.string(forType: .fileURL), store.url(for: b).absoluteString)
        XCTAssertEqual(writer.data(forType: .png), try Data(contentsOf: store.url(for: b)))
        XCTAssertTrue(board.writeObjects([writer]))
        app.isDraggingClips = true; app.draggedClipIDs = [b.id]
        let drop = GroupDraggingInfo(window: secondPanel, board: board, location: secondGrid.convert(CGPoint(x: 8, y: 8), to: nil))
        XCTAssertEqual(secondGrid.draggingEntered(drop), .move)
        XCTAssertTrue(secondGrid.performDragOperation(drop))
        app.isDraggingClips = false; app.draggedClipIDs = []
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.clips.count, 4, "Reference drags move the original clip instead of importing a copy")
        XCTAssertEqual(store.currentFolderID, nil)
        XCTAssertEqual(store.selectedIDs, [loose.id])
        XCTAssertEqual(secondGrid.numberOfItems(inSection: 0), 2, "Open group windows follow membership changes")
        XCTAssertNotNil(app.referenceWindows[.clip(b.id)], "A pin follows its image when it changes groups")
        try store.renameFolder(second.id, name: "Color directions")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(secondPanel.title, "Color directions")

        if let destination = ProcessInfo.processInfo.environment["SNIPSHELF_RENDER_QA"] {
            let directory = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (appearance, suffix): (NSAppearance.Name, String) in [(.aqua, "light"), (.darkAqua, "dark")] {
                for (panel, name, size) in [(secondPanel, "reference-group", CGSize(width: 300, height: 300)), (pin, "reference-image", CGSize(width: 240, height: 240))] {
                    panel.appearance = NSAppearance(named: appearance); panel.setContentSize(size)
                    try await Task.sleep(for: .milliseconds(100))
                    let view = try XCTUnwrap(panel.contentView)
                    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                    XCTAssertEqual(view.bounds.width, size.width, accuracy: 1, "Full-resolution images must fit compact reference windows")
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-" + suffix + ".png"))
                }
            }
        }
        store.delete([a.id])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(app.referenceWindows[.clip(a.id)], "Deleting a clip closes its stale pin")
        XCTAssertNotNil(app.referenceWindows[.group(first.id)], "An empty group remains open as a drop target")
        let emptyPanel = try XCTUnwrap(app.referenceWindows[.group(first.id)])
        let emptyGrid = try XCTUnwrap(collection(in: try XCTUnwrap(emptyPanel.contentView)))
        XCTAssertEqual(emptyGrid.numberOfItems(inSection: 0), 0)
        app.isDraggingClips = true; app.draggedClipIDs = [b.id]
        let emptyDrop = GroupDraggingInfo(window: emptyPanel, board: board, location: emptyGrid.convert(CGPoint(x: 8, y: 8), to: nil))
        XCTAssertTrue(emptyGrid.performDragOperation(emptyDrop))
        app.isDraggingClips = false; app.draggedClipIDs = []
        store.dissolveFolder(first.id)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(app.referenceWindows[.group(first.id)])
        XCTAssertNotNil(app.referenceWindows[.clip(b.id)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: b).path))
        XCTAssertTrue(app.handleReferenceKey(try key(13, "w", .command), target: .clip(b.id)))
        XCTAssertNil(app.referenceWindows[.clip(b.id)])
        XCTAssertEqual(store.clips.count, 3, "Closing windows never deletes images")
        XCTAssertTrue(NSScreen.main!.visibleFrame.contains(ShelfWindow.constrainedFrame(CGRect(x: -100000, y: -100000, width: 9999, height: 9999), to: NSScreen.main!.visibleFrame)))
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
