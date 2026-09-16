import AppKit
import SwiftUI
import Observation

enum ReferenceTarget: Hashable {
    case group(UUID), clip(UUID)

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
    func openReference(_ target: ReferenceTarget, from lift: ReferenceLiftWindow? = nil, at topLeft: CGPoint? = nil) {
        guard let title = target.title(in: store) else {
            if let lift { lift.finish(at: lift.sourceFrame) }
            return
        }
        if referencesHidden { toggleReferences() }
        if let existing = referenceWindows[target] {
            presentReference(existing, from: lift, at: topLeft)
            return
        }
        let size: CGSize
        switch target {
        case .group: size = CGSize(width: 340, height: 410)
        case .clip(let id):
            guard let clip = store.clips.first(where: { $0.id == id }) else { return }
            if defaults.object(forKey: target.backgroundKey) == nil { defaults.set(backdrop, forKey: target.backgroundKey) }
            size = CGSize(width: 340, height: min(500, max(220, 340 * CGFloat(clip.height) / CGFloat(clip.width) + 50)))
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
        let screen = shelf.panel?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let offset = CGFloat(referenceWindows.count % 8) * 28
        var frame = panel.frame
        frame.origin = CGPoint(x: screen.visibleFrame.minX + 36 + offset, y: screen.visibleFrame.maxY - frame.height - 36 - offset)
        if let lift {
            let visible = NSScreen.screens.first { $0.frame.intersects(lift.sourceFrame) }?.visibleFrame ?? screen.visibleFrame
            let beside = lift.sourceWindowFrame.maxX + 12
            frame.origin = CGPoint(x: beside + frame.width <= visible.maxX ? beside : lift.sourceWindowFrame.minX - frame.width - 12,
                                   y: lift.sourceFrame.maxY - frame.height)
        }
        if let saved = defaults.string(forKey: target.frameKey) { frame = NSRectFromString(saved) }
        let visible = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }?.visibleFrame ?? screen.visibleFrame
        referenceWindows[target] = panel
        panel.setFrame(ShelfWindow.constrainedFrame(frame, to: visible), display: false)
        panel.delegate = self
        presentReference(panel, from: lift, at: topLeft)
    }

    private func presentReference(_ panel: ShelfPanel, from lift: ReferenceLiftWindow?, at topLeft: CGPoint?) {
        guard let lift else { panel.makeKeyAndOrderFront(nil); return }
        var frame = panel.referenceTransition?.destinationFrame ?? panel.frame
        if let topLeft {
            frame.origin = CGPoint(x: topLeft.x, y: topLeft.y - frame.height)
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: lift.frame.midX, y: lift.frame.midY)) } ?? panel.screen ?? NSScreen.main
            if let screen { frame = ShelfWindow.constrainedFrame(frame, to: screen.visibleFrame) }
        }
        lift.finish(at: frame, revealing: panel)
    }

    func closeReference(_ target: ReferenceTarget) { referenceWindows[target]?.close() }

    /// Returns false only for a click. Window gestures never start a pasteboard drag or trigger a file drop.
    func trackReferenceDrag(_ target: ReferenceTarget, from view: NSView, event: NSEvent) -> Bool {
        guard let sourceWindow = view.window else { return true }
        let start = sourceWindow.convertPoint(toScreen: event.locationInWindow)
        let card = (view as? ShelfCollection.CardView) ?? (view.superview as? ShelfCollection.CardView)
        let source = card ?? view
        card?.pressed = true
        var lift: ReferenceLiftWindow?
        defer { card?.pressed = false; if lift != nil { NSCursor.pop() } }
        while let next = sourceWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .keyDown {
                guard next.keyCode == 53 else { continue }
                if let lift { lift.finish(at: lift.sourceFrame) }
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
                NSCursor.closedHand.push()
            }
            guard let lift else { return true }
            lift.follow(from: start, to: point)
            if next.type == .leftMouseUp {
                if lift.sourceFrame.contains(point) { lift.finish(at: lift.sourceFrame) }
                else { openReference(target, from: lift, at: CGPoint(x: lift.frame.minX, y: lift.frame.maxY)) }
                return true
            }
        }
        if let lift { lift.finish(at: lift.sourceFrame) }
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
        let command = event.modifierFlags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased()
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
        let title = { if case .group = target { "Open Reference Window" } else { "Pin as Reference" } }()
        let item = NSMenuItem(title: title, action: #selector(openReferenceAction(_:)), keyEquivalent: "")
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

final class ReferencePinButton: NSButton {
    weak var app: AppController?
    var referenceTarget: ReferenceTarget?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false; imagePosition = .imageOnly
        target = self; action = #selector(openReference)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openReference() {
        if let referenceTarget { app?.openReference(referenceTarget, from: ReferenceLiftWindow(source: superview ?? self)) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard let app, let referenceTarget else { return }
        highlight(true)
        defer { highlight(false) }
        if !app.trackReferenceDrag(referenceTarget, from: self, event: event), let action { sendAction(action, to: target) }
    }
}
