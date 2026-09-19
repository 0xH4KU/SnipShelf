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
                Button { app.openReference(.clip(clip.id)) } label: {
                    Label { Text("Open Floating Reference") } icon: { Image(nsImage: ReferencePinButton.icon) }
                }
                    .labelStyle(.iconOnly).frame(width: 28, height: 28).help("Open floating reference (⇧⌘P)")
                Button("Copy Image", systemImage: "doc.on.doc") { app.copy(clip) }
                    .labelStyle(.iconOnly).frame(width: 28, height: 28).help("Copy image (⌘C)")
            } else if store.selectedFolderID != nil || store.selectedIDs.count > 1 {
                Button(action: app.pinSelection) {
                    Label { Text("Open Selection as References") } icon: { Image(nsImage: ReferencePinButton.icon) }
                }
                    .labelStyle(.iconOnly).frame(width: 28, height: 28).help("Open selection as floating references (⇧⌘P)")
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
                            if store.currentFolderID != nil || store.isSearching { Button("Shelf") { store.move(store.selectedIDs, to: nil) } }
                            ForEach(store.folders) { folder in
                                Button(folder.name) { store.move(store.selectedIDs, to: folder.id) }
                                    .disabled(!store.isSearching && folder.id == store.currentFolderID)
                            }
                        }.disabled(store.isReadOnly)
                        Button("Delete Selected Clips", systemImage: "trash", role: .destructive) { store.delete(store.selectedIDs) }
                            .disabled(store.isReadOnly)
                    }
                }
                if !app.referenceWindows.isEmpty {
                    Button(action: app.toggleReferences) {
                        Label { Text(app.referencesHidden ? "Show Reference Windows" : "Hide Reference Windows") } icon: { Image(nsImage: ReferencePinButton.icon) }
                    }
                    Divider()
                }
                Button("Paste Image", systemImage: "document.on.clipboard", action: app.paste)
                    .disabled(app.busy || store.isReadOnly)
                Button("Clear Shelf…", systemImage: "trash", role: .destructive, action: app.clearShelf)
                    .disabled(store.clips.isEmpty || store.isReadOnly)
                Button("Recently Deleted (\(store.deleted.count))…", systemImage: "trash", action: app.showRecentlyDeleted)
                Button("Back Up Library…", systemImage: "externaldrive", action: app.backupLibrary)
                    .disabled(app.busy || store.isReadOnly || store.pendingImage != nil)
                Button("Restore Library…", systemImage: "arrow.triangle.2.circlepath", action: app.restoreLibrary)
                    .disabled(app.busy || store.transferringLibrary || store.pendingImage != nil)
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
        if store.transferringLibrary { return "Transferring library…" }
        if app.busy { return "Adding images…" }
        if store.latestID != nil { return "Clip saved" }
        if !store.selectedIDs.isEmpty { return "\(store.selectedIDs.count) selected" }
        let count = store.visibleClips.count
        if store.isSearching { return "\(count) \(count == 1 ? "result" : "results") · All groups" }
        let clips = "\(count) \(count == 1 ? "clip" : "clips")"
        guard store.currentFolderID == nil, !store.folders.isEmpty else { return clips }
        return "\(store.folders.count) \(store.folders.count == 1 ? "group" : "groups") · \(clips)"
    }
}
