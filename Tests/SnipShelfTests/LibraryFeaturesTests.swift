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
        XCTAssertEqual((grid.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize.height, 173)
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
        let b = try store.add(image, name: "Deleted")
        store.delete([b.id])
        let snapshot = store.clips, trash = store.deleted, png = try Data(contentsOf: store.url(for: a))
        let backup = directory.appendingPathComponent("Saved.snipshelfbackup")
        try await store.backup(to: backup)
        try await store.backup(to: backup) // Replacing an existing backup must be complete, too.
        XCTAssertEqual(try ShelfBackup.readIndex(at: backup).clips, snapshot)
        XCTAssertFalse(store.isReadOnly)
        let later = try store.add(image, name: "Added after backup")
        try store.renameFolder(folder.id, name: "Changed")
        let beforeRestore = store.clips
        let recovery = try await store.restoreBackup(from: backup)
        XCTAssertEqual(store.clips, snapshot); XCTAssertEqual(store.deleted, trash)
        XCTAssertEqual(store.folders, [folder]); XCTAssertTrue(store.undoHistory.isEmpty)
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

}
