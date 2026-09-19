import AppKit
import SwiftUI
import Observation

final class ShelfPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    weak var captureCanvas: CanvasNSView?
    var referenceTransition: ReferenceLiftWindow?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, captureCanvas?.handleKey(event) == true { return }
        super.sendEvent(event)
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if captureCanvas?.handleKey(event) == true { return true }
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor @Observable
final class ShelfWindow: NSObject, NSWindowDelegate {
    static let tabSize = CGSize(width: 24, height: 88)
    static let minimumSize = CGSize(width: 300, height: 280)
    var collapsed = false
    var edge = "right"
    private(set) var dockedEdge: String?
    var snapEdge: String?
    var dropTargeted = false
    var panel: ShelfPanel!
    private var expandedSize = CGSize(width: 340, height: 560)
    private var timer: Timer?
    var isAnimating: Bool { timer != nil }
    private var hoverTask: Task<Void, Never>?
    private var temporarilyExpanded = false
    private var dragStart = CGPoint.zero
    private var frameStart = CGRect.zero
    private var moving = false
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init() }

    func install(content: some View, key: @escaping (NSEvent) -> Bool) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let usable = screen.visibleFrame
        let hasSavedSize = defaults.object(forKey: "shelfSize") != nil || defaults.object(forKey: "shelfFrame") != nil
        if let size = defaults.string(forKey: "shelfSize") { expandedSize = NSSizeFromString(size) }
        expandedSize.width = min(usable.width, max(Self.minimumSize.width, expandedSize.width))
        expandedSize.height = min(usable.height, max(Self.minimumSize.height, expandedSize.height))
        var frame = CGRect(x: usable.maxX - expandedSize.width - 20, y: usable.midY - expandedSize.height / 2,
                           width: expandedSize.width, height: expandedSize.height)
        if let saved = defaults.string(forKey: "shelfFrame") { frame = NSRectFromString(saved) }
        edge = defaults.string(forKey: "shelfEdge") == "left" ? "left" : "right"
        collapsed = defaults.bool(forKey: "shelfCollapsed")
        panel = ShelfPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "SnipShelf"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        panel.onKey = key
        panel.delegate = self
        applySizing()
        if collapsed { panel.setFrame(dockedFrame(collapsed: true), display: true) }
        recoverScreen()
        persist()
        panel.orderFrontRegardless()
        if !hasSavedSize {
            DispatchQueue.main.async { [weak self] in self?.restoreTwoRows(animated: false) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    var screen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) }
            ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private func applySizing() {
        panel.minSize = collapsed ? Self.tabSize : Self.minimumSize
        if collapsed { panel.styleMask.remove(.resizable) } else { panel.styleMask.insert(.resizable) }
    }
    private func dockedFrame(collapsed: Bool) -> CGRect {
        let visible = screen.visibleFrame
        let size = collapsed ? Self.tabSize : expandedSize
        return CGRect(x: edge == "left" ? visible.minX : visible.maxX - size.width,
                      y: min(visible.maxY - size.height, max(visible.minY, panel.frame.midY - size.height / 2)),
                      width: min(size.width, visible.width), height: min(size.height, visible.height))
    }
    func collapse() {
        guard !collapsed else { return }
        let wasAnimating = timer != nil
        timer?.invalidate(); timer = nil
        if !wasAnimating { expandedSize = panel.frame.size }
        collapsed = true; dockedEdge = edge; temporarilyExpanded = false
        applySizing(); transition(to: dockedFrame(collapsed: true))
    }
    func expand() {
        guard collapsed else { panel.orderFrontRegardless(); return }
        collapsed = false
        let frame = dockedFrame(collapsed: false)
        // Minimum size is applied only after the transition so it doesn't snap first.
        panel.styleMask.insert(.resizable)
        transition(to: frame)
    }
    private func transition(to target: CGRect) {
        timer?.invalidate()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            timer = nil; panel.setFrame(target, display: true); applySizing(); persist(); return
        }
        let start = panel.frame
        let begun = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(begun) / 0.21)
            let eased = 1 - pow(1 - t, 3)
            func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
            self.panel.setFrame(CGRect(x: lerp(start.minX, target.minX), y: lerp(start.minY, target.minY),
                                      width: lerp(start.width, target.width), height: lerp(start.height, target.height)), display: true)
            if t >= 1 { timer.invalidate(); self.timer = nil; self.applySizing(); self.persist() }
            }
        }
    }
    func beginMove(at point: CGPoint) {
        let wasAnimating = timer != nil
        timer?.invalidate(); timer = nil
        if !collapsed && !wasAnimating { expandedSize = panel.frame.size }
        if !collapsed && wasAnimating { panel.setFrame(CGRect(origin: panel.frame.origin, size: expandedSize), display: true); applySizing() }
        moving = true
        snapEdge = nil
        temporarilyExpanded = false
        dragStart = point; frameStart = panel.frame
    }
    func move(to p: CGPoint) {
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        if collapsed {
            let inward = edge == "left" ? dx > 16 : dx < -16
            if inward {
                collapsed = false
                let x = edge == "left" ? frameStart.minX + dx : frameStart.maxX + dx - expandedSize.width
                let frame = CGRect(x: x, y: p.y - expandedSize.height + 14,
                                   width: expandedSize.width, height: expandedSize.height)
                panel.setFrame(frame, display: true); applySizing()
                dragStart = p; frameStart = panel.frame
                return
            }
            let visible = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: min(visible.maxY - Self.tabSize.height, max(visible.minY, frameStart.minY + dy))))
        } else if moving {
            panel.setFrameOrigin(CGPoint(x: frameStart.minX + dx, y: frameStart.minY + dy))
            let visible = screen.visibleFrame
            let threshold = panel.frame.width / 3
            snapEdge = panel.frame.minX <= visible.minX - threshold ? "left" :
                (panel.frame.maxX >= visible.maxX + threshold ? "right" : nil)
        }
    }
    func endMove(wasClick: Bool) {
        moving = false
        if !collapsed { applySizing(); expandedSize = panel.frame.size }
        if collapsed && wasClick { expand() }
        else if let snapEdge { edge = snapEdge; self.snapEdge = nil; collapse() }
        else { recoverScreen(); persist() }
    }
    func resize(to point: CGPoint) {
        guard moving, !collapsed else { return }
        let visible = screen.visibleFrame
        let fromLeft = dockedEdge == "right"
        let availableWidth = fromLeft ? frameStart.maxX - visible.minX : visible.maxX - frameStart.minX
        let width = min(availableWidth, max(Self.minimumSize.width,
            frameStart.width + (point.x - dragStart.x) * (fromLeft ? -1 : 1)))
        let height = min(frameStart.maxY - visible.minY, max(Self.minimumSize.height,
            frameStart.height - (point.y - dragStart.y)))
        panel.setFrame(CGRect(x: fromLeft ? frameStart.maxX - width : frameStart.minX,
                              y: frameStart.maxY - height, width: width, height: height), display: true)
    }
    func restoreTwoRows(animated: Bool = true) {
        guard !collapsed, !moving, let content = panel?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        func collection(in view: NSView) -> ShelfCollection.CollectionView? {
            (view as? ShelfCollection.CollectionView) ?? view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        guard let grid = collection(in: content), let scroll = grid.enclosingScrollView,
              let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        grid.updateLayout(for: scroll.contentView.bounds.width)
        let viewportHeight = 2 * layout.itemSize.height + layout.minimumLineSpacing + layout.sectionInset.top + layout.sectionInset.bottom
        let frame = panel.frame
        let height = max(Self.minimumSize.height, ceil(frame.height - scroll.contentView.bounds.height + viewportHeight))
        let target = Self.constrainedFrame(CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
                                           to: screen.visibleFrame)
        expandedSize = target.size
        if animated { transition(to: target) }
        else { panel.setFrame(target, display: true); applySizing(); persist() }
    }
    func dropHover(_ entered: Bool) {
        hoverTask?.cancel()
        if entered && collapsed {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                self.expand(); self.temporarilyExpanded = true
            }
        } else if !entered && temporarilyExpanded {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, let self, self.temporarilyExpanded else { return }
                self.collapse()
            }
        }
    }
    func dropFinished() { hoverTask?.cancel(); temporarilyExpanded = false }
    func windowDidResize(_ notification: Notification) {
        if !collapsed && timer == nil && !moving { expandedSize = panel.frame.size; persist() }
    }
    func windowDidMove(_ notification: Notification) { if timer == nil && !moving { persist() } }
    @objc private func screensChanged() { recoverScreen(); persist() }
    static func constrainedFrame(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return CGRect(x: min(visible.maxX - size.width, max(visible.minX, frame.minX)),
                      y: min(visible.maxY - size.height, max(visible.minY, frame.minY)), width: size.width, height: size.height)
    }
    func recoverScreen() {
        guard panel != nil else { return }
        let f = panel.frame
        let targetScreen = NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = targetScreen.visibleFrame
        var frame = Self.constrainedFrame(f, to: v)
        if collapsed { frame.origin.x = edge == "left" ? v.minX : v.maxX - frame.width }
        panel.setFrame(frame, display: true)
    }
    func persist() {
        // Keep controls in place while dragging; settle their alignment on release.
        if !moving && timer == nil {
            let frame = panel.frame, visible = screen.visibleFrame
            dockedEdge = collapsed ? edge : (abs(frame.minX - visible.minX) <= 1 ? "left" :
                (abs(frame.maxX - visible.maxX) <= 1 ? "right" : nil))
            if let dockedEdge { edge = dockedEdge }
        }
        defaults.set(NSStringFromRect(panel.frame), forKey: "shelfFrame")
        defaults.set(NSStringFromSize(expandedSize), forKey: "shelfSize")
        defaults.set(collapsed, forKey: "shelfCollapsed")
        defaults.set(edge, forKey: "shelfEdge")
    }
}

struct ShelfMoveHandle: NSViewRepresentable {
    let shelf: ShelfWindow
    var resizing = false
    func makeNSView(context: Context) -> HandleView { HandleView(shelf: shelf, resizing: resizing) }
    func updateNSView(_ view: HandleView, context: Context) { view.window?.invalidateCursorRects(for: view) }
    final class HandleView: NSView {
        let shelf: ShelfWindow
        let resizing: Bool
        var start = CGPoint.zero
        init(shelf: ShelfWindow, resizing: Bool) {
            self.shelf = shelf; self.resizing = resizing; super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(resizing ? .growArea : .button)
            setAccessibilityLabel(resizing ? "Resize shelf" : "Move shelf. Click the edge tab to expand.")
            if resizing { setAccessibilityHelp("Drag to resize. Activate to restore two rows of images.") }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: resizing
                ? .frameResize(position: shelf.dockedEdge == "right" ? .bottomLeft : .bottomRight, directions: .all)
                : .openHand)
        }
        override func mouseDown(with event: NSEvent) {
            start = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            shelf.beginMove(at: start)
            // Keep tracking when expanding replaces the SwiftUI edge-tab handle.
            guard let trackingWindow = window else { return }
            while let next = trackingWindow.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { mouseUp(with: next); break }
                track(to: trackingWindow.convertPoint(toScreen: next.locationInWindow))
            }
        }
        override func mouseDragged(with event: NSEvent) {
            track(to: window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow)
        }
        private func track(to point: CGPoint) {
            if resizing { shelf.resize(to: point) } else { shelf.move(to: point) }
        }
        override func mouseUp(with event: NSEvent) {
            let p = shelf.panel.convertPoint(toScreen: event.locationInWindow)
            shelf.endMove(wasClick: !resizing && hypot(start.x - p.x, start.y - p.y) < 4)
        }
        override func accessibilityPerformPress() -> Bool {
            if resizing { shelf.restoreTwoRows() } else { shelf.expand() }
            return true
        }
    }
}
