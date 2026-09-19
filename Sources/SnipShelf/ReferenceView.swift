import AppKit
import SwiftUI
import PaletteKit

struct ReferenceView: View {
    let app: AppController
    let target: ReferenceTarget

    var body: some View {
        Group {
            switch target {
            case .group(let id):
                VStack(spacing: 0) {
                    if app.store.clips.contains(where: { $0.folderID == id }) {
                        ShelfCollection(app: app, referenceFolderID: id)
                    } else {
                        ContentUnavailableView("This group is empty", systemImage: "square.dashed", description: Text("Drop images here to collect references."))
                        // Keep the native drop target mounted for an empty group, too.
                            .overlay { ShelfCollection(app: app, referenceFolderID: id) }
                    }
                    HStack {
                        Text("\(app.store.clips.filter { $0.folderID == id }.count) clips")
                        Spacer()
                        Label { Text("Double-click for reference") } icon: { Image(nsImage: ReferencePinButton.icon) }
                    }.font(.caption).foregroundStyle(.secondary).padding(12).background(.bar)
                }
            case .clip(let id):
                if let clip = app.store.clips.first(where: { $0.id == id }), let palette = app.referencePalettes[id] {
                    PinnedClipView(app: app, clip: clip, palette: palette)
                }
            }
        }
        .background(.regularMaterial)
    }
}

private struct PinnedClipView: View {
    let app: AppController
    let clip: Clip
    let palette: PaletteModel
    @AppStorage private var backdrop: Int
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var actualSize = false
    @State private var zoomReset = 0

    init(app: AppController, clip: Clip, palette: PaletteModel) {
        self.app = app
        self.clip = clip
        self.palette = palette
        _backdrop = AppStorage(wrappedValue: app.backdrop, ReferenceTarget.clip(clip.id).backgroundKey, store: app.defaults)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ImageBackdrop(style: backdrop)
                if let failure { ContentUnavailableView("Unable to Open Image", systemImage: "photo.badge.exclamationmark", description: Text(failure)) }
                else if let preview = image ?? app.store.thumbnail(for: clip) {
                    PreviewImage(image: preview, actualSize: actualSize, reset: zoomReset,
                                 onKey: { app.handleReferenceKey($0, target: .clip(clip.id)) }, app: app, clip: clip)
                        .contextMenu {
                            Button("Preview", systemImage: "eye") { app.previewClip = clip }
                            Button("Rename Image…", systemImage: "pencil") { app.renameClip(clip) }
                                .disabled(app.store.isReadOnly)
                            Button("Copy Image", systemImage: "doc.on.doc") { app.copy(clip) }
                            Button("Export PNG…", systemImage: "square.and.arrow.up") { app.export(clip) }
                        }
                }
                else { ProgressView().controlSize(.small) }
            }.clipped()
            ClipPaletteView(palette: palette, backdrop: backdrop)
            Divider()
            ClipImageControls(app: app, clip: clip, backdrop: $backdrop, actualSize: $actualSize, zoomReset: $zoomReset)
                .help("\(clip.width) × \(clip.height) px · Pinch to zoom · Space-drag to pan · Drag the image to export")
        }
        .task(id: clip.id) {
            let url = app.store.url(for: clip)
            do {
                let cg = try await Task.detached(priority: .userInitiated) { try ImageCore.load(url) }.value
                guard !Task.isCancelled else { return }
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}

/// Native dragging keeps file/PNG export and internal group moves on the same path.
final class ReferenceImageView: NSImageView, NSDraggingSource {
    weak var app: AppController?
    var clip: Clip?
    private var mouseStart: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        if let scroll = enclosingScrollView as? PreviewImage.ImageScrollView, scroll.spaceDown {
            mouseStart = nil; scroll.beginPan(event); return
        }
        mouseStart = event.locationInWindow
    }
    override func mouseUp(with event: NSEvent) {
        mouseStart = nil
        (enclosingScrollView as? PreviewImage.ImageScrollView)?.endPan()
    }
    override func mouseDragged(with event: NSEvent) {
        if let scroll = enclosingScrollView as? PreviewImage.ImageScrollView, scroll.pan(event) { return }
        guard let start = mouseStart, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4,
              let app, let clip, let image, let writer = app.clipPasteboardItem(clip) else { return }
        mouseStart = nil
        let item = NSDraggingItem(pasteboardWriter: writer)
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        item.setDraggingFrame(CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : .copy
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        app?.isDraggingClips = true
        app?.draggedClipIDs = clip.map { [$0.id] } ?? []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        app?.isDraggingClips = false; app?.draggedClipIDs = []
    }
}
