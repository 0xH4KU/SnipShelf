import SwiftUI

struct ShelfHeader: View {
    let app: AppController
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var store = app.store
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if app.store.currentFolder != nil {
                    Button("Back to Shelf", systemImage: "chevron.left") { app.openFolder(nil) }
                        .labelStyle(.iconOnly).frame(width: 28, height: 28)
                        .help("Back to Shelf (⌘[) · Drop clips here to move them out")
                        .onDrop(of: ShelfDropDelegate.types, delegate: ShelfFolderDropDelegate(app: app, folderID: nil))
                }
                Text(app.store.currentFolder?.name ?? "SnipShelf")
                    .font(.headline).lineLimit(1).truncationMode(.tail)
                    .help(app.store.currentFolder?.name ?? "Drag the title bar to move your shelf")
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                if let folder = app.store.currentFolder {
                    Menu("Group Options", systemImage: "ellipsis") {
                        Button("Open Reference Window", systemImage: "arrow.up.forward.square") { app.openReference(.group(folder.id)) }
                        Button("Rename Group…", systemImage: "pencil") { app.editFolder(folder) }
                            .disabled(app.store.isReadOnly)
                        Button("Dissolve Group — Keep Clips", systemImage: "rectangle.stack.badge.minus") { app.store.dissolveFolder(folder.id) }
                            .disabled(app.store.isReadOnly)
                    }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().frame(width: 28, height: 28).help("Group options")
                }
                Button("Tuck Shelf to Edge", systemImage: app.shelf.edge == "left" ? "sidebar.left" : "sidebar.right", action: app.shelf.collapse)
                    .labelStyle(.iconOnly).frame(width: 28, height: 28)
                    .foregroundStyle(.secondary).help("Tuck shelf to the screen edge (Esc)")
            }
            .buttonStyle(.borderless)
            .background { ShelfMoveHandle(shelf: app.shelf) }

            HStack(spacing: 8) {
                Button("Capture", systemImage: "lasso", action: app.capture)
                    .buttonStyle(.borderedProminent)
                    .help("Capture an element (\(app.shortcutLabel))").disabled(app.busy || app.store.isReadOnly)
                Button("Import", systemImage: "plus", action: app.chooseImages)
                    .help("Import images (⌘O)").disabled(app.busy || app.store.isReadOnly)
                Spacer(minLength: 0)
                Button("New Group", systemImage: "rectangle.stack.badge.plus") { app.editFolder(including: app.store.selectedIDs) }
                    .labelStyle(.iconOnly).frame(width: 28, height: 28)
                    .buttonStyle(.borderless)
                    .help(app.store.selectedIDs.isEmpty ? "New group (⇧⌘N)" : "New group with selection (⇧⌘N)")
                    .disabled(app.store.isReadOnly)
            }
            .buttonStyle(.bordered).controlSize(.regular)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all groups", text: $store.searchText)
                    .textFieldStyle(.plain).focused($searching)
                    .accessibilityLabel("Search images and group names")
                    .onExitCommand { store.searchText = ""; searching = false }
                if !store.searchText.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { store.searchText = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
            .onChange(of: app.searchFocusRequest) { searching = true }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
