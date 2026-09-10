import AppKit
import Observation

struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let width: Int
    let height: Int
}

@MainActor @Observable
final class ShelfStore {
    struct Index: Codable { let version: Int; let clips: [Clip] }
    let root: URL
    private(set) var clips: [Clip] = []
    private(set) var undoHistory: [[Clip]] = []
    private(set) var isReadOnly = false
    var message: String?
    var selectedIDs: Set<UUID> = []
    var selection: UUID? {
        get { clips.first { selectedIDs.contains($0.id) }?.id }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    var latestID: UUID?
    var pendingImage: CGImage?
    var pendingName = "Clip"
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
                guard index.version == 1, Set(index.clips.map(\.id)).count == index.clips.count else {
                    throw ShelfError("The shelf index is from an unsupported version or is damaged.")
                }
                clips = index.clips
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

    func thumbnail(for clip: Clip) -> NSImage? {
        if let cached = thumbnails.object(forKey: clip.id as NSUUID) { return cached }
        guard let image = NSImage(contentsOf: thumbnailURL(for: clip)) else { return nil }
        thumbnails.setObject(image, forKey: clip.id as NSUUID)
        return image
    }

    private func commit(_ next: [Clip]) throws {
        guard !isReadOnly else { throw ShelfError("The shelf is read-only until its index is repaired. Your existing files are safe.") }
        let data = try JSONEncoder().encode(Index(version: 1, clips: next))
        try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        clips = next
    }

    // ponytail: serial PNG/index writes keep transactions small; move encoding off-main if very large imports stall interaction.
    @discardableResult func add(_ image: CGImage, name: String) throws -> Clip {
        guard !isReadOnly else { throw ShelfError("The shelf is read-only. Open its storage folder to recover the index.") }
        let clip = Clip(id: UUID(), name: name, createdAt: Date(), width: image.width, height: image.height)
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
        selection = clip.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.latestID == clip.id { self?.latestID = nil }
        }
        return clip
    }

    func receive(_ image: CGImage, name: String) {
        do { try add(image, name: name) }
        catch {
            pendingImage = image; pendingName = name
            message = "Could not save this clip. It is still in memory; use Retry Save or Export Unsaved Clip before quitting. \(error.localizedDescription)"
        }
    }

    func retryPending() {
        guard let image = pendingImage else { return }
        do { try add(image, name: pendingName); pendingImage = nil }
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
            let restored = (clips + previous.filter { !present.contains($0.id) }).sorted { $0.createdAt > $1.createdAt }
            try commit(restored)
            selectedIDs = Set(previous.filter { !present.contains($0.id) }.map(\.id))
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
