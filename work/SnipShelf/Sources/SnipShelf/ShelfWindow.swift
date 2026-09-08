import AppKit
import SwiftUI
import Observation

final class ShelfPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor @Observable
final class ShelfWindow: NSObject, NSWindowDelegate {
    var collapsed = false
    var edge = "right"
    var snapEdge: String?
    var dropTargeted = false
    var panel: ShelfPanel!
    private var expandedSize = CGSize(width: 340, height: 440)
    private var timer: Timer?
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
        if let size = defaults.string(forKey: "shelfSize") { expandedSize = NSSizeFromString(size) }
        expandedSize.width = min(usable.width, max(300, expandedSize.width))
        expandedSize.height = min(usable.height, max(280, expandedSize.height))
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
        panel.hasShadow = true
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
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    var screen: NSScreen {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) }
            ?? panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private func applySizing() {
        panel.minSize = collapsed ? CGSize(width: 24, height: 88) : CGSize(width: 300, height: 280)
        if collapsed { panel.styleMask.remove(.resizable) } else { panel.styleMask.insert(.resizable) }
    }
    private func dockedFrame(collapsed: Bool) -> CGRect {
        let visible = screen.visibleFrame
        let size = collapsed ? CGSize(width: 24, height: 88) : expandedSize
        return CGRect(x: edge == "left" ? visible.minX : visible.maxX - size.width,
                      y: min(visible.maxY - size.height, max(visible.minY, panel.frame.midY - size.height / 2)),
                      width: min(size.width, visible.width), height: min(size.height, visible.height))
    }
    func collapse() {
        guard !collapsed else { return }
        let wasAnimating = timer != nil
        timer?.invalidate(); timer = nil
        if !wasAnimating { expandedSize = panel.frame.size }
        collapsed = true; temporarilyExpanded = false
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
            panel.setFrame(target, display: true); applySizing(); persist(); timer = nil; return
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
        timer?.invalidate(); timer = nil
        if !collapsed { panel.setFrame(CGRect(origin: panel.frame.origin, size: expandedSize), display: true); applySizing() }
        moving = true
        temporarilyExpanded = false
        dragStart = point; frameStart = panel.frame
    }
    func move(to p: CGPoint) {
        let dx = p.x - dragStart.x, dy = p.y - dragStart.y
        if collapsed {
            let inward = edge == "left" ? dx > 16 : dx < -16
            if inward { expand(); moving = false; return }
            let visible = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: min(visible.maxY - 88, max(visible.minY, frameStart.minY + dy))))
        } else if moving {
            panel.setFrameOrigin(CGPoint(x: frameStart.minX + dx, y: frameStart.minY + dy))
            let visible = screen.visibleFrame
            snapEdge = panel.frame.minX <= visible.minX + 30 ? "left" :
                (panel.frame.maxX >= visible.maxX - 30 ? "right" : nil)
        }
    }
    func endMove(wasClick: Bool) {
        moving = false
        if collapsed && wasClick { expand() }
        else if let snapEdge { edge = snapEdge; self.snapEdge = nil; collapse() }
        else { recoverScreen(); persist() }
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
    func recoverScreen() {
        guard panel != nil else { return }
        let f = panel.frame
        let targetScreen = NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = targetScreen.visibleFrame
        let width = min(f.width, v.width), height = min(f.height, v.height)
        var x = min(v.maxX - width, max(v.minX, f.minX))
        if collapsed { x = edge == "left" ? v.minX : v.maxX - width }
        panel.setFrame(CGRect(x: x, y: min(v.maxY - height, max(v.minY, f.minY)), width: width, height: height), display: true)
    }
    func persist() {
        defaults.set(NSStringFromRect(panel.frame), forKey: "shelfFrame")
        defaults.set(NSStringFromSize(expandedSize), forKey: "shelfSize")
        defaults.set(collapsed, forKey: "shelfCollapsed")
        defaults.set(edge, forKey: "shelfEdge")
    }
}

struct ShelfMoveHandle: NSViewRepresentable {
    let shelf: ShelfWindow
    func makeNSView(context: Context) -> HandleView { HandleView(shelf: shelf) }
    func updateNSView(_ view: HandleView, context: Context) {}
    final class HandleView: NSView {
        let shelf: ShelfWindow
        var start = CGPoint.zero
        init(shelf: ShelfWindow) {
            self.shelf = shelf; super.init(frame: .zero)
            setAccessibilityElement(true); setAccessibilityRole(.button)
            setAccessibilityLabel("Move shelf. Click the edge tab to expand.")
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            start = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            shelf.beginMove(at: start)
        }
        override func mouseDragged(with event: NSEvent) {
            shelf.move(to: window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow)
        }
        override func mouseUp(with event: NSEvent) {
            let p = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            shelf.endMove(wasClick: hypot(start.x - p.x, start.y - p.y) < 4)
        }
        override func accessibilityPerformPress() -> Bool { shelf.expand(); return true }
    }
}
