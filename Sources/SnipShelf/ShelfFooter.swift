import SwiftUI

struct ShelfFooter: View {
    let app: AppController
    private var store: ShelfStore { app.store }

    var body: some View {
        HStack(spacing: 8) {
            if app.busy { ProgressView().controlSize(.mini).accessibilityLabel("Adding images") }
            Text(status)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).help(status)
            Spacer(minLength: 0)
            if let clip = store.selectedClip {
                Button("Pin as Reference", systemImage: "pin") { app.openReference(.clip(clip.id)) }
                    .labelStyle(.iconOnly).frame(width: 28, height: 28).help("Pin as reference (⇧⌘P)")
                Button("Copy Image", systemImage: "doc.on.doc") { app.copy(clip) }
                    .labelStyle(.iconOnly).frame(width: 28, height: 28).help("Copy image (⌘C)")
            } else if store.selectedFolderID != nil || store.selectedIDs.count > 1 {
                Button("Pin Selection", systemImage: "pin", action: app.pinSelection)
                    .labelStyle(.iconOnly).frame(width: 28, height: 28).help("Pin selection as references (⇧⌘P)")
            }
            if !store.undoHistory.isEmpty {
                Button(store.undoTitle, systemImage: "arrow.uturn.backward", action: store.undo)
                    .labelStyle(.iconOnly).frame(width: 28, height: 28).help("\(store.undoTitle) (⌘Z)")
            }
            Menu("Shelf Options", systemImage: "ellipsis") {
                if !store.selectedIDs.isEmpty {
                    Section("Selection") {
                        if let clip = store.selectedClip {
                            Button("Preview", systemImage: "eye") { app.previewClip = clip }
                            Button("Rename Image…", systemImage: "pencil") { app.renameClip(clip) }
                                .disabled(store.isReadOnly)
                            Button("Export PNG…", systemImage: "square.and.arrow.up") { app.export(clip) }
                            Button("Crop a Copy…", systemImage: "crop") { app.recrop(clip) }
                        }
                        Menu("Move to Group", systemImage: "rectangle.stack") {
                            Button("New Group with Selection…") { app.editFolder(including: store.selectedIDs) }
                            Divider()
                            if store.currentFolderID != nil { Button("Shelf") { store.move(store.selectedIDs, to: nil) } }
                            ForEach(store.folders) { folder in
                                Button(folder.name) { store.move(store.selectedIDs, to: folder.id) }
                                    .disabled(folder.id == store.currentFolderID)
                            }
                        }.disabled(store.isReadOnly)
                        Button("Delete Selected Clips", systemImage: "trash", role: .destructive) { store.delete(store.selectedIDs) }
                            .disabled(store.isReadOnly)
                    }
                }
                if !app.referenceWindows.isEmpty {
                    Button(app.referencesHidden ? "Show Reference Windows" : "Hide Reference Windows", systemImage: "pin", action: app.toggleReferences)
                    Divider()
                }
                Button("Paste Image", systemImage: "document.on.clipboard", action: app.paste)
                    .disabled(app.busy || store.isReadOnly)
                Button("Clear Shelf…", systemImage: "trash", role: .destructive, action: app.clearShelf)
                    .disabled(store.clips.isEmpty || store.isReadOnly)
                Divider()
                Button("Settings…", systemImage: "gearshape", action: app.showSettings)
                Button("About SnipShelf", systemImage: "info.circle", action: app.showAbout)
                Divider()
                Button("Quit SnipShelf") { NSApp.terminate(nil) }
            }
            .labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize().frame(width: 28, height: 28).help("Shelf and selection options")
        }
        .buttonStyle(.borderless).controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 4)
    }

    private var status: String {
        if let status = app.status { return status }
        if app.busy { return "Adding images…" }
        if store.latestID != nil { return "Clip saved" }
        if !store.selectedIDs.isEmpty { return "\(store.selectedIDs.count) selected" }
        let count = store.visibleClips.count
        let clips = "\(count) \(count == 1 ? "clip" : "clips")"
        guard store.currentFolderID == nil, !store.folders.isEmpty else { return clips }
        return "\(store.folders.count) \(store.folders.count == 1 ? "group" : "groups") · \(clips)"
    }
}
