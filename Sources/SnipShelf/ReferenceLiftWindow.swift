import AppKit

/// A small image stack follows the pointer; the full reference is created only on release.
final class ReferenceLiftWindow: NSPanel {
    let sourceFrame: CGRect
    let sourceWindowFrame: CGRect
    private(set) var destinationFrame: CGRect?
    private weak var sourceView: NSView?
    private let preview: ReferenceLiftPreview
    private var outside: Bool?
    private var transitionTimer: Timer?

    init?(source: NSView) {
        guard let card = source as? ShelfCollection.CardView, let window = source.window else { return nil }
        sourceFrame = window.convertToScreen(source.convert(source.bounds, to: nil))
        sourceWindowFrame = window.frame
        sourceView = source
        preview = ReferenceLiftPreview(card: card)
        super.init(contentRect: sourceFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        ignoresMouseEvents = true; hidesOnDeactivate = false
        appearance = source.effectiveAppearance
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = preview
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showDestination(outside: Bool) {
        guard self.outside != outside else { return }
        self.outside = outside
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            preview.badge.animator().alphaValue = outside ? 1 : 0
        }
    }

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
            panel.referenceTransition?.stop()
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
        let start = frame, panelStart = panel?.frame ?? frame
        let panelAlpha = panel?.alphaValue ?? 0, sourceAlpha = sourceView?.alphaValue ?? 1
        let begun = ProcessInfo.processInfo.systemUptime
        // Like the Shelf's own transition, advance both windows on one clock, even during another drag.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [self, weak panel] _ in
            MainActor.assumeIsolated {
                if let panel, panel.referenceTransition !== self || !panel.isVisible {
                    self.stop(); return
                }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - begun) / (reduceMotion ? 0.1 : 0.3))
                let eased = 1 - pow(1 - t, 3)
                func interpolate(_ frame: CGRect) -> CGRect {
                    CGRect(x: frame.minX + (destination.minX - frame.minX) * eased,
                           y: frame.minY + (destination.minY - frame.minY) * eased,
                           width: frame.width + (destination.width - frame.width) * eased,
                           height: frame.height + (destination.height - frame.height) * eased)
                }
                if !reduceMotion {
                    self.setFrame(interpolate(start), display: true)
                    panel?.setFrame(interpolate(panelStart), display: true)
                }
                self.alphaValue = 1 - eased
                panel?.alphaValue = panelAlpha + (1 - panelAlpha) * eased
                self.sourceView?.alphaValue = sourceAlpha + (1 - sourceAlpha) * eased
                if t >= 1 {
                    if panel?.referenceTransition === self { panel?.referenceTransition = nil }
                    self.stop()
                }
            }
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stop() {
        transitionTimer?.invalidate(); transitionTimer = nil
        sourceView?.alphaValue = 1
        close()
    }
}

private final class ReferenceLiftPreview: NSView {
    let badge = NSView()
    private let icon = NSImageView()
    private let image: NSImage?
    private let related: [NSImage?]
    private let caption: String
    override var isFlipped: Bool { true }

    init(card: ShelfCollection.CardView) {
        image = card.picture.image
        related = card.folderID == nil ? [] : card.related.map(\.image)
        caption = card.caption.stringValue
        super.init(frame: CGRect(origin: .zero, size: card.bounds.size))
        wantsLayer = true
        badge.wantsLayer = true
        badge.layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        badge.shadow = shadow
        badge.alphaValue = 0
        icon.image = ReferencePinButton.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        badge.addSubview(icon)
        addSubview(badge)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private var paper: NSColor { dark ? NSColor(srgbRed: 0.188, green: 0.192, blue: 0.204, alpha: 1) : NSColor(white: 0.99, alpha: 1) }
    private var raised: NSColor { dark ? NSColor(srgbRed: 0.204, green: 0.208, blue: 0.22, alpha: 1) : .white }
    private var line: NSColor { NSColor(white: dark ? 0.30 : 0.84, alpha: 1) }
    private var muted: NSColor { NSColor(white: dark ? 0.67 : 0.43, alpha: 1) }
    // Leave room for the rotated sheets and corner badge without changing the grab offset.
    private var scale: CGFloat { min(bounds.width / 168, bounds.height / 202) }
    private var origin: CGPoint { CGPoint(x: (bounds.width - 148 * scale) / 2, y: (bounds.height - 182 * scale) / 2) }

    override func layout() {
        super.layout()
        badge.frame = CGRect(x: origin.x + 125 * scale, y: origin.y + 159 * scale, width: 28 * scale, height: 28 * scale)
        badge.layer?.cornerRadius = badge.bounds.width / 2
        icon.frame = badge.bounds.insetBy(dx: 5.5 * scale, dy: 5.5 * scale)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        badge.layer?.backgroundColor = raised.cgColor
        badge.layer?.borderColor = line.cgColor
        icon.contentTintColor = muted
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.scale(by: scale)
        transform.concat()
        for (index, image) in related.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let rotation = NSAffineTransform()
            rotation.translateX(by: 74 + (index == 0 ? 4 : -4), yBy: 90.5 - (index == 0 ? 4 : 3))
            rotation.rotate(byDegrees: index == 0 ? 6 : -5)
            rotation.translateX(by: -74, yBy: -90.5)
            rotation.concat()
            let frame = CGRect(x: 4, y: 4, width: 140, height: 173)
            drawSheet(frame, color: raised)
            drawImage(image, in: frame.insetBy(dx: 18, dy: 18), opacity: 0.72)
            NSGraphicsContext.restoreGraphicsState()
        }
        let face = CGRect(x: 4, y: 5, width: 140, height: 174)
        drawSheet(face, color: paper)
        drawImage(image, in: CGRect(x: 14, y: 17, width: 120, height: 130))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (caption as NSString).draw(in: CGRect(x: 16, y: 155, width: 104, height: 14), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted, .paragraphStyle: paragraph
        ])
    }

    private func drawSheet(_ frame: CGRect, color: NSColor) {
        let path = NSBezierPath(roundedRect: frame, xRadius: 13, yRadius: 13)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.28 : 0.12)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        shadow.set()
        color.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        line.setStroke(); path.lineWidth = 1; path.stroke()
    }

    private func drawImage(_ image: NSImage?, in frame: CGRect, opacity: CGFloat = 1) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let artwork = image.withSymbolConfiguration(.init(paletteColors: [muted])) ?? image
        let fit = min(frame.width / image.size.width, frame.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        artwork.draw(in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}
