import AppKit
import Observation

struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    let width: Int
    let height: Int
    var folderID: UUID? = nil
}

struct ShelfFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
}

struct DeletedClip: Codable, Identifiable, Equatable {
    var clip: Clip
    let deletedAt: Date
    var id: UUID { clip.id }
}

@MainActor @Observable
final class ShelfStore {
    struct Index: Codable {
        let version: Int
        let clips: [Clip]
        var folders: [ShelfFolder]? = nil
        var deleted: [DeletedClip]? = nil
        var itemOrder: [UUID]? = nil

        func validate() throws {
            let groups = folders ?? [], trash = deleted ?? []
            let folderIDs = Set(groups.map(\.id)), records = clips + trash.map(\.clip)
            let activeIDs = Set(clips.map(\.id)).union(folderIDs)
            guard (1...3).contains(version), version == 1 || folders != nil,
                  version < 3 || deleted != nil,
                  Set(records.map(\.id)).count == records.count,
                  folderIDs.count == groups.count,
                  folderIDs.isDisjoint(with: records.map(\.id)),
                  Set(itemOrder ?? []).count == (itemOrder ?? []).count,
                  (itemOrder ?? []).allSatisfy(activeIDs.contains),
                  records.compactMap(\.folderID).allSatisfy(folderIDs.contains),
                  records.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.width <= ImageCore.maxPixels / $0.height }) else {
                throw ShelfError("The shelf index is from an unsupported version or is damaged.")
            }
        }
    }
    struct UndoChange {
        let name: String
        let clips: [Clip]
        let deleted: [DeletedClip]
        let folders: [ShelfFolder]
        let folderID: UUID?
        let itemOrder: [UUID]
    }
    struct BrowsingState {
        var selectedIDs: Set<UUID> = []
        var selectedFolderID: UUID?
        var scrollOrigin: CGPoint = .zero
    }
    let root: URL
    private(set) var clips: [Clip] = []
    private(set) var folders: [ShelfFolder] = []
    private(set) var deleted: [DeletedClip] = []
    private(set) var itemOrder: [UUID] = []
    private(set) var currentFolderID: UUID?
    private(set) var undoHistory: [UndoChange] = []
    var undoTitle: String { undoHistory.last.map { "Undo \($0.name)" } ?? "Undo" }
    @ObservationIgnored var browsingStates: [UUID?: BrowsingState] = [:]
    private var indexUnreadable = false
    private(set) var transferringLibrary = false
    var isReadOnly: Bool { indexUnreadable || transferringLibrary }
    var searchText = "" {
        didSet {
            let wasSearching = !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !wasSearching && isSearching { rememberSelection() }
            if wasSearching && !isSearching { restoreSelection() }
            else if isSearching { selectedIDs.formIntersection(Set(visibleClips.map(\.id))) }
        }
    }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var message: String?
    var selectedIDs: Set<UUID> = [] { didSet { selectedFolderID = nil } }
    private(set) var selectedFolderID: UUID?
    var selection: UUID? {
        get { selectedFolderID ?? clips.first { selectedIDs.contains($0.id) }?.id }
        set {
            if currentFolderID == nil, folders.contains(where: { $0.id == newValue }) {
                selectedIDs = []; selectedFolderID = newValue
            } else { selectedIDs = newValue.map { [$0] } ?? [] }
        }
    }
    var latestID: UUID?
    var pendingImage: CGImage?
    var pendingName = "Clip"
    private var pendingFolderID: UUID?
    @ObservationIgnored private let thumbnails = NSCache<NSUUID, NSImage>()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnipShelf", isDirectory: true)
        thumbnails.countLimit = 120
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let indexURL = self.root.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                try index.validate()
                clips = index.clips
                folders = index.folders ?? []
                deleted = index.deleted ?? []
                itemOrder = index.itemOrder ?? []
            }
            collectUnusedFiles()
        } catch {
            indexUnreadable = true
            message = "Your saved shelf could not be read. Files have been kept untouched at \(self.root.path). \(error.localizedDescription)"
        }
    }

    func url(for clip: Clip) -> URL { root.appendingPathComponent("\(clip.id).png") }
    func thumbnailURL(for clip: Clip) -> URL { root.appendingPathComponent("\(clip.id)-thumb.png") }
    var selectedClip: Clip? { selectedIDs.count == 1 ? clips.first { selectedIDs.contains($0.id) } : nil }
    var currentFolder: ShelfFolder? { folders.first { $0.id == currentFolderID } }
    var visibleClips: [Clip] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return clips(in: currentFolderID) }
        let matchingGroups = Set(folders.filter { $0.name.localizedStandardContains(query) }.map(\.id))
        return clips.filter { $0.name.localizedStandardContains(query) || $0.folderID.map(matchingGroups.contains) == true }
    }

    func orderedIDs(_ ids: [UUID]) -> [UUID] {
        let saved = Set(itemOrder), available = Set(ids)
        // New captures keep appearing first without disturbing the manually arranged items.
        return ids.filter { !saved.contains($0) } + itemOrder.filter(available.contains)
    }

    func clips(in folderID: UUID?) -> [Clip] {
        let members = clips.filter { $0.folderID == folderID }
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        return orderedIDs(members.map(\.id)).compactMap { byID[$0] }
    }

    @discardableResult func reorder(_ ids: [UUID], in folderID: UUID?) -> Bool {
        do {
            let peers = (folderID == nil ? folders.map(\.id) : []) + clips.filter { $0.folderID == folderID }.map(\.id)
            guard (folderID == nil || folders.contains { $0.id == folderID }),
                  ids.count == peers.count, Set(ids) == Set(peers) else {
                throw ShelfError("These items changed while you were arranging them. Try again.")
            }
            guard ids != orderedIDs(peers) else { return false }
            let changed = Set(ids)
            try commit(clips, itemOrder: itemOrder.filter { !changed.contains($0) } + ids, undoName: "Reorder Items")
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func locationName(for clip: Clip) -> String { folders.first { $0.id == clip.folderID }?.name ?? "Shelf" }

    private func rememberSelection() {
        browsingStates[currentFolderID, default: BrowsingState()].selectedIDs = selectedIDs
        browsingStates[currentFolderID, default: BrowsingState()].selectedFolderID = selectedFolderID
    }

    private func restoreSelection() {
        let saved = browsingStates[currentFolderID] ?? BrowsingState()
        selectedIDs = saved.selectedIDs.intersection(Set(visibleClips.map(\.id)))
        if currentFolderID == nil, let folder = saved.selectedFolderID, folders.contains(where: { $0.id == folder }) {
            selectedFolderID = folder
        }
    }

    func openFolder(_ id: UUID?) {
        searchText = ""
        guard currentFolderID != id, id == nil || folders.contains(where: { $0.id == id }) else { return }
        rememberSelection()
        currentFolderID = id
        restoreSelection()
    }

    func thumbnail(for clip: Clip) -> NSImage? {
        if let cached = thumbnails.object(forKey: clip.id as NSUUID) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(for: clip)) else { return nil }
        thumbnails.setObject(image, forKey: clip.id as NSUUID)
        return image
    }

    private func commit(_ next: [Clip], folders nextFolders: [ShelfFolder]? = nil, deleted nextDeleted: [DeletedClip]? = nil,
                        itemOrder nextOrder: [UUID]? = nil, undoName: String? = nil) throws {
        guard !isReadOnly else { throw ShelfError("The shelf is read-only until its index is repaired. Your existing files are safe.") }
        let nextFolders = nextFolders ?? folders
        let nextDeleted = nextDeleted ?? deleted
        let activeIDs = Set(next.map(\.id) + nextFolders.map(\.id))
        let nextOrder = (nextOrder ?? itemOrder).filter(activeIDs.contains)
        guard next != clips || nextFolders != folders || nextDeleted != deleted || nextOrder != itemOrder else { return }
        let index = Index(version: 3, clips: next, folders: nextFolders, deleted: nextDeleted, itemOrder: nextOrder)
        try index.validate()
        let data = try JSONEncoder().encode(index)
        try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        if let undoName {
            let clipsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
            let deletedByID = Dictionary(uniqueKeysWithValues: nextDeleted.map { ($0.id, $0) })
            undoHistory.append(UndoChange(name: undoName,
                clips: clips.filter { clipsByID[$0.id] != $0 },
                deleted: deleted.filter { deletedByID[$0.id] != $0 },
                folders: folders, folderID: currentFolderID, itemOrder: itemOrder))
        }
        clips = next
        folders = nextFolders
        deleted = nextDeleted
        itemOrder = nextOrder
        if isSearching { selectedIDs.formIntersection(Set(visibleClips.map(\.id))) }
    }

    private func folderName(_ name: String, excluding id: UUID? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ShelfError("Enter a group name.") }
        guard !folders.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ShelfError("A group with that name already exists.")
        }
        return name
    }

    @discardableResult func createFolder(name: String, including ids: Set<UUID> = []) throws -> ShelfFolder {
        let folder = ShelfFolder(id: UUID(), name: try folderName(name))
        try commit(moving(ids, to: folder.id), folders: folders + [folder], undoName: "New Group")
        selectedIDs.formIntersection(Set(visibleClips.map(\.id)))
        return folder
    }

    private func moving(_ ids: Set<UUID>, to folderID: UUID?) -> [Clip] {
        clips.map { clip in
            var clip = clip
            if ids.contains(clip.id) { clip.folderID = folderID }
            return clip
        }
    }

    func renameFolder(_ id: UUID, name: String) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var next = folders
        next[index].name = try folderName(name, excluding: id)
        try commit(clips, folders: next, undoName: "Rename Group")
    }

    func renameClip(_ id: UUID, name: String) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ShelfError("Enter an image name.") }
        var next = clips
        next[index].name = name
        try commit(next, undoName: "Rename Image")
    }

    @discardableResult func move(_ ids: Set<UUID>, to folderID: UUID?) -> Bool {
        do {
            guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
                throw ShelfError("That group no longer exists.")
            }
            let next = moving(ids, to: folderID)
            guard next != clips else { return false }
            try commit(next, undoName: "Move Clips")
            selectedIDs.formIntersection(Set(visibleClips.map(\.id)))
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func dissolveFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        do {
            let next = moving(Set(clips.filter { $0.folderID == id }.map(\.id)), to: nil)
            let trash = deleted.map { entry in
                var entry = entry
                if entry.clip.folderID == id { entry.clip.folderID = nil }
                return entry
            }
            try commit(next, folders: folders.filter { $0.id != id }, deleted: trash, undoName: "Dissolve Group")
            if selectedFolderID == id { selectedFolderID = nil }
            if currentFolderID == id { openFolder(nil) }
        } catch { message = error.localizedDescription }
    }

    // ponytail: serial PNG/index writes keep transactions small; move encoding off-main if very large imports stall interaction.
    @discardableResult func add(_ image: CGImage, name: String, folderID: UUID? = nil) throws -> Clip {
        guard !isReadOnly else { throw ShelfError("The shelf is read-only. Open its storage folder to recover the index.") }
        // An import finishing after its folder was dissolved belongs back on the shelf.
        let folderID = folders.first { $0.id == folderID }?.id
        let clip = Clip(id: UUID(), name: name, createdAt: Date(), width: image.width, height: image.height, folderID: folderID)
        do {
            try ImageCore.png(image).write(to: url(for: clip), options: .atomic)
            try ImageCore.png(ImageCore.thumbnail(image)).write(to: thumbnailURL(for: clip), options: .atomic)
            try commit([clip] + clips)
        } catch {
            try? FileManager.default.removeItem(at: url(for: clip))
            try? FileManager.default.removeItem(at: thumbnailURL(for: clip))
            throw error
        }
        latestID = clip.id
        if visibleClips.contains(where: { $0.id == clip.id }) { selection = clip.id }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.latestID == clip.id { self?.latestID = nil }
        }
        return clip
    }

    func receive(_ image: CGImage, name: String, folderID: UUID? = nil) {
        do { try add(image, name: name, folderID: folderID) }
        catch {
            pendingImage = image; pendingName = name; pendingFolderID = folderID
            message = "Could not save this clip. It is still in memory; use Retry Save or Export Unsaved Clip before quitting. \(error.localizedDescription)"
        }
    }

    func retryPending() {
        guard let image = pendingImage else { return }
        do { try add(image, name: pendingName, folderID: pendingFolderID); pendingImage = nil }
        catch { message = error.localizedDescription }
    }

    func delete(_ ids: Set<UUID>) {
        let ids = ids.intersection(Set(clips.map(\.id)))
        guard !ids.isEmpty else { return }
        do {
            let removed = clips.filter { ids.contains($0.id) }.map { DeletedClip(clip: $0, deletedAt: Date()) }
            try commit(clips.filter { !ids.contains($0.id) }, deleted: removed + deleted, undoName: "Deletion")
            selectedIDs.subtract(ids)
        } catch { message = error.localizedDescription }
    }

    func undo() {
        guard let change = undoHistory.last else { return }
        do {
            // Restore only this edit's records; captures and imports added later stay intact.
            let changedClips = Set(change.clips.map(\.id) + change.deleted.map(\.id))
            let nextFolders = change.folders
            let folderIDs = Set(nextFolders.map(\.id))
            let next = (clips.filter { !changedClips.contains($0.id) } + change.clips).map { clip in
                var clip = clip
                if let id = clip.folderID, !folderIDs.contains(id) { clip.folderID = nil }
                return clip
            }
            let trash = (deleted.filter { !changedClips.contains($0.id) } + change.deleted).map { entry in
                var entry = entry
                if let id = entry.clip.folderID, !folderIDs.contains(id) { entry.clip.folderID = nil }
                return entry
            }.sorted { $0.deletedAt > $1.deletedAt }
            try commit(next.sorted { $0.createdAt > $1.createdAt }, folders: nextFolders, deleted: trash, itemOrder: change.itemOrder)
            if let id = selectedFolderID, !folderIDs.contains(id) { selectedFolderID = nil }
            if isSearching {
                selectedIDs = Set(visibleClips.filter { changedClips.contains($0.id) }.map(\.id))
            } else if let first = change.clips.first, let restored = clips.first(where: { $0.id == first.id }) {
                openFolder(restored.folderID)
                selectedIDs = Set(visibleClips.filter { changedClips.contains($0.id) }.map(\.id))
            } else { openFolder(change.folderID) }
            undoHistory.removeLast()
        } catch { message = error.localizedDescription }
    }

    func restoreDeleted(_ ids: Set<UUID>) {
        let restored = deleted.filter { ids.contains($0.id) }.map(\.clip)
        guard !restored.isEmpty else { return }
        do {
            try commit((clips + restored).sorted { $0.createdAt > $1.createdAt },
                       deleted: deleted.filter { !ids.contains($0.id) }, undoName: "Restore Clips")
        } catch { message = error.localizedDescription }
    }

    func permanentlyDelete(_ ids: Set<UUID>) throws {
        let ids = ids.intersection(Set(deleted.map(\.id)))
        guard !ids.isEmpty else { return }
        try commit(clips, deleted: deleted.filter { !ids.contains($0.id) })
        undoHistory.removeAll { change in
            change.clips.contains { ids.contains($0.id) } || change.deleted.contains { ids.contains($0.id) }
        }
        collectUnusedFiles()
    }

    func backup(to destination: URL) async throws {
        guard !isReadOnly, pendingImage == nil else { throw ShelfError("Finish saving your clip before backing up the library.") }
        try ShelfBackup.requireSeparate(destination, from: root)
        transferringLibrary = true
        defer { transferringLibrary = false }
        let index = Index(version: 3, clips: clips, folders: folders, deleted: deleted, itemOrder: itemOrder), source = root
        try await Task.detached(priority: .userInitiated) {
            try ShelfBackup.write(index, from: source, to: destination)
        }.value
    }

    /// Returns the untouched previous library, retained beside the current one.
    @discardableResult func restoreBackup(from source: URL) async throws -> URL {
        guard !transferringLibrary, pendingImage == nil else { throw ShelfError("Finish the current save before restoring a library.") }
        try ShelfBackup.requireSeparate(source, from: root)
        transferringLibrary = true
        defer { transferringLibrary = false }
        let staging = root.deletingLastPathComponent().appendingPathComponent(".snipshelf-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let index = try await Task.detached(priority: .userInitiated) {
            let index = try ShelfBackup.readIndex(at: source)
            try ShelfBackup.copy(index, from: source, to: staging)
            return index
        }.value
        let recoveryName = "\(root.lastPathComponent)-before-restore-\(UUID().uuidString).snipshelfbackup"
        let currentIndex = root.appendingPathComponent("index.json")
        if !indexUnreadable && !FileManager.default.fileExists(atPath: currentIndex.path) {
            try JSONEncoder().encode(Index(version: 3, clips: clips, folders: folders, deleted: deleted, itemOrder: itemOrder)).write(to: currentIndex, options: .atomic)
        }
        _ = try FileManager.default.replaceItemAt(root, withItemAt: staging, backupItemName: recoveryName,
                                                  options: .withoutDeletingBackupItem)
        clips = index.clips; folders = index.folders ?? []; deleted = index.deleted ?? []
        itemOrder = index.itemOrder ?? []
        undoHistory = []; browsingStates = [:]; currentFolderID = nil
        searchText = ""; selectedIDs = []; latestID = nil
        thumbnails.removeAllObjects(); indexUnreadable = false
        return root.deletingLastPathComponent().appendingPathComponent(recoveryName)
    }

    func collectUnusedFiles() {
        guard !isReadOnly else { return }
        let kept = Set((clips + deleted.map(\.clip) + undoHistory.flatMap(\.clips) + undoHistory.flatMap { $0.deleted.map(\.clip) })
            .flatMap { ["\($0.id).png", "\($0.id)-thumb.png"] })
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" && !kept.contains(file.lastPathComponent) {
            let stem = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-thumb", with: "")
            if UUID(uuidString: stem) != nil { try? FileManager.default.removeItem(at: file) }
        }
    }
}
