import AppKit
import Observation

struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let width: Int
    let height: Int
    var folderID: UUID? = nil
}

struct ShelfFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
}

@MainActor @Observable
final class ShelfStore {
    struct Index: Codable { let version: Int; let clips: [Clip]; var folders: [ShelfFolder]? = nil }
    let root: URL
    private(set) var clips: [Clip] = []
    private(set) var folders: [ShelfFolder] = []
    private(set) var currentFolderID: UUID?
    private(set) var undoHistory: [[Clip]] = []
    private(set) var isReadOnly = false
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
                let folders = index.folders ?? []
                let folderIDs = Set(folders.map(\.id))
                guard (1...2).contains(index.version),
                      index.version == 1 || index.folders != nil,
                      Set(index.clips.map(\.id)).count == index.clips.count,
                      folderIDs.count == folders.count,
                      index.clips.compactMap(\.folderID).allSatisfy(folderIDs.contains) else {
                    throw ShelfError("The shelf index is from an unsupported version or is damaged.")
                }
                clips = index.clips
                self.folders = folders
            }
            collectUnusedFiles()
        } catch {
            isReadOnly = true
            message = "Your saved shelf could not be read. Files have been kept untouched at \(self.root.path). \(error.localizedDescription)"
        }
    }

    func url(for clip: Clip) -> URL { root.appendingPathComponent("\(clip.id).png") }
    func thumbnailURL(for clip: Clip) -> URL { root.appendingPathComponent("\(clip.id)-thumb.png") }
    var selectedClip: Clip? { selectedIDs.count == 1 ? clips.first { selectedIDs.contains($0.id) } : nil }
    var currentFolder: ShelfFolder? { folders.first { $0.id == currentFolderID } }
    var visibleClips: [Clip] { clips.filter { $0.folderID == currentFolderID } }

    func openFolder(_ id: UUID?) {
        guard id == nil || folders.contains(where: { $0.id == id }) else { return }
        currentFolderID = id
        selectedIDs = []
    }

    func thumbnail(for clip: Clip) -> NSImage? {
        if let cached = thumbnails.object(forKey: clip.id as NSUUID) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(for: clip)) else { return nil }
        thumbnails.setObject(image, forKey: clip.id as NSUUID)
        return image
    }

    private func commit(_ next: [Clip], folders nextFolders: [ShelfFolder]? = nil) throws {
        guard !isReadOnly else { throw ShelfError("The shelf is read-only until its index is repaired. Your existing files are safe.") }
        let nextFolders = nextFolders ?? folders
        let data = try JSONEncoder().encode(Index(version: 2, clips: next, folders: nextFolders))
        try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        clips = next
        folders = nextFolders
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
        try commit(moving(ids, to: folder.id), folders: folders + [folder])
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
        try commit(clips, folders: next)
    }

    @discardableResult func move(_ ids: Set<UUID>, to folderID: UUID?) -> Bool {
        do {
            guard folderID == nil || folders.contains(where: { $0.id == folderID }) else {
                throw ShelfError("That group no longer exists.")
            }
            let next = moving(ids, to: folderID)
            guard next != clips else { return false }
            try commit(next)
            selectedIDs.formIntersection(Set(visibleClips.map(\.id)))
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func dissolveFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        do {
            let next = moving(Set(clips.filter { $0.folderID == id }.map(\.id)), to: nil)
            try commit(next, folders: folders.filter { $0.id != id })
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
        if currentFolderID == folderID { selection = clip.id }
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
            let previous = clips
            try commit(clips.filter { !ids.contains($0.id) })
            undoHistory.append(previous)
            selectedIDs.subtract(ids)
        } catch { message = error.localizedDescription }
    }

    func undo() {
        guard let previous = undoHistory.last else { return }
        do {
            // Keep clips captured after deletion; undo only restores removed records.
            let present = Set(clips.map(\.id))
            let restored = previous.filter { !present.contains($0.id) }.map { clip in
                var clip = clip
                if !folders.contains(where: { $0.id == clip.folderID }) { clip.folderID = nil }
                return clip
            }
            try commit((clips + restored).sorted { $0.createdAt > $1.createdAt })
            if let first = restored.first { openFolder(first.folderID) }
            selectedIDs = Set(restored.filter { $0.folderID == currentFolderID }.map(\.id))
            undoHistory.removeLast()
        } catch { message = error.localizedDescription }
    }

    func collectUnusedFiles() {
        guard !isReadOnly else { return }
        let kept = Set((clips + undoHistory.flatMap { $0 }).flatMap { ["\($0.id).png", "\($0.id)-thumb.png"] })
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" && !kept.contains(file.lastPathComponent) {
            let stem = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-thumb", with: "")
            if UUID(uuidString: stem) != nil { try? FileManager.default.removeItem(at: file) }
        }
    }
}
