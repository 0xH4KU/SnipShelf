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
        let restorePosition = referenceFolderID == nil && (!coordinator.loaded || coordinator.restoringPosition || coordinator.displayedFolderID != app.store.currentFolderID || coordinator.displayedSearch != app.store.searchText)
        coordinator.displayedFolderID = app.store.currentFolderID
        coordinator.displayedSearch = app.store.searchText
        let members = Dictionary(grouping: app.store.clips.reversed(), by: \.folderID)
        let groups: [Entry] = referenceFolderID == nil && app.store.currentFolderID == nil && !app.store.isSearching
            ? app.store.folders.map { .group($0, members[$0.id] ?? []) } : []
        let clips = referenceFolderID.map { app.store.clips(in: $0) } ?? app.store.visibleClips
        let unsorted = groups + clips.map(Entry.clip)
        let byID = Dictionary(uniqueKeysWithValues: unsorted.map { ($0.id, $0) })
        let entries = referenceFolderID != nil || !app.store.isSearching
            ? app.store.orderedIDs(unsorted.map(\.id)).compactMap { byID[$0] } : unsorted
        guard coordinator.reorderingID == nil else { return }
        collection.updateLayout(for: scroll.contentView.bounds.width)
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
            let query = app.store.searchText
            let origin = app.store.isSearching ? .zero : (app.store.browsingStates[folderID]?.scrollOrigin ?? .zero)
            // A remounted collection receives its viewport size after updateNSView returns.
            DispatchQueue.main.async { [weak scroll, weak coordinator] in
                guard let scroll, let coordinator, coordinator.displayedFolderID == folderID, app.store.searchText == query else { return }
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
                item.configure(app: app, entry: entries[index.item], selected: selected.contains(entries[index.item].id), showsLocation: referenceFolderID == nil && app.store.isSearching)
            }
        }
    }
    final class Item: NSCollectionViewItem {
        override func loadView() { view = CardView() }
        override func prepareForReuse() {
            super.prepareForReuse()
            view.alphaValue = 1
            (view as? CardView)?.setHovered(false, animated: false)
        }
        override var isSelected: Bool { didSet { (view as? CardView)?.selected = isSelected } }
        override var draggingImageComponents: [NSDraggingImageComponent] {
            guard let card = view as? CardView, let image = card.picture.image else { return [] }
            let component = NSDraggingImageComponent(key: .icon)
            component.contents = image
            let scale = min(card.picture.bounds.width / image.size.width, card.picture.bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            component.frame = CGRect(x: card.picture.frame.midX - size.width / 2, y: card.picture.frame.midY - size.height / 2,
                                     width: size.width, height: size.height)
            return [component]
        }
        func configure(app: AppController, entry: Entry, selected: Bool? = nil, showsLocation: Bool = false) {
            guard let card = view as? CardView else { return }
            if card.folderID != entry.folder?.id { card.dropTargeted = false }
            card.folderID = entry.folder?.id
            card.alphaValue = (collectionView?.dataSource as? Coordinator)?.reorderingID == entry.id ? 0.45 : 1
            card.selected = selected ?? (app.store.selectedIDs.contains(entry.id) || app.store.selectedFolderID == entry.id)
            card.recent = entry.clip.map { app.store.latestID == $0.id } ?? false
            card.openGroup = nil
            card.more.isHidden = true
            card.more.stringValue = ""
            card.related.forEach { $0.isHidden = true; $0.image = nil }
            card.setAccessibilityElement(entry.folder != nil)
            card.pinButton.app = app
            card.pinButton.referenceTarget = entry.folder.map { .group($0.id) } ?? .clip(entry.id)
            card.dragHandle.app = app
            card.dragHandle.referenceTarget = card.pinButton.referenceTarget
            let name = switch entry { case .clip(let clip): clip.name; case .group(let folder, _): folder.name }
            card.caption.font = .systemFont(ofSize: 11, weight: entry.folder == nil ? .regular : .medium)
            card.location.isHidden = !showsLocation
            card.location.stringValue = entry.clip.map { app.store.locationName(for: $0) } ?? ""
            card.caption.toolTip = name
            let pinLabel = "Open \(name) in a floating reference window"
            card.pinButton.image = ReferencePinButton.icon
            card.pinButton.toolTip = pinLabel
            card.pinButton.setAccessibilityLabel(pinLabel)
            card.pinButton.setAccessibilityHelp("Opens a separate floating window. The original stays on the shelf.")
            card.dragHandle.toolTip = showsLocation || app.store.isReadOnly
                ? "Drag out to open a floating reference" : "Drag to reorder · Drag out for a floating reference"
            card.dragHandle.setAccessibilityLabel("Move \(name)")
            card.dragHandle.setAccessibilityHelp(card.dragHandle.toolTip! + ". Escape cancels a drag."
                + (showsLocation || app.store.isReadOnly ? "" : " Select and use Option–Command–arrow keys to reorder."))
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
                card.toolTip = "\(folder.name) · \(clips.count) clips · Click to browse or drop clips here"
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
        let location = NSTextField(labelWithString: "")
        let related = [NSImageView(), NSImageView()]
        let relatedFrames = [ThumbnailFrame(), ThumbnailFrame()]
        let more = NSTextField(labelWithString: "")
        let pinButton = ReferencePinButton()
        let dragHandle = ReferenceDragHandle()
        var collection: CollectionView? {
            var parent = superview
            while let view = parent {
                if let collection = view as? CollectionView { return collection }
                parent = view.superview
            }
            return nil
        }
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
            location.font = .systemFont(ofSize: 10)
            location.textColor = .secondaryLabelColor
            location.lineBreakMode = .byTruncatingMiddle
            location.isHidden = true
            addSubview(location)
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
            addSubview(dragHandle)
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
                picture.frame = CGRect(x: bounds.midX - 63 - (hovered ? 1 : 0), y: hovered ? 20 : 23, width: 82, height: 115)
                for (index, frame) in relatedFrames.enumerated() {
                    frame.frame = CGRect(x: bounds.midX + 23 + (hovered ? 2 : 0),
                                         y: 29 + CGFloat(index) * 53 + (hovered ? (index == 0 ? -2 : 2) : 0), width: 40, height: 46)
                    related[index].frame = frame.bounds.insetBy(dx: 3, dy: 3)
                }
                more.frame = CGRect(x: bounds.midX + 23, y: 132, width: 40, height: 15)
            } else {
                picture.frame = CGRect(x: 10, y: 28, width: max(1, bounds.width - 20), height: 106)
            }
            for (image, frame) in zip(related, relatedFrames) { frame.isHidden = image.isHidden }
            dragHandle.frame = CGRect(x: bounds.midX - 22, y: 0, width: 44, height: 22)
            caption.frame = CGRect(x: 6, y: 150, width: max(1, bounds.width - 39), height: 18)
            location.frame = CGRect(x: 6, y: 169, width: max(1, bounds.width - 12), height: 16)
            pinButton.frame = CGRect(x: bounds.width - 30, y: 146, width: 27, height: 27)
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
            let collection = documentView as? CollectionView
            // AppKit prepares the grid as the viewport changes, before resizing its document view.
            collection?.updateLayout(for: min(bounds.width, newSize.width))
            super.setFrameSize(newSize)
            collection?.updateLayout(for: newSize.width)
        }
    }
    final class CollectionView: NSCollectionView {
        static let pasteboardTypes = (ShelfDropDelegate.types + [UTType.jpeg.identifier, UTType.heic.identifier, UTType.webP.identifier])
            .map { NSPasteboard.PasteboardType($0) }
        weak var app: AppController?
        var referenceFolderID: UUID?
        private var originalDragIndex: Int?
        var handleDragEvent: NSEvent?
        var canReorder: Bool {
            guard let app else { return false }
            return !app.store.isReadOnly && (referenceFolderID != nil || !app.store.isSearching)
        }

        func beginReordering(_ id: UUID) {
            guard canReorder, let coordinator = dataSource as? Coordinator,
                  let index = coordinator.entries.firstIndex(where: { $0.id == id }) else { return }
            originalDragIndex = index
            coordinator.reorderingID = id
        }

        func updateReordering(at screenPoint: CGPoint) {
            guard let window, let coordinator = dataSource as? Coordinator, coordinator.reorderingID != nil else { return }
            let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            guard visibleRect.contains(point) else { return }
            let slots = indexPathsForVisibleItems().compactMap { index -> (Int, CGRect)? in
                layoutAttributesForItem(at: index).map { (index.item, $0.frame) }
            }
            // Layout slots stay stable while the native item views animate between them.
            if let nearest = slots.min(by: {
                hypot($0.1.midX - point.x, $0.1.midY - point.y) < hypot($1.1.midX - point.x, $1.1.midY - point.y)
            }) { moveDraggedItem(to: nearest.0) }
        }

        private func moveDraggedItem(to index: Int) {
            guard let coordinator = dataSource as? Coordinator, let id = coordinator.reorderingID,
                  let previous = coordinator.entries.firstIndex(where: { $0.id == id }), previous != index else { return }
            coordinator.updating = true
            defer { coordinator.updating = false }
            coordinator.entries.insert(coordinator.entries.remove(at: previous), at: index)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
                performBatchUpdates { self.moveItem(at: IndexPath(item: previous, section: 0), to: IndexPath(item: index, section: 0)) }
            }
        }

        func finishReordering(commit: Bool) -> CGRect? {
            guard let coordinator = dataSource as? Coordinator, let id = coordinator.reorderingID,
                  let originalDragIndex else { return nil }
            defer { coordinator.reorderingID = nil; self.originalDragIndex = nil }
            if !commit || app?.store.reorder(coordinator.entries.map(\.id), in: referenceFolderID ?? app?.store.currentFolderID) != true {
                moveDraggedItem(to: originalDragIndex)
            }
            guard let index = coordinator.entries.firstIndex(where: { $0.id == id }),
                  let frame = layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return nil }
            item(at: IndexPath(item: index, section: 0))?.view.alphaValue = 1
            return window?.convertToScreen(convert(frame, to: nil))
        }
        func updateLayout(for width: CGFloat) {
            guard let layout = collectionViewLayout as? NSCollectionViewFlowLayout, width > 26 else { return }
            let columns = max(1, Int((width - 16) / 136))
            let size = CGSize(width: floor((width - 26 - CGFloat(columns - 1) * 10) / CGFloat(columns)),
                              height: referenceFolderID == nil && app?.store.isSearching == true ? 191 : 173)
            if layout.itemSize != size { layout.itemSize = size }
            if referenceFolderID == nil { app?.shelfColumns = columns }
        }
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
                    var dragged = false
                    while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                        if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) >= 6 { dragged = true }
                        if next.type == .leftMouseUp {
                            if !dragged, self.entry(at: convert(next.locationInWindow, from: nil))?.id == folder.id { app.openFolder(folder.id) }
                            break
                        }
                    }
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
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option],
               [UInt16(123), 124, 125, 126].contains(event.keyCode), canReorder,
               let coordinator = dataSource as? Coordinator, selectionIndexPaths.count == 1, let selected = selectionIndexPaths.first {
                var ids = coordinator.entries.map(\.id)
                let delta = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
                let destination = min(ids.count - 1, max(0, selected.item + delta))
                ids.insert(ids.remove(at: selected.item), at: destination)
                app.store.reorder(ids, in: referenceFolderID ?? app.store.currentFolderID)
                return true
            }
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
        var reorderingID: UUID?
        var updating = false
        var loaded = false
        var restoringPosition = false
        var displayedFolderID: UUID?
        var displayedSearch = ""
        let referenceFolderID: UUID?
        var selectedIDs: Set<UUID> = []
        init(app: AppController, referenceFolderID: UUID? = nil) { self.app = app; self.referenceFolderID = referenceFolderID }
        @objc func scrolled(_ notification: Notification) {
            if let clipView = notification.object as? NSClipView { rememberScroll(clipView) }
        }
        func rememberScroll(_ clipView: NSClipView) {
            guard !updating, !restoringPosition, loaded, referenceFolderID == nil, !app.shelf.collapsed, !app.store.isSearching,
                  displayedFolderID == app.store.currentFolderID else { return }
            app.store.browsingStates[displayedFolderID, default: ShelfStore.BrowsingState()].scrollOrigin = clipView.bounds.origin
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("clip"), for: indexPath) as! Item
            item.configure(app: app, entry: entries[indexPath.item], selected: referenceFolderID != nil ? selectedIDs.contains(entries[indexPath.item].id) : nil,
                           showsLocation: referenceFolderID == nil && app.store.isSearching)
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
