import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let snipShelfBackup = UTType(exportedAs: "org.snipshelf.backup", conformingTo: .package)
}

struct RecentlyDeletedView: View {
    let app: AppController
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if app.store.deleted.isEmpty {
                ContentUnavailableView("No Deleted Clips", systemImage: "trash", description: Text("Deleted images stay here until you restore or permanently delete them."))
            } else {
                List(app.store.deleted, selection: $selected) { entry in
                    HStack(spacing: 12) {
                        if let image = app.store.thumbnail(for: entry.clip) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 54)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.clip.name).lineLimit(1)
                            Text("\(app.store.locationName(for: entry.clip)) · \(entry.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 3).tag(entry.id)
                }
            }
            Divider()
            HStack {
                Menu("Select", systemImage: "checklist") {
                    Button("Select All") { selected = Set(app.store.deleted.map(\.id)) }
                    Button("Deselect All") { selected = [] }
                }.fixedSize()
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Group {
                    Button("Delete Permanently…", role: .destructive) { app.deletePermanently(selected) }
                    Button("Restore") { app.store.restoreDeleted(selected) }.buttonStyle(.borderedProminent)
                }.disabled(selected.isEmpty || app.store.isReadOnly)
            }.padding(12)
        }
        .onChange(of: app.store.deleted) { selected.formIntersection(Set(app.store.deleted.map(\.id))) }
    }
}

extension AppController {
    func showRecentlyDeleted() {
        if deletedWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 610, height: 450),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Recently Deleted"
            window.minSize = CGSize(width: 520, height: 280)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RecentlyDeletedView(app: self))
            window.center(); deletedWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        deletedWindow?.makeKeyAndOrderFront(nil)
    }

    func deletePermanently(_ ids: Set<UUID>) {
        let ids = ids.intersection(Set(store.deleted.map(\.id)))
        guard !ids.isEmpty, !store.isReadOnly else { return }
        let alert = NSAlert()
        alert.messageText = "Permanently delete \(ids.count) \(ids.count == 1 ? "clip" : "clips")?"
        alert.informativeText = "This removes the saved images from this Mac and cannot be undone. Existing backups are kept."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Permanently")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store.permanentlyDelete(ids) }
        catch { store.message = error.localizedDescription }
    }

    func backupLibrary() {
        guard readyForNewImage(), !store.isReadOnly else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up SnipShelf Library"
        panel.allowedContentTypes = [.snipShelfBackup]
        panel.nameFieldStringValue = "SnipShelf-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).snipshelfbackup"
        panel.message = "Includes every image, group, and Recently Deleted clip."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "Backing up library…"
        Task {
            defer { busy = false; status = nil }
            do {
                try await store.backup(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { store.message = "Backup failed. \(error.localizedDescription)" }
        }
    }

    func restoreLibrary() {
        guard readyForNewImage() else { return }
        let panel = NSOpenPanel()
        panel.title = "Restore SnipShelf Library"
        panel.allowedContentTypes = [.snipShelfBackup]
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Restore this library?"
        alert.informativeText = "This replaces the current images, groups, and Recently Deleted clips. SnipShelf validates the backup first and keeps a copy of your current library beside its storage folder."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Restore Library")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; status = "Restoring library…"
        Task {
            defer { busy = false; status = nil }
            do {
                let previous = try await store.restoreBackup(from: url)
                previewClip = nil
                for target in Array(referenceWindows.keys) { closeReference(target) }
                store.message = "Library restored. Your previous library is kept at:\n\(previous.path)"
            } catch { store.message = "Restore failed. \(error.localizedDescription)" }
        }
    }
}
