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
                else { expandedShelf }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear,
                        in: RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24))
            .overlay {
                RoundedRectangle(cornerRadius: app.shelf.collapsed ? 12 : 24)
                    .strokeBorder(app.shelf.snapEdge != nil || app.shelf.dropTargeted ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.12),
                                  lineWidth: app.shelf.snapEdge != nil || app.shelf.dropTargeted ? 2 : 0.5)
                    .allowsHitTesting(false)
            }
            .padding(app.shelf.collapsed ? 1 : 5)
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.png.identifier, UTType.tiff.identifier, UTType.image.identifier],
                isTargeted: Binding(get: { app.shelf.dropTargeted }, set: { app.shelf.dropTargeted = $0; app.shelf.dropHover($0) })) { app.acceptDrop($0) }
        .sheet(item: $app.previewClip, onDismiss: {
            if let clip = app.cropAfterPreview { app.cropAfterPreview = nil; app.recrop(clip) }
        }) { clip in PreviewView(app: app, clip: clip) }
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
            Image(systemName: app.shelf.edge == "right" ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
            Text(store.clips.count > 99 ? "99+" : "\(store.clips.count)")
                .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
            Circle().fill(store.latestID == nil ? Color.secondary.opacity(0.25) : Color.accentColor)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { ShelfMoveHandle(shelf: app.shelf) }
        .help("\(store.clips.count) clips · Click or pull inward to open")
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
        VStack(spacing: 9) {
            ZStack {
                Capsule().fill(.secondary.opacity(0.25)).frame(width: 30, height: 4)
                ShelfMoveHandle(shelf: app.shelf)
            }.frame(height: 16)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("SnipShelf").font(.system(size: 15, weight: .semibold))
                    Text(app.shelf.snapEdge.map { "Release to tuck \($0)" } ?? "A little space for your ideas")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { app.capture() } label: { Image(systemName: "lasso").frame(width: 24, height: 24) }
                    .buttonStyle(.glassProminent).help("Capture element (\(app.shortcutLabel))").accessibilityLabel("Capture element").disabled(app.busy)
                Button { app.chooseImages() } label: { Image(systemName: "plus").frame(width: 20, height: 24) }
                    .buttonStyle(.borderless).help("Import images").accessibilityLabel("Import images").disabled(app.busy)
                Button { app.shelf.collapse() } label: { Image(systemName: "sidebar.right").frame(width: 20, height: 24) }
                    .buttonStyle(.borderless).help("Tuck shelf to edge").accessibilityLabel("Collapse shelf")
            }.padding(.horizontal, 15).padding(.bottom, 13)
        }
    }
    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "square.on.square.dashed").font(.system(size: 37, weight: .ultraLight))
                .foregroundStyle(.secondary).padding(.bottom, 3)
            Text("Keep the part you love.").font(.system(size: 16, weight: .medium))
            Text("Circle an element on your screen,\nor drop an image here.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            Button("Capture an element") { app.capture() }.buttonStyle(.glass).padding(.top, 5).disabled(app.busy)
            Text(app.shortcutLabel).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }
    private var grid: some View {
        ShelfCollection(app: app)
            .help("Drag from empty space to select multiple clips. Press Delete to remove them; Command–Z restores them.")
    }
    private var footer: some View {
        HStack(spacing: 9) {
            if app.busy { ProgressView().controlSize(.mini) }
            Text(app.status ?? (store.selectedIDs.isEmpty ? "\(store.clips.count) clips" : "\(store.selectedIDs.count) selected"))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if !store.selectedIDs.isEmpty {
                Button { store.delete(store.selectedIDs) } label: { Image(systemName: "trash") }
                    .help("Delete selected clips").accessibilityLabel("Delete selected clips")
            }
            if !store.undoHistory.isEmpty {
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo deletion (⌘Z)").accessibilityLabel("Undo deletion")
            }
            Menu {
                Picker("Image background", selection: $app.backdrop) {
                    Text("Checkerboard").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }
                Divider()
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

struct PreviewView: View {
    @Bindable var app: AppController
    let clip: Clip
    @State private var image: NSImage?
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.name).font(.headline).lineLimit(1)
                    Text("\(clip.width) × \(clip.height) · PNG").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.previewClip = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close preview (Esc)").keyboardShortcut(.cancelAction)
            }
            ZStack {
                ImageBackdrop(style: app.backdrop)
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(20) }
                else if let failure { Text(failure).foregroundStyle(.secondary).padding() }
                else { ProgressView() }
            }.clipShape(RoundedRectangle(cornerRadius: 16))
            HStack {
                Picker("Background", selection: $app.backdrop) {
                    Text("Checker").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }.pickerStyle(.segmented).frame(width: 190)
                Spacer()
                Button("Crop a Copy") { app.cropAfterPreview = clip; app.previewClip = nil }
                Button("Export…") { app.export(clip) }
                Button("Copy") { app.copy(clip) }.buttonStyle(.glassProminent).keyboardShortcut("c", modifiers: .command)
            }.buttonStyle(.glass)
        }.padding(20).frame(width: 610, height: 500)
        .task {
            let url = app.store.url(for: clip)
            do {
                let cg = try await Task.detached { try ImageCore.load(url) }.value
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } catch { failure = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @Bindable var app: AppController
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Make it yours.").font(.system(size: 23, weight: .semibold))
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Capture shortcut").font(.headline)
                    Text("Click to record. Include ⌘ or ⌃.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ShortcutRecorder(app: app).frame(width: 145, height: 34)
            }
            Picker("Image background", selection: $app.backdrop) {
                Text("Checkerboard").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
            }
            Divider()
            HStack {
                Text("Clips stay on this Mac until you delete them.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Storage…") { NSWorkspace.shared.open(app.store.root) }
            }
            Text("No accounts. No uploads. Just your ideas.").font(.caption).foregroundStyle(.tertiary)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Image(systemName: "lasso").font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                .frame(width: 76, height: 76).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            Text("SnipShelf").font(.system(size: 25, weight: .semibold))
            Text("Keep the part you love.").foregroundStyle(.secondary)
            Text("Version 0.3.0 · Free & open source").font(.caption).padding(.top, 8)
            Text("Made for your creative flow.\nMIT License · On-device by design.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
