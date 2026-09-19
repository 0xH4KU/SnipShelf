import AppKit
import SwiftUI
import PaletteKit

struct PreviewView: View {
    @Bindable var app: AppController
    var body: some View {
        if let clip = app.previewClip, let palette = app.previewPalette {
            PreviewContent(app: app, clip: clip, palette: palette).id(clip.id)
        }
    }
}

private struct PreviewContent: View {
    @Bindable var app: AppController
    let clip: Clip
    let palette: PaletteModel
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var actualSize = false
    @State private var zoomReset = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ControlGroup {
                    Button("Previous Clip", systemImage: "chevron.left") { app.movePreview(-1) }
                        .buttonHover()
                        .disabled(app.adjacentPreview(-1) == nil).help("Previous clip (←)")
                    Button("Next Clip", systemImage: "chevron.right") { app.movePreview(1) }
                        .buttonHover()
                        .disabled(app.adjacentPreview(1) == nil).help("Next clip (→)")
                }.labelStyle(.iconOnly).fixedSize()
                if let index = app.previewClips.firstIndex(where: { $0.id == clip.id }) {
                    Text("\(index + 1) of \(app.previewClips.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer()
                Button { app.openReference(.clip(clip.id)) } label: {
                    Label { Text("Floating Reference") } icon: {
                        Image(nsImage: ReferencePinButton.icon).resizable().frame(width: 15, height: 15)
                    }
                }
                    .labelStyle(.iconOnly)
                    .buttonHover()
                    .help("Keep this image in a separate reference window (⇧⌘P)")
                Menu("Image Actions", systemImage: "ellipsis") {
                    Button("Rename Image…", systemImage: "pencil") { app.renameClip(clip) }
                        .disabled(app.store.isReadOnly)
                    Button("Crop a Copy…", systemImage: "crop") { app.previewClip = nil; app.recrop(clip) }
                    Button("Export PNG…", systemImage: "square.and.arrow.up") { app.export(clip) }
                }.labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize().buttonHover().help("Image actions")
            }.buttonStyle(.bordered).controlSize(.small).padding(10)
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
            ClipPaletteView(palette: palette, backdrop: app.backdrop)
            Divider()
            ClipImageControls(app: app, clip: clip, backdrop: $app.backdrop, actualSize: $actualSize, zoomReset: $zoomReset)
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
    var app: AppController? = nil
    var clip: Clip? = nil
    func makeNSView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.contentView = CenteredClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.00001; scroll.maxMagnification = 16
        let picture = ReferenceImageView()
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setAccessibilityLabel("Clip preview. Pinch to zoom and scroll to pan.")
        scroll.documentView = picture
        return scroll
    }
    func updateNSView(_ scroll: ImageScrollView, context: Context) {
        if let picture = scroll.documentView as? ReferenceImageView {
            picture.image = image; picture.app = app; picture.clip = clip
            if let clip { picture.setAccessibilityLabel("\(clip.name). Pinch to zoom, Space-drag to pan, or drag to copy to another app.") }
        }
        scroll.spacePans = clip != nil
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
        var spacePans = false
        private(set) var spaceDown = false
        private var panStart: CGPoint?
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
            if spacePans, event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                spaceDown = true; return
            }
            if handleZoomKey(event) { return }
            if onKey?(event) != true { super.keyDown(with: event) }
        }
        override func keyUp(with event: NSEvent) {
            if event.keyCode == 49 { spaceDown = false; endPan() }
            else { super.keyUp(with: event) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handleZoomKey(event) || super.performKeyEquivalent(with: event)
        }
        private func handleZoomKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command), !(window?.firstResponder is NSTextView) else { return false }
            switch event.charactersIgnoringModifiers {
            case "0", "1":
                fitsWindow = event.charactersIgnoringModifiers == "0"
                needsZoomReset = true; needsLayout = true
            case "+", "=", "-":
                fitsWindow = false
                let amount: CGFloat = event.charactersIgnoringModifiers == "-" ? 1 / 1.25 : 1.25
                setMagnification(min(maxMagnification, max(minMagnification, magnification * amount)),
                                 centeredAt: CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
            default: return false
            }
            return true
        }
        func beginPan(_ event: NSEvent) { panStart = event.locationInWindow }
        @discardableResult func pan(_ event: NSEvent) -> Bool {
            guard let start = panStart else { return false }
            let point = event.locationInWindow, origin = contentView.bounds.origin
            contentView.scroll(to: CGPoint(x: origin.x - (point.x - start.x) / magnification,
                                          y: origin.y - (point.y - start.y) / magnification))
            reflectScrolledClipView(contentView); panStart = point
            return true
        }
        func endPan() { panStart = nil }
    }
}
