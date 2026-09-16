import AppKit
import SwiftUI

struct PreviewView: View {
    @Bindable var app: AppController
    var body: some View {
        if let clip = app.previewClip {
            PreviewContent(app: app, clip: clip).id(clip.id)
        }
    }
}

private struct PreviewContent: View {
    @Bindable var app: AppController
    let clip: Clip
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var actualSize = false
    @State private var zoomReset = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ControlGroup {
                    Button("Previous Clip", systemImage: "chevron.left") { app.movePreview(-1) }
                        .disabled(app.adjacentPreview(-1) == nil).help("Previous clip (←)")
                    Button("Next Clip", systemImage: "chevron.right") { app.movePreview(1) }
                        .disabled(app.adjacentPreview(1) == nil).help("Next clip (→)")
                }.labelStyle(.iconOnly).fixedSize()
                if let index = app.previewClips.firstIndex(where: { $0.id == clip.id }) {
                    Text("\(index + 1) of \(app.previewClips.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Pin", systemImage: "pin") { app.openReference(.clip(clip.id)) }
                    .help("Keep this image in a separate reference window (⇧⌘P)")
                Button(app.copiedClipID == clip.id ? "Copied" : "Copy",
                       systemImage: app.copiedClipID == clip.id ? "checkmark" : "doc.on.doc") { app.copy(clip) }
                    .buttonStyle(.borderedProminent).help("Copy image (⌘C)")
                    .accessibilityInputLabels(["Copy", "Copy Image"])
                Menu("Image Actions", systemImage: "ellipsis") {
                    Button("Rename Image…", systemImage: "pencil") { app.renameClip(clip) }
                        .disabled(app.store.isReadOnly)
                    Button("Crop a Copy…", systemImage: "crop") { app.previewClip = nil; app.recrop(clip) }
                    Button("Export PNG…", systemImage: "square.and.arrow.up") { app.export(clip) }
                }.labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize().help("Image actions")
            }.buttonStyle(.bordered).controlSize(.regular).padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            Divider()
            ZStack {
                ImageBackdrop(style: app.backdrop)
                if let image {
                    PreviewImage(image: image, actualSize: actualSize, reset: zoomReset, onKey: app.handlePreviewKey)
                } else if let failure {
                    ContentUnavailableView("Unable to Open Image", systemImage: "photo.badge.exclamationmark", description: Text(failure))
                } else { ProgressView().controlSize(.small) }
            }.clipped()
            Divider()
            HStack(spacing: 12) {
                Picker("Background", selection: $app.backdrop) {
                    Text("Checkerboard").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }.labelsHidden().pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                Spacer()
                ViewThatFits {
                    Text("\(clip.width) × \(clip.height) px").font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                ControlGroup {
                    Button("Fit") { actualSize = false; zoomReset += 1 }
                        .keyboardShortcut("0", modifiers: .command).help("Fit image to window (⌘0)")
                    Button("100%") { actualSize = true; zoomReset += 1 }
                        .keyboardShortcut("1", modifiers: .command).help("Show actual pixels (⌘1) · Pinch to zoom, scroll to pan")
                }.fixedSize()
            }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
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

/// NSScrollView supplies trackpad magnification, momentum scrolling and scroll bars.
struct PreviewImage: NSViewRepresentable {
    let image: NSImage
    let actualSize: Bool
    let reset: Int
    let onKey: (NSEvent) -> Bool
    func makeNSView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.contentView = CenteredClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.00001; scroll.maxMagnification = 16
        let picture = NSImageView()
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setAccessibilityLabel("Clip preview. Pinch to zoom and scroll to pan.")
        scroll.documentView = picture
        return scroll
    }
    func updateNSView(_ scroll: ImageScrollView, context: Context) {
        (scroll.documentView as? NSImageView)?.image = image
        scroll.onKey = onKey
        if scroll.lastReset != reset {
            scroll.lastReset = reset
            scroll.fitsWindow = !actualSize
            scroll.needsZoomReset = true
        }
        scroll.needsLayout = true
    }
    final class CenteredClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            if let documentView {
                if rect.width > documentView.frame.width { rect.origin.x = (documentView.frame.width - rect.width) / 2 }
                if rect.height > documentView.frame.height { rect.origin.y = (documentView.frame.height - rect.height) / 2 }
            }
            return rect
        }
    }
    final class ImageScrollView: NSScrollView {
        var onKey: ((NSEvent) -> Bool)?
        var lastReset = -1
        var fitsWindow = true
        var needsZoomReset = true
        private var previousSize = CGSize.zero
        override var acceptsFirstResponder: Bool { true }
        override func layout() {
            super.layout()
            guard let picture = documentView as? NSImageView, let image = picture.image else { return }
            let backing = window?.backingScaleFactor ?? 2
            let size = CGSize(width: image.size.width / backing, height: image.size.height / backing)
            if picture.frame.size != size { picture.setFrameSize(size); needsZoomReset = true }
            if needsZoomReset || (fitsWindow && previousSize != contentSize) {
                needsZoomReset = false; previousSize = contentSize
                let fit = min(max(1, contentSize.width - 40) / size.width, max(1, contentSize.height - 40) / size.height)
                setMagnification(fitsWindow ? min(maxMagnification, max(minMagnification, fit)) : 1,
                                 centeredAt: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        override func magnify(with event: NSEvent) { fitsWindow = false; super.magnify(with: event) }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }
}
