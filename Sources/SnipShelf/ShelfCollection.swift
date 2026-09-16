import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit supplies native marquee selection, modifier selection, keyboard navigation and dragging.
struct ShelfCollection: NSViewRepresentable {
    let app: AppController
    enum Entry: Equatable {
        case clip(Clip)
        case group(ShelfFolder, [Clip])
        var id: UUID {
            switch self { case .clip(let clip): clip.id; case .group(let folder, _): folder.id }
        }
        var clip: Clip? { if case .clip(let clip) = self { clip } else { nil } }
        var folder: ShelfFolder? { if case .group(let folder, _) = self { folder } else { nil } }
    }
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
        collection.registerForDraggedTypes(CollectionView.pasteboardTypes)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        scroll.documentView = collection
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? CollectionView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        let members = Dictionary(grouping: app.store.clips.reversed(), by: \.folderID)
        let groups: [Entry] = app.store.currentFolderID == nil
            ? app.store.folders.map { .group($0, members[$0.id] ?? []) } : []
        let entries = groups + app.store.visibleClips.map(Entry.clip)
        if coordinator.entries != entries {
            coordinator.entries = entries
            collection.reloadData()
        }
        let indexes = Set(entries.enumerated().compactMap { index, entry in
            app.store.selectedIDs.contains(entry.id) || app.store.selectedFolderID == entry.id ? IndexPath(item: index, section: 0) : nil
        })
        if collection.selectionIndexPaths != indexes {
            collection.selectionIndexPaths = indexes
            if indexes.count == 1 { collection.scrollToItems(at: indexes, scrollPosition: .nearestVerticalEdge) }
        }
        for item in collection.visibleItems() {
            if let item = item as? Item, let index = collection.indexPath(for: item), entries.indices.contains(index.item) {
                item.configure(app: app, entry: entries[index.item])
            }
        }
    }
    final class Item: NSCollectionViewItem {
        override func loadView() { view = CardView() }
        override func prepareForReuse() {
            super.prepareForReuse()
            (view as? CardView)?.setHovered(false, animated: false)
        }
        override var isSelected: Bool { didSet { (view as? CardView)?.selected = isSelected } }
        func configure(app: AppController, entry: Entry) {
            guard let card = view as? CardView else { return }
            if card.folderID != entry.folder?.id { card.dropTargeted = false }
            card.folderID = entry.folder?.id
            card.selected = app.store.selectedIDs.contains(entry.id) || app.store.selectedFolderID == entry.id
            card.recent = entry.clip.map { app.store.latestID == $0.id } ?? false
            card.openGroup = nil
            card.more.isHidden = true
            card.more.stringValue = ""
            card.related.forEach { $0.isHidden = true; $0.image = nil }
            card.setAccessibilityElement(entry.folder != nil)
            switch entry {
            case .clip(let clip):
                card.picture.image = app.store.thumbnail(for: clip)
                card.caption.stringValue = clip.name
                card.toolTip = "\(clip.name) · \(clip.width) × \(clip.height) · Double-click or Space to preview"
                card.setAccessibilityLabel(clip.name)
            case .group(let folder, let clips):
                card.picture.image = clips.first.flatMap { app.store.thumbnail(for: $0) }
                    ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: "Empty group")
                for (index, clip) in clips.dropFirst().prefix(2).enumerated() {
                    card.related[index].image = app.store.thumbnail(for: clip)
                    card.related[index].isHidden = false
                }
                card.more.isHidden = clips.count <= 3
                card.more.stringValue = clips.count > 3 ? "+\(clips.count - 3)" : ""
                card.caption.stringValue = folder.name
                card.toolTip = "\(folder.name) · \(clips.count) clips · Click to open or drop clips here"
                card.setAccessibilityRole(.button)
                card.setAccessibilityLabel("\(folder.name), group, \(clips.count) clips")
                card.openGroup = { [weak app] in app?.openFolder(folder.id) }
            }
            card.needsLayout = true
            card.needsDisplay = true
        }
    }
    final class CardView: NSView {
        let picture = NSImageView()
        let caption = NSTextField(labelWithString: "")
        let related = [NSImageView(), NSImageView()]
        let relatedFrames = [ThumbnailFrame(), ThumbnailFrame()]
        let more = NSTextField(labelWithString: "")
        private var tracking: NSTrackingArea?
        private(set) var hovered = false
        var folderID: UUID?
        var openGroup: (() -> Void)?
        var dropTargeted = false { didSet { needsDisplay = true } }
        var selected = false { didSet { needsDisplay = true } }
        var recent = false { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            picture.imageScaling = .scaleProportionallyUpOrDown
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .labelColor
            caption.alignment = .center
            caption.lineBreakMode = .byTruncatingMiddle
            addSubview(picture); addSubview(caption)
            for (image, frame) in zip(related, relatedFrames) {
                image.imageScaling = .scaleProportionallyUpOrDown
                image.isHidden = true
                frame.addSubview(image)
                addSubview(frame)
            }
            for preview in [picture] + relatedFrames {
                preview.wantsLayer = true
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                preview.shadow = shadow
            }
            more.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            more.textColor = .secondaryLabelColor
            more.alignment = .center
            more.isHidden = true
            addSubview(more)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
            addTrackingArea(tracking!)
            super.updateTrackingAreas()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setHovered(false, animated: false) }
        }
        override func resetCursorRects() {
            if folderID != nil { addCursorRect(bounds, cursor: .pointingHand) }
        }
        override func mouseEntered(with event: NSEvent) { setHovered(true) }
        override func mouseExited(with event: NSEvent) { setHovered(false) }
        func setHovered(_ value: Bool, animated: Bool = true) {
            guard hovered != value else { return }
            hovered = value
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.22 : 0
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
                context.allowsImplicitAnimation = context.duration > 0
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
            needsDisplay = true
        }
        override func layout() {
            super.layout()
            if folderID != nil {
                picture.frame = CGRect(x: bounds.midX - 63 - (hovered ? 1 : 0), y: hovered ? 2 : 5, width: 82, height: 115)
                for (index, frame) in relatedFrames.enumerated() {
                    frame.frame = CGRect(x: bounds.midX + 23 + (hovered ? 2 : 0),
                                         y: 11 + CGFloat(index) * 53 + (hovered ? (index == 0 ? -2 : 2) : 0), width: 40, height: 46)
                    related[index].frame = frame.bounds.insetBy(dx: 3, dy: 3)
                }
                more.frame = CGRect(x: bounds.midX + 23, y: 114, width: 40, height: 15)
            } else {
                picture.frame = CGRect(x: 10, y: 10, width: max(1, bounds.width - 20), height: 106)
            }
            for (image, frame) in zip(related, relatedFrames) { frame.isHidden = image.isHidden }
            caption.frame = CGRect(x: 6, y: 132, width: max(1, bounds.width - 12), height: 18)
        }
        override func draw(_ dirtyRect: NSRect) {
            if hovered {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15).fill()
            }
            if selected || dropTargeted {
                NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15).fill()
            }
            if selected || recent || dropTargeted {
                NSColor.controlAccentColor.setStroke()
                let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
                border.lineWidth = 1.5; border.stroke()
            }
        }
        override func accessibilityPerformPress() -> Bool {
            guard let openGroup else { return false }
            openGroup(); return true
        }
    }
    final class ThumbnailFrame: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 0.75
            border.stroke()
        }
    }
    final class CollectionView: NSCollectionView {
        static let pasteboardTypes = (ShelfDropDelegate.types + [UTType.jpeg.identifier, UTType.heic.identifier, UTType.webP.identifier])
            .map { NSPasteboard.PasteboardType($0) }
        weak var app: AppController?
        private var dropFolderID: UUID? {
            didSet {
                for case let item as Item in visibleItems() {
                    guard let card = item.view as? CardView else { continue }
                    card.dropTargeted = card.folderID != nil && card.folderID == dropFolderID
                }
            }
        }
        private func entry(at point: NSPoint) -> Entry? {
            guard let index = indexPathForItem(at: point), let coordinator = dataSource as? Coordinator,
                  coordinator.entries.indices.contains(index.item) else { return nil }
            return coordinator.entries[index.item]
        }
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
            if let entry = entry(at: convert(event.locationInWindow, from: nil)), let app {
                if let folder = entry.folder, event.modifierFlags.intersection([.command, .shift]).isEmpty {
                    app.openFolder(folder.id); return
                }
                if event.clickCount == 2, let clip = entry.clip { app.previewClip = clip; return }
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
            guard let entry = entry(at: convert(event.locationInWindow, from: nil)), let app else { return nil }
            if let folder = entry.folder { return app.folderMenu(folder) }
            return entry.clip.map(app.clipMenu)
        }
        private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let app, !app.store.isReadOnly else { dropFolderID = nil; return [] }
            dropFolderID = entry(at: convert(sender.draggingLocation, from: nil))?.folder?.id
            if app.isDraggingClips { return dropFolderID != nil && !app.draggedClipIDs.isEmpty ? .move : [] }
            return sender.draggingPasteboard.availableType(from: Self.pasteboardTypes) != nil ? .copy : []
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { dropFolderID = nil }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropOperation(sender) != [] }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { dropFolderID = nil }
            guard dropOperation(sender) != [], let app else { return false }
            let folderID = dropFolderID ?? app.store.currentFolderID
            if app.isDraggingClips { return app.dropIntoFolder([], folderID: folderID) }
            let providers = (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item -> NSItemProvider? in
                guard let type = item.availableType(from: Self.pasteboardTypes), let data = item.data(forType: type) else { return nil }
                return NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
            }
            return !providers.isEmpty && app.dropIntoFolder(providers, folderID: folderID)
        }
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let app: AppController
        var entries: [Entry] = []
        var updating = false
        init(app: AppController) { self.app = app }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("clip"), for: indexPath) as! Item
            item.configure(app: app, entry: entries[indexPath.item])
            return item
        }
        private func updateSelection(_ collection: NSCollectionView) {
            guard !updating else { return }
            let selected = collection.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item] : nil }
            if selected.count == 1, let folder = selected.first?.folder { app.store.selection = folder.id }
            else { app.store.selectedIDs = Set(selected.compactMap { $0.clip?.id }) }
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateSelection(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateSelection(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            app.isDraggingClips = true
            app.draggedClipIDs = Set(indexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item].clip?.id : nil })
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            app.isDraggingClips = false
            app.draggedClipIDs = []
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let clip = entries[indexPath.item].clip else { return nil }
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
