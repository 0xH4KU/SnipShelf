import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Bindable var app: AppController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24))
            .overlay {
                RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24)
                    .strokeBorder(app.shelf.dropTargeted ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08),
                                  lineWidth: app.shelf.dropTargeted ? 2 : 0.5)
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
            header
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
            if store.clips.isEmpty { emptyState }
            else { grid }
            footer
        }
    }
    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                Capsule().fill(.secondary.opacity(0.3)).frame(width: 28, height: 4)
                ShelfMoveHandle(shelf: app.shelf)
            }.frame(height: 18)
            HStack(spacing: 10) {
                Text("SnipShelf").font(.headline)
                Spacer(minLength: 4)
                Button { app.capture() } label: { Image(systemName: "lasso").frame(width: 24, height: 24) }
                    .buttonStyle(.borderedProminent).help("Capture element (\(app.shortcutLabel))")
                    .accessibilityLabel("Capture element").disabled(app.busy)
                Button { app.chooseImages() } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .help("Import images (⌘O)").accessibilityLabel("Import images").disabled(app.busy)
                Button { app.shelf.collapse() } label: {
                    Image(systemName: app.shelf.edge == "left" ? "sidebar.left" : "sidebar.right").frame(width: 24, height: 24)
                }.help("Tuck shelf to edge").accessibilityLabel("Collapse shelf")
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.bottom, 12)
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.on.square.dashed").font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary).padding(.bottom, 4)
            Text("Your Shelf").font(.title3.weight(.semibold))
            Text("Capture an element, or drop an image\nhere to keep it within reach.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Capture", systemImage: "lasso") { app.capture() }
                .buttonStyle(.borderedProminent).padding(.top, 4).disabled(app.busy)
            Text(app.shortcutLabel).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }
    private var grid: some View {
        ShelfCollection(app: app)
            .help("Drag from empty space to select multiple clips. Press Delete to remove them; Command–Z restores them.")
    }
    private var footer: some View {
        HStack(spacing: 9) {
            if app.busy { ProgressView().controlSize(.mini) }
            Text(app.status ?? (store.latestID != nil ? "Clip saved" : nil) ?? (store.selectedIDs.isEmpty ? "\(store.clips.count) clips" : "\(store.selectedIDs.count) selected"))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if let clip = store.selectedClip {
                Button { app.copy(clip) } label: { Image(systemName: "doc.on.doc").frame(width: 22, height: 22) }
                    .help("Copy image (⌘C)").accessibilityLabel("Copy image")
            }
            if !store.selectedIDs.isEmpty {
                Button { store.delete(store.selectedIDs) } label: { Image(systemName: "trash") }
                    .help("Delete selected clips").accessibilityLabel("Delete selected clips")
            }
            if !store.undoHistory.isEmpty {
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo deletion (⌘Z)").accessibilityLabel("Undo deletion")
            }
            Menu {
                Button("Paste Image") { app.paste() }
                Button("Clear Shelf…", role: .destructive) { app.clearShelf() }.disabled(store.clips.isEmpty)
                Divider()
                Button("Settings…") { app.showSettings() }
                Button("About SnipShelf") { app.showAbout() }
                Button("Quit SnipShelf") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 16) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Shelf options").accessibilityLabel("Shelf options")
        }.buttonStyle(.borderless).padding(.horizontal, 17).padding(.vertical, 12)
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
        return app.acceptDrop(info.itemProviders(for: Self.types))
    }
}

struct ImageBackdrop: View {
    let style: Int
    var body: some View {
        Canvas { context, size in
            let light = style != 2
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: light ? 0.94 : 0.17)))
            if style == 0 {
                let square: CGFloat = 10
                for y in 0...Int(size.height / square) {
                    for x in 0...Int(size.width / square) where (x + y) % 2 == 0 {
                        context.fill(Path(CGRect(x: CGFloat(x) * square, y: CGFloat(y) * square, width: square, height: square)), with: .color(Color(white: 0.88)))
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
                HStack {
                    Text("Keyboard shortcut")
                    Spacer()
                    ShortcutRecorder(app: app).frame(width: 145, height: 32)
                }
                Text("Click the shortcut to record. Include Command or Control.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Preview background", selection: $app.backdrop) {
                    Text("Checkerboard").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }
            }
            Section("Storage") {
                HStack {
                    Text("Clips are saved on this Mac.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(app.store.root) }
                }
            }
        }.formStyle(.grouped)
    }
}
struct ShortcutRecorder: NSViewRepresentable {
    let app: AppController
    func makeNSView(context: Context) -> RecorderView { RecorderView(app: app) }
    func updateNSView(_ view: RecorderView, context: Context) { _ = app.shortcutLabel; view.needsDisplay = true }
    final class RecorderView: NSView {
        let app: AppController
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        init(app: AppController) {
            self.app = app; super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Record capture shortcut")
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            let text = recording ? "Type shortcut…" : app.shortcutLabel
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: max(3, (bounds.width - size.width) / 2), y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
        override func mouseDown(with event: NSEvent) { recording = true; window?.makeFirstResponder(self); needsDisplay = true }
        override func accessibilityPerformPress() -> Bool { recording = true; window?.makeFirstResponder(self); needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { recording = false; needsDisplay = true; return true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode != 53 { app.recordShortcut(event) }
            recording = false; window?.makeFirstResponder(nil); needsDisplay = true
        }
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
