import XCTest
import AppKit
import SwiftUI
@testable import SnipShelf

final class ShelfOrganizationTests: XCTestCase {
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
}
