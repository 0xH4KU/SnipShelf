import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Bindable var app: AppController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var store: ShelfStore { app.store }
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            Group {
                if app.shelf.collapsed { edgeTab }
                else { dockingContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear,
                        in: RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24))
            .glassEffect(reduceTransparency ? .identity : .regular, in: RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24))
            .overlay {
                RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24)
                    .strokeBorder(app.shelf.dropTargeted ? Color.accentColor.opacity(0.8) : Color.primary.opacity(contrast == .increased ? 0.5 : 0.08),
                                  lineWidth: app.shelf.dropTargeted ? 2 : (contrast == .increased ? 1 : 0.5))
                    .allowsHitTesting(false)
            }
            .padding(app.shelf.collapsed ? 1 : 5)
        }
        .onDrop(of: ShelfDropDelegate.types, delegate: ShelfDropDelegate(app: app))
        .alert("SnipShelf", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            if store.pendingImage != nil {
                Button("Retry Save") { store.retryPending() }
                Button("Export Unsaved Clip…") { app.exportPending() }
            }
            if store.isReadOnly { Button("Open Storage Folder") { NSWorkspace.shared.open(store.root) } }
            Button("OK", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }

    private var edgeTab: some View {
        VStack(spacing: 9) {
            Image(systemName: store.latestID != nil ? "checkmark" : (app.shelf.edge == "right" ? "chevron.left" : "chevron.right"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(store.latestID != nil ? Color.accentColor : Color.primary)
            if store.latestID != nil {
                Text("Saved").font(.caption2.weight(.medium)).rotationEffect(.degrees(-90))
                    .fixedSize().frame(width: 18, height: 36)
            } else {
                Text(store.clips.count > 99 ? "99+" : "\(store.clips.count)")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { ShelfMoveHandle(shelf: app.shelf) }
        .help(store.latestID != nil ? "Clip saved · Pull inward to use it" : "\(store.clips.count) clips · Click or pull inward to open")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.latestID != nil ? "Clip saved" : "Shelf, \(store.clips.count) clips")
    }
    private var dockingContent: some View {
        ZStack {
            // Keep the collection mounted so pulling away preserves selection and scroll position.
            expandedShelf
                .opacity(app.shelf.snapEdge == nil ? 1 : 0)
                .allowsHitTesting(app.shelf.snapEdge == nil)
                .accessibilityHidden(app.shelf.snapEdge != nil)
            if let edge = app.shelf.snapEdge {
                Image(systemName: edge == "left" ? "chevron.right" : "chevron.left")
                    .font(.system(size: 52, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == "left" ? .trailing : .leading)
                    .padding(.horizontal, 26)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Release to tuck shelf to the \(edge) edge")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: app.shelf.snapEdge)
    }
    private var expandedShelf: some View {
        VStack(spacing: 0) {
            ShelfHeader(app: app)
            if let pending = store.pendingImage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Unsaved clip").font(.caption)
                    Spacer()
                    Button("Retry") { store.retryPending() }
                    Button("Export…") { app.exportPending() }
                }.font(.caption).padding(10).background(Color.orange.opacity(0.12))
                    .accessibilityValue("\(pending.width) by \(pending.height) pixels")
            }
            if !store.visibleClips.isEmpty || (!store.isSearching && store.currentFolderID == nil && !store.folders.isEmpty) { grid }
            else { emptyState }
            Divider().padding(.horizontal, 14)
            ShelfFooter(app: app)
        }
    }
    private var emptyState: some View {
        Group {
            if store.isSearching { ContentUnavailableView.search(text: store.searchText) }
            else {
                ContentUnavailableView {
                    Label(store.currentFolderID == nil ? "Keep inspiration close" : "This group is empty",
                          systemImage: "square.on.square.dashed")
                } description: {
                    Text(store.currentFolderID == nil
                         ? "Capture a detail, or drop an image here."
                         : "Capture, paste, or drop images into this group.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var grid: some View {
        ShelfCollection(app: app)
            .help("Drag from empty space to select multiple clips. Press Delete to remove them; Command–Z restores them.")
    }
}

struct ShelfFolderDropDelegate: DropDelegate {
    let app: AppController
    let folderID: UUID?
    func validateDrop(info: DropInfo) -> Bool {
        !app.store.isReadOnly && (!app.isDraggingClips || !app.draggedClipIDs.isEmpty)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: app.isDraggingClips ? .move : .copy) }
    func performDrop(info: DropInfo) -> Bool {
        return app.dropIntoFolder(info.itemProviders(for: ShelfDropDelegate.types), folderID: folderID)
    }
}

struct ShelfDropDelegate: DropDelegate {
    static let types = [UTType.fileURL.identifier, UTType.png.identifier, UTType.tiff.identifier, UTType.image.identifier]
    let app: AppController
    func validateDrop(info: DropInfo) -> Bool { !app.isDraggingClips }
    func dropEntered(info: DropInfo) {
        guard !app.isDraggingClips else { return }
        app.shelf.dropTargeted = true; app.shelf.dropHover(true)
    }
    func dropExited(info: DropInfo) {
        app.shelf.dropTargeted = false; app.shelf.dropHover(false)
    }
    func performDrop(info: DropInfo) -> Bool {
        app.shelf.dropTargeted = false
        return app.acceptDrop(info.itemProviders(for: Self.types), folderID: app.store.currentFolderID)
    }
}

struct ImageBackdrop: View {
    let style: Int
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Canvas { context, size in
            let light = style == 1 || (style == 0 && colorScheme == .light)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: light ? 0.96 : 0.16)))
            if style == 0 {
                let square: CGFloat = 10
                for y in 0...Int(size.height / square) {
                    for x in 0...Int(size.width / square) where (x + y) % 2 == 0 {
                        context.fill(Path(CGRect(x: CGFloat(x) * square, y: CGFloat(y) * square, width: square, height: square)), with: .color(Color(white: light ? 0.92 : 0.20)))
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @Bindable var app: AppController
    var body: some View {
        Form {
            Section("Capture") {
                ForEach(AppShortcut.allCases.filter { $0 != .references }, id: \.self) { shortcut in
                    LabeledContent(shortcut.title) {
                        ShortcutRecorder(app: app, shortcut: shortcut).frame(width: 145, height: 32)
                    }
                }
                Text("Works from any app. Record a single key or any modifier combination. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = app.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Appearance") {
                Picker("Preview background", selection: $app.backdrop) {
                    Text("Checkerboard").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }
            }
            Section("Reference Windows") {
                LabeledContent("Show / hide all") {
                    ShortcutRecorder(app: app, shortcut: .references).frame(width: 145, height: 32)
                }
                Text("Works while you are using another app.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                HStack {
                    Text("Clips are saved on this Mac.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(app.store.root) }
                }
                Button("Recently Deleted…", action: app.showRecentlyDeleted)
                HStack {
                    Button("Back Up Library…", action: app.backupLibrary)
                        .disabled(app.busy || app.store.isReadOnly || app.store.pendingImage != nil)
                    Button("Restore Library…", action: app.restoreLibrary)
                        .disabled(app.busy || app.store.transferringLibrary || app.store.pendingImage != nil)
                }
                if app.store.transferringLibrary { ProgressView("Transferring library…").controlSize(.small) }
            }
        }.formStyle(.grouped)
    }
}
struct ShortcutRecorder: NSViewRepresentable {
    let app: AppController
    var shortcut: AppShortcut = .capture
    func makeNSView(context: Context) -> RecorderView { RecorderView(app: app, shortcut: shortcut) }
    func updateNSView(_ view: RecorderView, context: Context) { _ = app.shortcutLabel(for: shortcut); view.updateTitle() }
    final class RecorderView: NSButton {
        let app: AppController
        let shortcut: AppShortcut
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        init(app: AppController, shortcut: AppShortcut = .capture) {
            self.app = app; self.shortcut = shortcut; super.init(frame: .zero)
            bezelStyle = .rounded
            target = self; action = #selector(beginRecording)
            setAccessibilityLabel("Record \(shortcut.title.lowercased()) shortcut")
            updateTitle()
        }
        required init?(coder: NSCoder) { fatalError() }
        private var label: String { app.shortcutLabel(for: shortcut) }
        override func accessibilityValue() -> Any? { recording ? "Type a shortcut, or Escape to cancel" : label }
        func updateTitle() { title = recording ? "Type shortcut…" : label }
        @objc private func beginRecording() {
            app.shortcutError = nil
            window?.makeFirstResponder(self); recording = true; updateTitle()
        }
        override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
        override func resignFirstResponder() -> Bool { recording = false; updateTitle(); return super.resignFirstResponder() }
        override func keyDown(with event: NSEvent) {
            if !recording {
                if event.keyCode == 49 || event.keyCode == 36 { _ = accessibilityPerformPress() }
                else { super.keyDown(with: event) }
                return
            }
            let cancel = event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if !cancel { app.recordShortcut(event, for: shortcut) }
            finishRecording()
        }
        func recordRegisteredShortcut(_ source: AppShortcut) {
            let binding = app.shortcutBinding(for: source)
            app.registerShortcut(code: binding.code, modifiers: binding.modifiers, label: binding.label, for: shortcut)
            finishRecording()
        }
        private func finishRecording() { recording = false; window?.makeFirstResponder(nil); updateTitle() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording { keyDown(with: event); return true }; return false
        }
    }
}
struct AboutView: View {
    var body: some View {
        VStack(spacing: 13) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 76, height: 76)
            Text("SnipShelf").font(.system(size: 25, weight: .semibold))
            Text("Keep the part you love.").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Free & open source")
                .font(.caption).padding(.top, 8)
            Text("Made for your creative flow.\nMIT License · On-device by design.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
