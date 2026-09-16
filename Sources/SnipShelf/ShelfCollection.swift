import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit supplies native marquee selection, modifier selection, keyboard navigation and dragging.
struct ShelfCollection: NSViewRepresentable {
    let app: AppController
    var referenceFolderID: UUID? = nil
    enum Entry: Equatable {
        case clip(Clip)
        case group(ShelfFolder, [Clip])
        var id: UUID {
            switch self { case .clip(let clip): clip.id; case .group(let folder, _): folder.id }
        }
        var clip: Clip? { if case .clip(let clip) = self { clip } else { nil } }
        var folder: ShelfFolder? { if case .group(let folder, _) = self { folder } else { nil } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(app: app, referenceFolderID: referenceFolderID) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        let clipView = ClipView()
        clipView.drawsBackground = false
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clipView)
        scroll.contentView = clipView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let collection = CollectionView()
        collection.app = app
        collection.referenceFolderID = referenceFolderID
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
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? CollectionView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer {
            coordinator.updating = false
            coordinator.rememberScroll(scroll.contentView)
        }
        let restorePosition = referenceFolderID == nil && (!coordinator.loaded || coordinator.restoringPosition || coordinator.displayedFolderID != app.store.currentFolderID)
        coordinator.displayedFolderID = app.store.currentFolderID
        let members = Dictionary(grouping: app.store.clips.reversed(), by: \.folderID)
        let groups: [Entry] = referenceFolderID == nil && app.store.currentFolderID == nil
            ? app.store.folders.map { .group($0, members[$0.id] ?? []) } : []
        let clips = referenceFolderID.map { id in app.store.clips.filter { $0.folderID == id } } ?? app.store.visibleClips
        let entries = groups + clips.map(Entry.clip)
        coordinator.selectedIDs.formIntersection(Set(entries.map(\.id)))
        if coordinator.entries != entries {
            coordinator.entries = entries
            collection.reloadData()
        }
        let selected = referenceFolderID == nil ? app.store.selectedIDs.union(app.store.selectedFolderID.map { [$0] } ?? []) : coordinator.selectedIDs
        let indexes = Set(entries.enumerated().compactMap { index, entry in
            selected.contains(entry.id) ? IndexPath(item: index, section: 0) : nil
        })
        if collection.selectionIndexPaths != indexes {
            collection.selectionIndexPaths = indexes
            if indexes.count == 1 && !restorePosition {
                collection.scrollToItems(at: indexes, scrollPosition: .nearestHorizontalEdge)
            }
        }
        if restorePosition {
            coordinator.restoringPosition = true
        }
        if restorePosition && !app.shelf.isAnimating {
            let folderID = app.store.currentFolderID
            let origin = app.store.browsingStates[folderID]?.scrollOrigin ?? .zero
            // A remounted collection receives its viewport size after updateNSView returns.
            DispatchQueue.main.async { [weak scroll, weak coordinator] in
                guard let scroll, let coordinator, coordinator.displayedFolderID == folderID else { return }
                defer { coordinator.restoringPosition = false }
                guard scroll.window != nil, app.store.currentFolderID == folderID, !app.shelf.collapsed else { return }
                collection.layoutSubtreeIfNeeded()
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        coordinator.loaded = true
        for item in collection.visibleItems() {
            if let item = item as? Item, let index = collection.indexPath(for: item), entries.indices.contains(index.item) {
                item.configure(app: app, entry: entries[index.item], selected: selected.contains(entries[index.item].id))
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
        func configure(app: AppController, entry: Entry, selected: Bool? = nil) {
            guard let card = view as? CardView else { return }
            if card.folderID != entry.folder?.id { card.dropTargeted = false }
            card.folderID = entry.folder?.id
            card.selected = selected ?? (app.store.selectedIDs.contains(entry.id) || app.store.selectedFolderID == entry.id)
            card.recent = entry.clip.map { app.store.latestID == $0.id } ?? false
            card.openGroup = nil
            card.more.isHidden = true
            card.more.stringValue = ""
            card.related.forEach { $0.isHidden = true; $0.image = nil }
            card.setAccessibilityElement(entry.folder != nil)
            card.pinButton.app = app
            card.pinButton.referenceTarget = entry.folder.map { .group($0.id) } ?? .clip(entry.id)
            let name = switch entry { case .clip(let clip): clip.name; case .group(let folder, _): folder.name }
            card.caption.font = .systemFont(ofSize: 11, weight: entry.folder == nil ? .regular : .medium)
            card.caption.toolTip = name
            let pinLabel = entry.folder != nil ? "Open \(name) in a reference window" : "Pin \(name) as a reference"
            card.pinButton.image = NSImage(systemSymbolName: entry.folder != nil ? "arrow.up.forward.square" : "pin", accessibilityDescription: pinLabel)
            card.pinButton.toolTip = pinLabel + " · Drag to place the window"
            card.pinButton.setAccessibilityLabel(pinLabel)
            card.pinButton.setAccessibilityHelp("Click to open, or drag to place the reference window. Drag back here or press Escape to cancel.")
            switch entry {
            case .clip(let clip):
                card.picture.image = app.store.thumbnail(for: clip)
                card.caption.stringValue = clip.name
                card.toolTip = "\(clip.name) · \(clip.width) × \(clip.height) · Double-click or Space to preview"
                card.setAccessibilityLabel(clip.name)
                card.setAccessibilityHelp("\(clip.width) by \(clip.height) pixels. Double-click or press Space to preview. Drag to copy to another app.")
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
                card.toolTip = "\(folder.name) · \(clips.count) clips · Click to browse, drag out to reference, or drop clips here"
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
        let pinButton = ReferencePinButton()
        private var tracking: NSTrackingArea?
        private(set) var hovered = false
        var pressed = false { didSet { needsDisplay = true } }
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
            caption.alignment = .left
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
            addSubview(pinButton)
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
            if folderID != nil { addCursorRect(bounds, cursor: .openHand) }
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
            caption.frame = CGRect(x: 6, y: 132, width: max(1, bounds.width - 35), height: 18)
            pinButton.frame = CGRect(x: bounds.width - 25, y: 130, width: 22, height: 22)
        }
        override func draw(_ dirtyRect: NSRect) {
            if hovered || pressed {
                NSColor.labelColor.withAlphaComponent(pressed ? 0.12 : 0.06).setFill()
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
    final class ClipView: NSClipView {
        override func setFrameSize(_ newSize: NSSize) {
            let layout = (documentView as? NSCollectionView)?.collectionViewLayout as? NSCollectionViewFlowLayout
            func fitItems(to width: CGFloat) {
                guard let layout, width > 26 else { return }
                let size = NSSize(width: min(floor(width - 26), max(110, floor((width - 36) / 2))), height: 153)
                if layout.itemSize != size { layout.itemSize = size }
            }
            // AppKit prepares the grid as the viewport changes, before resizing its document view.
            fitItems(to: min(bounds.width, newSize.width))
            super.setFrameSize(newSize)
            fitItems(to: newSize.width)
        }
    }
    final class CollectionView: NSCollectionView {
        static let pasteboardTypes = (ShelfDropDelegate.types + [UTType.jpeg.identifier, UTType.heic.identifier, UTType.webP.identifier])
            .map { NSPasteboard.PasteboardType($0) }
        weak var app: AppController?
        var referenceFolderID: UUID?
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
        override func mouseDown(with event: NSEvent) {
            window?.makeKey(); window?.makeFirstResponder(self)
            if let entry = entry(at: convert(event.locationInWindow, from: nil)), let app {
                if let folder = entry.folder, event.modifierFlags.intersection([.command, .shift]).isEmpty {
                    let card = indexPathForItem(at: convert(event.locationInWindow, from: nil)).flatMap { item(at: $0)?.view } ?? self
                    if !app.trackReferenceDrag(.group(folder.id), from: card, event: event) { app.openFolder(folder.id) }
                    return
                }
                if event.clickCount == 2, let clip = entry.clip {
                    if referenceFolderID != nil { app.openReference(.clip(clip.id)) } else { app.previewClip = clip }
                    return
                }
            }
            super.mouseDown(with: event)
        }
        override func keyDown(with event: NSEvent) {
            if !handleKey(event) { super.keyDown(with: event) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command), handleKey(event) { return true }
            return super.performKeyEquivalent(with: event)
        }
        func handleKey(_ event: NSEvent) -> Bool {
            guard let app else { return false }
            guard let referenceFolderID else { return app.handleKey(event) }
            if app.handleReferenceKey(event, target: .group(referenceFolderID)) { return true }
            guard let coordinator = dataSource as? Coordinator else { return false }
            let selected = coordinator.entries.compactMap(\.clip).filter { coordinator.selectedIDs.contains($0.id) }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "a":
                    selectItems(at: Set(coordinator.entries.indices.map { IndexPath(item: $0, section: 0) }), scrollPosition: [])
                    coordinator.selectedIDs = Set(coordinator.entries.map(\.id))
                case "c": if selected.count == 1 { app.copy(selected[0]) }
                case "p" where event.modifierFlags.contains(.shift): selected.forEach { app.openReference(.clip($0.id)) }
                default: return false
                }
                return true
            }
            if event.modifierFlags.intersection([.control, .option]).isEmpty && [UInt16(36), 49].contains(event.keyCode) {
                selected.forEach { app.openReference(.clip($0.id)) }; return true
            }
            return false
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let entry = entry(at: convert(event.locationInWindow, from: nil)), let app else { return nil }
            if referenceFolderID != nil, let clip = entry.clip {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(app.referenceMenuItem(.clip(clip.id)))
                menu.addItem(app.renameMenuItem(clip))
                return menu
            }
            if let folder = entry.folder { return app.folderMenu(folder) }
            return entry.clip.map(app.clipMenu)
        }
        private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let app, !app.store.isReadOnly else { dropFolderID = nil; return [] }
            dropFolderID = entry(at: convert(sender.draggingLocation, from: nil))?.folder?.id ?? referenceFolderID
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
        var loaded = false
        var restoringPosition = false
        var displayedFolderID: UUID?
        let referenceFolderID: UUID?
        var selectedIDs: Set<UUID> = []
        init(app: AppController, referenceFolderID: UUID? = nil) { self.app = app; self.referenceFolderID = referenceFolderID }
        @objc func scrolled(_ notification: Notification) {
            if let clipView = notification.object as? NSClipView { rememberScroll(clipView) }
        }
        func rememberScroll(_ clipView: NSClipView) {
            guard !updating, !restoringPosition, loaded, referenceFolderID == nil, !app.shelf.collapsed,
                  displayedFolderID == app.store.currentFolderID else { return }
            app.store.browsingStates[displayedFolderID, default: ShelfStore.BrowsingState()].scrollOrigin = clipView.bounds.origin
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("clip"), for: indexPath) as! Item
            item.configure(app: app, entry: entries[indexPath.item], selected: referenceFolderID != nil ? selectedIDs.contains(entries[indexPath.item].id) : nil)
            return item
        }
        private func updateSelection(_ collection: NSCollectionView) {
            guard !updating else { return }
            let selected = collection.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item] : nil }
            if referenceFolderID != nil { selectedIDs = Set(selected.map(\.id)); return }
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
            return app.clipPasteboardItem(clip)
        }
    }
}
