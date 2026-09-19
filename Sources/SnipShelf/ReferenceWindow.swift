import AppKit
import SwiftUI
import Observation
import PaletteKit

extension Clip {
    var imageWindowContentSize: CGSize {
        CGSize(width: 340, height: min(560, max(286, 340 * CGFloat(height) / CGFloat(width) + 116)))
    }
}

enum ReferenceTarget: Hashable {
    case group(UUID), clip(UUID)

    var id: UUID { switch self { case .group(let id), .clip(let id): id } }

    private var preferenceKey: String {
        switch self {
        case .group(let id): "reference.group.\(id)"
        case .clip(let id): "reference.clip.\(id)"
        }
    }
    var frameKey: String { preferenceKey + ".frame" }
    var backgroundKey: String { preferenceKey + ".background" }

    @MainActor func title(in store: ShelfStore) -> String? {
        switch self {
        case .group(let id): store.folders.first { $0.id == id }?.name
        case .clip(let id): store.clips.first { $0.id == id }?.name
        }
    }
}

extension AppController {
    func openReference(_ target: ReferenceTarget, from lift: ReferenceLiftWindow? = nil, at center: CGPoint? = nil) {
        guard let title = target.title(in: store) else {
            if let lift { lift.finish(at: lift.sourceFrame) }
            return
        }
        if referencesHidden { toggleReferences() }
        if let existing = referenceWindows[target] {
            presentReference(existing, from: lift, at: center)
            return
        }
        let size: CGSize
        switch target {
        case .group: size = CGSize(width: 340, height: 410)
        case .clip(let id):
            guard let clip = store.clips.first(where: { $0.id == id }) else { return }
            let palette = PaletteModel(defaults: paletteDefaults)
            referencePalettes[id] = palette
            palette.open(store.url(for: clip))
            if defaults.object(forKey: target.backgroundKey) == nil { defaults.set(backdrop, forKey: target.backgroundKey) }
            size = clip.imageWindowContentSize
        }
        let panel = ShelfPanel(contentRect: CGRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = { if case .group = target { CGSize(width: 300, height: 240) } else { CGSize(width: 220, height: 180) } }()
        let content = NSHostingView(rootView: ReferenceView(app: self, target: target))
        // Window limits are set above; intrinsic content sizing must not interrupt the opening animation.
        content.sizingOptions = []
        panel.contentView = content
        panel.onKey = { [weak self] in self?.handleReferenceKey($0, target: target) ?? false }
        let anchor = shelf.panel?.frame ?? lift?.sourceWindowFrame
        let screen = anchor.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens[0]
        var frame = CGRect(origin: screen.visibleFrame.origin, size: panel.frame.size)
        if let saved = defaults.string(forKey: target.frameKey) {
            frame = NSRectFromString(saved)
        } else if center == nil {
            frame = Self.initialReferenceFrame(size: frame.size, minimumSize: panel.minSize, beside: anchor, in: screen.visibleFrame,
                occupied: referenceWindows.values.map { $0.referenceTransition?.destinationFrame ?? $0.frame })
        }
        let visible = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }?.visibleFrame ?? screen.visibleFrame
        panel.setFrame(ShelfWindow.constrainedFrame(frame, to: visible), display: false)
        panel.delegate = self
        referenceWindows[target] = panel
        presentReference(panel, from: lift, at: center)
    }

    static func initialReferenceFrame(size: CGSize, minimumSize: CGSize, beside anchor: CGRect?, in visible: CGRect, occupied: [CGRect]) -> CGRect {
        let gap: CGFloat = 12, step: CGFloat = 28
        let regions: [CGRect]
        if let anchor, anchor.intersects(visible) {
            let shelf = anchor.intersection(visible)
            regions = [
                CGRect(x: shelf.maxX + gap, y: visible.minY, width: visible.maxX - shelf.maxX - gap, height: visible.height),
                CGRect(x: visible.minX, y: visible.minY, width: shelf.minX - visible.minX - gap, height: visible.height),
                CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: shelf.minY - visible.minY - gap),
                CGRect(x: visible.minX, y: shelf.maxY + gap, width: visible.width, height: visible.maxY - shelf.maxY - gap)
            ].filter { $0.size.width > 0 && $0.size.height > 0 }
        } else { regions = [visible] }
        // Constrain inside free space, so screen-edge clamping cannot push a window back over the Shelf.
        let usable = regions.filter { $0.width >= minimumSize.width && $0.height >= minimumSize.height }
        let region = regions.first { $0.width >= size.width && $0.height >= size.height } ?? (usable.isEmpty ? regions : usable).max {
            min($0.width, size.width) * min($0.height, size.height) < min($1.width, size.width) * min($1.height, size.height)
        } ?? visible
        var frame = CGRect(x: anchor?.minX ?? visible.minX + 36, y: (anchor?.maxY ?? visible.maxY - 36) - size.height,
                           width: size.width, height: size.height)
        if let anchor {
            if region.minX >= anchor.maxX { frame.origin.x = region.minX }
            else if region.maxX <= anchor.minX { frame.origin.x = region.maxX - frame.width }
            if region.maxY <= anchor.minY { frame.origin.y = region.maxY - frame.height }
            else if region.minY >= anchor.maxY { frame.origin.y = region.minY }
        }
        frame = ShelfWindow.constrainedFrame(frame, to: region)
        let left = frame.minX - region.minX, right = region.maxX - frame.maxX
        let below = frame.minY - region.minY, above = region.maxY - frame.maxY
        let xSteps = Int(max(left, right) / step), ySteps = Int(max(below, above) / step)
        let candidates = (0...max(xSteps, ySteps)).map { index in
            frame.offsetBy(dx: CGFloat(min(index, xSteps)) * step * (right >= left ? 1 : -1),
                           dy: CGFloat(min(index, ySteps)) * step * (below >= above ? -1 : 1))
        }
        return candidates.first { candidate in
            !occupied.contains { abs($0.minX - candidate.minX) < step / 2 && abs($0.maxY - candidate.maxY) < step / 2 }
        } ?? candidates[occupied.count % candidates.count]
    }

    private func presentReference(_ panel: ShelfPanel, from lift: ReferenceLiftWindow?, at center: CGPoint?) {
        guard let lift else { panel.makeKeyAndOrderFront(nil); return }
        var frame = panel.referenceTransition?.destinationFrame ?? panel.frame
        if let center {
            frame.origin = CGPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: lift.frame.midX, y: lift.frame.midY)) } ?? panel.screen ?? NSScreen.main
            if let screen { frame = ShelfWindow.constrainedFrame(frame, to: screen.visibleFrame) }
        }
        lift.finish(at: frame, revealing: panel)
    }

    func closeReference(_ target: ReferenceTarget) { referenceWindows[target]?.close() }

    func updateReferenceWindowControls(for window: NSWindow? = nil) {
        let count = referenceWindows.count
        for panel in referenceWindows.values where window == nil || panel === window {
            let index = panel.titlebarAccessoryViewControllers.firstIndex { $0.view is ReferenceTitlebarControls }
            guard count > 1 else {
                if let index { panel.removeTitlebarAccessoryViewController(at: index) }
                panel.titleVisibility = .visible
                continue
            }
            let controls = index.flatMap { panel.titlebarAccessoryViewControllers[$0].view as? ReferenceTitlebarControls }
                ?? ReferenceTitlebarControls(app: self)
            let button = controls.button
            controls.title.stringValue = panel.title
            button.title = "Close All · \(count)"
            button.toolTip = "Close all \(count) reference windows (⌥⌘W)"
            button.setAccessibilityLabel("Close all \(count) reference windows")
            button.sizeToFit()
            button.frame.size.width += 12
            let leading = panel.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil).maxX + 12 } ?? 80
            controls.setFrameSize(CGSize(width: max(0, panel.frame.width - leading), height: 32))
            controls.needsLayout = true
            panel.titleVisibility = .hidden
            if index == nil {
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = .right
                accessory.view = controls
                panel.addTitlebarAccessoryViewController(accessory)
            }
        }
    }

    @objc func closeAllReferences() {
        // Closing calls the delegate to save placement and remove each window and its palette.
        for panel in Array(referenceWindows.values) { panel.close() }
    }

    func handleCloseAllReferencesKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option],
              event.charactersIgnoringModifiers?.lowercased() == "w" else { return false }
        closeAllReferences()
        return true
    }

    /// Returns false only for a click. Window gestures never start a pasteboard drag or trigger a file drop.
    func trackReferenceDrag(_ target: ReferenceTarget, from view: NSView, event: NSEvent) -> Bool {
        guard let sourceWindow = view.window else { return true }
        let start = sourceWindow.convertPoint(toScreen: event.locationInWindow)
        let card = (view as? ShelfCollection.CardView) ?? (view.superview as? ShelfCollection.CardView)
        let source = card ?? view
        let collection = card?.collection
        card?.pressed = true
        var lift: ReferenceLiftWindow?
        let scrolling = Timer(timeInterval: 0.04, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard lift != nil, let collection, collection.canReorder, let lastDrag = collection.handleDragEvent,
                      sourceWindow.frame.contains(sourceWindow.convertPoint(toScreen: lastDrag.locationInWindow)),
                      collection.autoscroll(with: lastDrag) else { return }
                collection.updateReordering(at: sourceWindow.convertPoint(toScreen: lastDrag.locationInWindow))
            }
        }
        RunLoop.main.add(scrolling, forMode: .common)
        defer {
            scrolling.invalidate()
            collection?.handleDragEvent = nil
            _ = collection?.finishReordering(commit: false)
            card?.pressed = false
            if lift != nil { NSCursor.pop() }
        }
        while let next = sourceWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .keyDown {
                guard next.keyCode == 53 else { continue }
                if let lift { lift.finish(at: collection?.finishReordering(commit: false) ?? lift.sourceFrame) }
                return true
            }
            let point = (next.window ?? sourceWindow).convertPoint(toScreen: next.locationInWindow)
            if lift == nil {
                if next.type == .leftMouseUp {
                    let local = view.convert(sourceWindow.convertPoint(fromScreen: point), from: nil)
                    return !view.bounds.contains(local)
                }
                guard hypot(point.x - start.x, point.y - start.y) >= 6 else { continue }
                lift = ReferenceLiftWindow(source: source)
                guard lift != nil else { return true }
                collection?.beginReordering(target.id)
                NSCursor.closedHand.push()
            }
            guard let lift else { return true }
            lift.follow(from: start, to: point)
            let outside = !sourceWindow.frame.contains(point)
            let inGrid = collection.map { $0.visibleRect.contains($0.convert(sourceWindow.convertPoint(fromScreen: point), from: nil)) } ?? false
            lift.showDestination(outside: outside)
            if !outside { collection?.updateReordering(at: point) }
            collection?.handleDragEvent = next.type == .leftMouseDragged ? next : nil
            if next.type == .leftMouseUp {
                let returnFrame = collection?.finishReordering(commit: !outside && inGrid) ?? lift.sourceFrame
                if outside { openReference(target, from: lift, at: CGPoint(x: lift.frame.midX, y: lift.frame.midY)) }
                else { lift.finish(at: returnFrame) }
                return true
            }
        }
        if let lift { lift.finish(at: collection?.finishReordering(commit: false) ?? lift.sourceFrame) }
        return true
    }

    func pinSelection() {
        if let id = store.selectedFolderID { openReference(.group(id)) }
        else { for clip in store.clips where store.selectedIDs.contains(clip.id) { openReference(.clip(clip.id)) } }
    }

    @objc func toggleReferences() {
        guard !referenceWindows.isEmpty else { return }
        referencesHidden.toggle()
        for panel in referenceWindows.values {
            if referencesHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    func handleReferenceKey(_ event: NSEvent, target: ReferenceTarget) -> Bool {
        if handleCloseAllReferencesKey(event) { return true }
        let command = event.modifierFlags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           case .clip(let id) = target, let palette = referencePalettes[id], palette.settingsPresented {
            palette.settingsPresented = false
            return true
        }
        if command && key == "z" && !event.modifierFlags.contains(.shift) { store.undo(); return true }
        if (event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty) || (command && key == "w") {
            closeReference(target); return true
        }
        if command && key == "c", case .clip(let id) = target, let clip = store.clips.first(where: { $0.id == id }) {
            copy(clip); return true
        }
        return false
    }

    func referenceMenuItem(_ target: ReferenceTarget) -> NSMenuItem {
        let item = NSMenuItem(title: "Open Floating Reference", action: #selector(openReferenceAction(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = target
        return item
    }

    @objc private func openReferenceAction(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? ReferenceTarget { openReference(target) }
    }

    func persistReferenceFrame(_ notification: Notification) {
        guard let (target, panel) = referenceWindows.first(where: { $0.value === notification.object as? NSWindow }) else { return }
        defaults.set(NSStringFromRect(panel.referenceTransition?.destinationFrame ?? panel.frame), forKey: target.frameKey)
    }

    @objc func recoverReferenceWindows() {
        for panel in referenceWindows.values {
            let visible = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) }?.visibleFrame
                ?? NSScreen.main?.visibleFrame
            if let visible { panel.setFrame(ShelfWindow.constrainedFrame(panel.frame, to: visible), display: true) }
        }
    }

    func observeReferenceChanges() {
        withObservationTracking {
            _ = store.clips; _ = store.folders
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPreviewTitle()
                for (target, panel) in self.referenceWindows {
                    if let title = target.title(in: self.store) { panel.title = title }
                    else { panel.close() }
                }
                self.updateReferenceWindowControls()
                self.observeReferenceChanges()
            }
        }
    }

    func clipPasteboardItem(_ clip: Clip) -> NSPasteboardItem? {
        do {
            let url = store.url(for: clip)
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(try Data(contentsOf: url), forType: .png)
            return item
        } catch { store.message = error.localizedDescription; return nil }
    }
}

final class ReferenceCloseAllButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ReferenceTitlebarControls: NSView {
    let title = NSTextField(labelWithString: "")
    let button: ReferenceCloseAllButton

    init(app: AppController) {
        button = ReferenceCloseAllButton(title: "", target: app, action: #selector(AppController.closeAllReferences))
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.usesSingleLineMode = true
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        addSubview(title); addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        button.frame = CGRect(x: bounds.width - button.frame.width - 6, y: (bounds.height - 24) / 2,
                              width: button.frame.width, height: 24)
        title.frame = CGRect(x: 0, y: (bounds.height - 18) / 2, width: max(0, button.frame.minX - 8), height: 18)
    }
}

final class ReferencePinButton: NSButton {
    static let icon: NSImage = {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { _ in
            let scale = NSAffineTransform()
            scale.scale(by: 0.75); scale.concat()
            NSColor.black.setStroke(); NSColor.black.setFill()
            let outline = NSBezierPath(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 14), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.5; outline.stroke()
            NSBezierPath(roundedRect: CGRect(x: 11, y: 11, width: 7, height: 5), xRadius: 1.3, yRadius: 1.3).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
    weak var app: AppController?
    var referenceTarget: ReferenceTarget?
    private var tracking: NSTrackingArea?
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false; imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        target = self; action = #selector(openReference)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openReference() {
        if let referenceTarget { app?.openReference(referenceTarget, from: ReferenceLiftWindow(source: superview ?? self)) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        func press(_ pressed: Bool) {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = layer.presentation()?.transform ?? layer.transform
            let scale = pressed ? 0.94 : 1.0
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
            animation.toValue = layer.transform
            animation.duration = 0.12
            layer.add(animation, forKey: "press")
        }
        press(true)
        super.mouseDown(with: event)
        press(false)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

final class ReferenceDragHandle: NSView {
    weak var app: AppController?
    var referenceTarget: ReferenceTarget?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0.65
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func setHovered(_ value: Bool) {
        hovered = value; needsDisplay = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            animator().alphaValue = value ? 1 : 0.65
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || pressed {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.12 : 0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        NSColor.labelColor.setFill()
        for x in [-5.0, 0, 5] {
            for y in [-2.5, 2.5] {
                NSBezierPath(ovalIn: CGRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2)).fill()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let app, let referenceTarget else { return }
        pressed = true; needsDisplay = true
        defer { pressed = false; needsDisplay = true }
        if !app.trackReferenceDrag(referenceTarget, from: self, event: event),
           let collection = (superview as? ShelfCollection.CardView)?.collection,
           let coordinator = collection.dataSource as? ShelfCollection.Coordinator,
           let index = coordinator.entries.firstIndex(where: { $0.id == referenceTarget.id }) {
            collection.selectItems(at: [IndexPath(item: index, section: 0)], scrollPosition: [])
            window?.makeKey(); window?.makeFirstResponder(collection)
        }
    }
}
