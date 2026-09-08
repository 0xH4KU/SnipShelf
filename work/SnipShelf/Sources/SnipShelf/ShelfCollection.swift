import AppKit
import SwiftUI

/// AppKit supplies native marquee selection, modifier selection, keyboard navigation and dragging.
struct ShelfCollection: NSViewRepresentable {
    let app: AppController
    func makeCoordinator() -> Coordinator { Coordinator(app: app) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let collection = CollectionView()
        collection.app = app
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 5, left: 13, bottom: 12, right: 13)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.register(Item.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("clip"))
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        scroll.documentView = collection
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? CollectionView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        if coordinator.clips != app.store.clips {
            coordinator.clips = app.store.clips
            collection.reloadData()
        }
        let indexes = Set(coordinator.clips.enumerated().compactMap { index, clip in
            app.store.selectedIDs.contains(clip.id) ? IndexPath(item: index, section: 0) : nil
        })
        if collection.selectionIndexPaths != indexes {
            collection.selectionIndexPaths = indexes
            if indexes.count == 1 { collection.scrollToItems(at: indexes, scrollPosition: .nearestVerticalEdge) }
        }
        for item in collection.visibleItems() {
            if let item = item as? Item, let index = collection.indexPath(for: item), coordinator.clips.indices.contains(index.item) {
                item.configure(app: app, clip: coordinator.clips[index.item])
            }
        }
    }
    final class Item: NSCollectionViewItem {
        override func loadView() { view = CardView() }
        override var isSelected: Bool { didSet { (view as? CardView)?.selected = isSelected } }
        func configure(app: AppController, clip: Clip) {
            guard let card = view as? CardView else { return }
            card.picture.image = app.store.thumbnail(for: clip)
            card.caption.stringValue = clip.name
            card.style = app.backdrop
            card.selected = app.store.selectedIDs.contains(clip.id)
            card.recent = app.store.latestID == clip.id
            card.toolTip = "\(clip.name) · \(clip.width) × \(clip.height) · Double-click or Space to preview"
            card.setAccessibilityLabel(clip.name)
        }
    }
    final class CardView: NSView {
        let picture = NSImageView()
        let caption = NSTextField(labelWithString: "")
        var style = 0 { didSet { needsDisplay = true } }
        var selected = false { didSet { needsDisplay = true } }
        var recent = false { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            picture.imageScaling = .scaleProportionallyUpOrDown
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .secondaryLabelColor
            caption.lineBreakMode = .byTruncatingMiddle
            addSubview(picture); addSubview(caption)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            picture.frame = CGRect(x: 16, y: 16, width: max(1, bounds.width - 32), height: 96)
            caption.frame = CGRect(x: 6, y: 129, width: max(1, bounds.width - 12), height: 18)
        }
        override func draw(_ dirtyRect: NSRect) {
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15).fill()
            }
            if selected || recent {
                NSColor.controlAccentColor.setStroke()
                let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
                border.lineWidth = 1.5; border.stroke()
            }
            NSGraphicsContext.saveGraphicsState()
            let well = CGRect(x: 3, y: 3, width: max(1, bounds.width - 6), height: 122)
            NSBezierPath(roundedRect: well, xRadius: 12, yRadius: 12).addClip()
            NSColor(calibratedWhite: style == 2 ? 0.17 : 0.94, alpha: 1).setFill(); well.fill()
            if style == 0 {
                NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
                for y in 0...12 { for x in 0...Int(well.width / 10) where (x + y) % 2 == 0 {
                    CGRect(x: 3 + x * 10, y: 3 + y * 10, width: 10, height: 10).fill()
                } }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    final class CollectionView: NSCollectionView {
        weak var app: AppController?
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func layout() {
            if let layout = collectionViewLayout as? NSCollectionViewFlowLayout {
                let available = enclosingScrollView?.contentSize.width ?? bounds.width
                let size = NSSize(width: max(110, floor((available - 36) / 2)), height: 153)
                if layout.itemSize != size { layout.itemSize = size }
            }
            super.layout()
        }
        override func mouseDown(with event: NSEvent) {
            window?.makeKey(); window?.makeFirstResponder(self)
            if event.clickCount == 2, let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)),
               let app, app.store.clips.indices.contains(index.item) {
                app.previewClip = app.store.clips[index.item]
                return
            }
            super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if app?.handleKey(event) != true { super.keyDown(with: event) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command), app?.handleKey(event) == true { return true }
            return super.performKeyEquivalent(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)),
                  let app, app.store.clips.indices.contains(index.item) else { return nil }
            return app.clipMenu(app.store.clips[index.item])
        }
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let app: AppController
        var clips: [Clip] = []
        var updating = false
        init(app: AppController) { self.app = app }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { clips.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("clip"), for: indexPath) as! Item
            item.configure(app: app, clip: clips[indexPath.item])
            return item
        }
        private func updateSelection(_ collection: NSCollectionView) {
            guard !updating else { return }
            app.store.selectedIDs = Set(collection.selectionIndexPaths.compactMap { clips.indices.contains($0.item) ? clips[$0.item].id : nil })
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateSelection(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateSelection(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let clip = clips[indexPath.item]
            do {
                let url = app.store.url(for: clip)
                let writer = NSPasteboardItem()
                writer.setString(url.absoluteString, forType: .fileURL)
                writer.setData(try Data(contentsOf: url), forType: .png)
                return writer
            } catch { app.store.message = error.localizedDescription; return nil }
        }
    }
}
