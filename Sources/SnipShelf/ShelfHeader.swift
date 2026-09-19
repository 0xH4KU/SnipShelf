import SwiftUI

struct ShelfHeader: View {
    let app: AppController
    @FocusState private var searching: Bool
    @State private var hoveringHandle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var direction: LayoutDirection { app.shelf.dockedEdge == "left" ? .rightToLeft : .leftToRight }

    var body: some View {
        @Bindable var store = app.store
        VStack(spacing: 8) {
            Capsule()
                .fill(.secondary.opacity(hoveringHandle ? 0.8 : 0.4))
                .frame(width: hoveringHandle ? 36 : 30, height: 4)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity).frame(height: 10)
                .background { ShelfMoveHandle(shelf: app.shelf) }
                .onHover { hoveringHandle = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hoveringHandle)
                .help("Drag to move your shelf")
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                if app.store.currentFolder != nil {
                    Button("Back to Shelf", systemImage: direction == .rightToLeft ? "chevron.right" : "chevron.left") { app.openFolder(nil) }
                        .labelStyle(.iconOnly).frame(width: 28, height: 28)
                        .buttonHover()
                        .environment(\.layoutDirection, .leftToRight)
                        .help("Back to Shelf (⌘[) · Drop clips here to move them out")
                        .onDrop(of: ShelfDropDelegate.types, delegate: ShelfFolderDropDelegate(app: app, folderID: nil))
                }
                Text(app.store.currentFolder?.name ?? "SnipShelf")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .environment(\.layoutDirection, .leftToRight)
                    .help(app.store.currentFolder?.name ?? "Drag the title bar to move your shelf")
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                Button("Capture", systemImage: "lasso", action: app.capture)
                    .buttonStyle(.bordered).controlSize(.regular).fixedSize()
                    .buttonHover()
                    .environment(\.layoutDirection, .leftToRight)
                    .help("Capture an element (\(app.shortcutLabel))").disabled(app.busy || app.store.isReadOnly)
                Button("Import Images", systemImage: "plus", action: app.chooseImages)
                    .labelStyle(.iconOnly).frame(width: 28, height: 28)
                    .buttonHover().foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
                    .help("Import images (⌘O)").disabled(app.busy || app.store.isReadOnly)
                if let folder = app.store.currentFolder {
                    Menu("Group Options", systemImage: "ellipsis") {
                        Button { app.openReference(.group(folder.id)) } label: {
                            Label { Text("Open Floating Reference") } icon: { Image(nsImage: ReferencePinButton.icon) }
                        }
                        Button("Rename Group…", systemImage: "pencil") { app.editFolder(folder) }
                            .disabled(app.store.isReadOnly)
                        Button("Dissolve Group — Keep Clips", systemImage: "rectangle.stack.badge.minus") { app.store.dissolveFolder(folder.id) }
                            .disabled(app.store.isReadOnly)
                    }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize().frame(width: 28, height: 28).buttonHover().help("Group options")
                }
                Button("Tuck Shelf to Edge", systemImage: app.shelf.edge == "left" ? "sidebar.left" : "sidebar.right", action: app.shelf.collapse)
                    .labelStyle(.iconOnly).frame(width: 28, height: 28)
                    .buttonHover()
                    .environment(\.layoutDirection, .leftToRight)
                    .foregroundStyle(.secondary).help("Tuck shelf to the screen edge (Esc)")
            }
            .environment(\.layoutDirection, direction)
            .buttonStyle(.borderless)
            .background { ShelfMoveHandle(shelf: app.shelf) }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all clips", text: $store.searchText)
                    .textFieldStyle(.plain).focused($searching)
                    .accessibilityLabel("Search images and group names")
                    .onExitCommand { store.searchText = ""; searching = false }
                if !store.searchText.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { store.searchText = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                        .buttonHover()
                } else {
                    Text("⌘ F").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9).frame(height: 29)
            .background(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5).allowsHitTesting(false) }
            .onChange(of: app.searchFocusRequest) { searching = true }

            HStack(spacing: 6) {
                if app.busy { ProgressView().controlSize(.mini).accessibilityLabel("Adding images") }
                Text(status)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).help(status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: app.shelf.dockedEdge)
    }

    private var status: String {
        let store = app.store
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
