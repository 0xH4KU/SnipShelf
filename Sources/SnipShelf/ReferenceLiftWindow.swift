import AppKit

/// One small snapshot follows the pointer; the full reference is created only on release.
final class ReferenceLiftWindow: NSPanel {
    let sourceFrame: CGRect
    let sourceWindowFrame: CGRect
    private(set) var destinationFrame: CGRect?
    private weak var sourceView: NSView?

    init?(source: NSView) {
        guard let window = source.window,
              let bitmap = source.bitmapImageRepForCachingDisplay(in: source.bounds) else { return nil }
        source.cacheDisplay(in: source.bounds, to: bitmap)
        let image = NSImage(size: source.bounds.size)
        image.addRepresentation(bitmap)
        sourceFrame = window.convertToScreen(source.convert(source.bounds, to: nil))
        sourceWindowFrame = window.frame
        sourceView = source
        super.init(contentRect: sourceFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        ignoresMouseEvents = true; hidesOnDeactivate = false
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let material = NSVisualEffectView(frame: CGRect(origin: .zero, size: sourceFrame.size))
        material.material = .popover; material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14; material.layer?.masksToBounds = true
        let preview = NSImageView(frame: material.bounds)
        preview.image = image; preview.imageScaling = .scaleProportionallyUpOrDown
        preview.autoresizingMask = [.width, .height]
        material.addSubview(preview)
        contentView = material
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func follow(from start: CGPoint, to point: CGPoint) {
        // Preserve the exact grab offset; easing here would make the card lag behind the pointer.
        setFrameOrigin(sourceFrame.origin.applying(CGAffineTransform(translationX: point.x - start.x, y: point.y - start.y)))
        if !isVisible {
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                sourceView?.animator().alphaValue = 0.45
            }
        }
    }

    func finish(at destination: CGRect, revealing panel: ShelfPanel? = nil) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        destinationFrame = destination
        if let panel {
            panel.referenceTransition = self
            panel.animationBehavior = .none
            if !panel.isVisible {
                // Both surfaces grow from the same card-sized frame, so no full-size window appears behind the card.
                panel.setFrame(reduceMotion ? destination : frame, display: false)
                panel.alphaValue = 0
            }
            if reduceMotion { panel.setFrame(destination, display: true) }
            panel.makeKeyAndOrderFront(nil)
        }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
            if !reduceMotion {
                animator().setFrame(destination, display: true)
                panel?.animator().setFrame(destination, display: true)
            }
            animator().alphaValue = 0
            panel?.animator().alphaValue = 1
            sourceView?.animator().alphaValue = 1
        } completionHandler: {
            // Never re-show or reposition the real window here: it may already have been grabbed or closed.
            if panel?.referenceTransition === self { panel?.referenceTransition = nil }
            self.close()
        }
    }
}
