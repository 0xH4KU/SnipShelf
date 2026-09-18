import Foundation

/// A Finder package keeps backups portable without an archive dependency or extraction paths.
enum ShelfBackup {
    static func requireSeparate(_ backup: URL, from library: URL) throws {
        let a = backup.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let b = library.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard backup.isFileURL, !a.starts(with: b), !b.starts(with: a) else {
            throw ShelfError("Choose a backup outside the current library folder.")
        }
    }

    private static func requireFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ShelfError("The backup contains an invalid file: \(url.lastPathComponent).")
        }
    }

    static func readIndex(at directory: URL) throws -> ShelfStore.Index {
        let url = directory.appendingPathComponent("index.json")
        try requireFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw ShelfError("The backup index is too large to read.") }
        let index = try JSONDecoder().decode(ShelfStore.Index.self, from: Data(contentsOf: url))
        try index.validate()
        return index
    }

    static func copy(_ index: ShelfStore.Index, from source: URL, to destination: URL) throws {
        try index.validate()
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        for clip in index.clips + (index.deleted ?? []).map(\.clip) {
            try autoreleasepool {
                let original = source.appendingPathComponent("\(clip.id).png")
                try requireFile(original)
                let target = destination.appendingPathComponent(original.lastPathComponent)
                try manager.copyItem(at: original, to: target)
                let image = try ImageCore.load(target)
                guard image.width == clip.width, image.height == clip.height else {
                    throw ShelfError("The backup image does not match its record: \(clip.name).")
                }
                // Rebuilding the small preview also repairs a missing or damaged thumbnail.
                try ImageCore.png(ImageCore.thumbnail(image)).write(
                    to: destination.appendingPathComponent("\(clip.id)-thumb.png"), options: .atomic)
            }
        }
        try JSONEncoder().encode(index).write(to: destination.appendingPathComponent("index.json"), options: .atomic)
    }

    static func write(_ index: ShelfStore.Index, from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".snipshelf-backup-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try copy(index, from: source, to: staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else { try manager.moveItem(at: staging, to: destination) }
    }
}
