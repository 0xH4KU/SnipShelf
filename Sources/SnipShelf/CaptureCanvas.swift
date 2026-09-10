import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class CanvasModel {
    enum Mode: String, CaseIterable { case lasso = "Lasso", polygon = "Polygon" }
    let session: CaptureSession
    let isScreen: Bool
    var mode: Mode = .lasso
    var selecting = false
    var scale: CGFloat = 1
    var offset = CGPoint.zero
    var error: String?
    var resetToken = 0
    var actualSize = false
    var smoothing: Double { didSet { preferences?.set(smoothing, forKey: "lassoSmoothing") } }
    var snapEnabled: Bool { didSet { preferences?.set(snapEnabled, forKey: "lassoSnap") } }
    var snapRadius: Double { didSet { preferences?.set(snapRadius, forKey: "lassoSnapRadius") } }
    var edgeMap: ContourMap?
    let pixelEdges: PixelEdges?
    var reviewImage: CGImage?
    var showCutout = true
    private(set) var reviewPoints: [CGPoint] = []
    private(set) var reviewOrigin = CGPoint.zero
    private(set) var previousOutline: [CGPoint]?
    var restoreToken = 0
    var resumeToken = 0
    var reviewing: Bool { reviewImage != nil }
    var hasOutline: Bool { selecting || reviewing }
    var edgeStatus = "Freehand ready · preparing edge help…"
    private var analyzed = false
    @ObservationIgnored private let preferences: UserDefaults?
    var complete: (CGImage) -> Void
    var cancel: () -> Void
    init(image: CGImage, isScreen: Bool, preferences: UserDefaults? = nil, complete: @escaping (CGImage) -> Void, cancel: @escaping () -> Void) {
        session = CaptureSession(image: image)
        pixelEdges = PixelEdges(image)
        self.preferences = preferences
        smoothing = min(1, max(0, preferences?.object(forKey: "lassoSmoothing") as? Double ?? 0.55))
        snapEnabled = preferences?.object(forKey: "lassoSnap") as? Bool ?? true
        snapRadius = min(24, max(4, preferences?.object(forKey: "lassoSnapRadius") as? Double ?? 10))
        self.isScreen = isScreen; self.complete = complete; self.cancel = cancel
    }
    func analyzeEdges() async {
        guard !analyzed else { return }
        analyzed = true
        let image = session.image
        let task = Task.detached(priority: .userInitiated) { try ContourMap.detect(in: image) }
        await withTaskCancellationHandler {
            do {
                let map = try await task.value
                guard !Task.isCancelled else { return }
                edgeMap = map
                edgeStatus = map.isEmpty ? "Freehand ready" : "Gentle edge help ready"
            } catch {
                guard !Task.isCancelled else { return }
                edgeStatus = "Freehand ready"
            }
        } onCancel: { task.cancel() }
    }
    func reset() {
        if reviewing { previousOutline = reviewPoints }
        reviewImage = nil; selecting = false; error = nil; resetToken += 1
    }
    func prepareReview(points: [CGPoint]) throws {
        reviewImage = try ImageCore.crop(session.image, points: points)
        reviewPoints = points
        reviewOrigin = CGPoint(x: max(0, floor(points.map(\.x).min() ?? 0)),
                               y: max(0, floor(points.map(\.y).min() ?? 0)))
        selecting = false
    }
    func continueSelection() {
        guard reviewing else { return }
        // ponytail: one outline checkpoint; use UndoManager if multi-step editing is needed.
        previousOutline = reviewPoints
        reviewImage = nil; selecting = true; resumeToken += 1
    }
    func undoSelection() {
        guard let points = previousOutline else { return }
        do {
            try prepareReview(points: points)
            previousOutline = nil; error = nil; restoreToken += 1
        } catch { self.error = error.localizedDescription }
    }
    func confirm() {
        guard let image = reviewImage else { return }
        reviewImage = nil
        complete(image)
    }
    func fit() { scale = 1; actualSize = false; offset = .zero }
}

struct CaptureView: View {
    @Bindable var model: CanvasModel
    @State private var toolbarOffset = CGSize.zero
    @State private var toolbarStart = CGSize.zero
    @State private var showAssist = false
    var body: some View {
        GeometryReader { geometry in
            GlassEffectContainer(spacing: 16) {
                ZStack(alignment: .top) {
                    SelectionCanvas(model: model)
                    VStack(spacing: 10) {
                        HStack(spacing: 14) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                .frame(width: 24, height: 28).contentShape(Rectangle())
                                .accessibilityLabel("Move selection toolbar")
                                .help("Drag to move the toolbar")
                                .gesture(DragGesture().onChanged { value in
                                    let limitX = max(0, (geometry.size.width - 600) / 2)
                                    toolbarOffset = CGSize(width: min(limitX, max(-limitX, toolbarStart.width + value.translation.width)),
                                                           height: min(max(0, geometry.size.height - 200), max(0, toolbarStart.height + value.translation.height)))
                                }.onEnded { _ in toolbarStart = toolbarOffset })
                            if model.reviewing {
                                Picker("Review", selection: $model.showCutout) {
                                    Text("Original").tag(false)
                                    Text("Cutout").tag(true)
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                            } else {
                                Picker("Selection", selection: $model.mode) {
                                    ForEach(CanvasModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 160).disabled(model.selecting)
                            }
                            Button { showAssist.toggle() } label: { Image(systemName: "wand.and.stars") }
                                .help("Selection assistance").accessibilityLabel("Selection assistance")
                                .disabled(model.selecting).popover(isPresented: $showAssist) { assistance }
                            Divider().frame(height: 18)
                            Button("Fit") { model.fit() }.help("Fit image").disabled(model.selecting)
                            Button("100%") { model.actualSize = true; model.scale = 1; model.offset = .zero }.disabled(model.selecting)
                            Button { model.scale = max(0.1, model.scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                                .help("Zoom out").accessibilityLabel("Zoom out").disabled(model.selecting)
                            Button { model.scale = min(16, model.scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                                .help("Zoom in").accessibilityLabel("Zoom in").disabled(model.selecting)
                            Divider().frame(height: 18)
                            Button { model.undoSelection() } label: { Image(systemName: "arrow.uturn.backward") }
                                .help("Undo last refinement (⌘Z)").accessibilityLabel("Undo last refinement")
                                .disabled(model.previousOutline == nil).keyboardShortcut("z", modifiers: .command)
                            Button { model.cancel() } label: { Image(systemName: "xmark") }
                                .help("Cancel (Esc)").accessibilityLabel("Cancel capture").keyboardShortcut(.cancelAction)
                        }.buttonStyle(.borderless).controlSize(.regular)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                        Text(hint)
                            .font(.callout).foregroundStyle(model.error == nil ? Color.secondary : Color.primary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule()).allowsHitTesting(false)
                    }.padding(.top, 18).offset(toolbarOffset)
                    VStack {
                        Spacer()
                        if model.reviewing {
                            HStack(spacing: 12) {
                                Button("Redraw", systemImage: "arrow.counterclockwise") { model.reset() }
                                    .help("Start again · ⌘Z restores this outline")
                                Button("Refine", systemImage: "pencil.tip") { model.continueSelection() }
                                    .help("Drag from the outline to retrace · ⌘Z restores the previous outline")
                                Divider().frame(height: 22)
                                Button("Keep Clip", systemImage: "checkmark") { model.confirm() }
                                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                                    .help("Save this cutout to the shelf (Return)")
                            }.buttonStyle(.bordered).controlSize(.large)
                                .padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
                        } else if model.hasOutline {
                            Button("Redraw", systemImage: "arrow.counterclockwise") { model.reset() }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                    }.padding(.bottom, 22)
                }
            }
        }.task { await model.analyzeEdges() }
    }
    private var hint: String {
        if let error = model.error { return error }
        if model.reviewing { return "Compare the cutout · Refine the edge · Return to keep" }
        if model.previousOutline != nil && model.selecting { return "Retrace or redraw · ⌘Z restores the previous outline" }
        return model.mode == .lasso ? "Draw around an element · Release to review · ⌥ bypasses edge help" : "Click to add points · Return to review · Delete to undo"
    }
    private var assistance: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selection Assistance").font(.headline)
            Text(model.edgeStatus).font(.caption).foregroundStyle(.secondary)
            Picker("Tool", selection: $model.mode) {
                ForEach(CanvasModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle(model.mode == .lasso ? "Gentle edge help" : "Snap to edges", isOn: $model.snapEnabled)
            if model.mode == .polygon {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Snap distance"); Spacer(); Text("\(Int(model.snapRadius)) pt").foregroundStyle(.secondary) }
                    Slider(value: $model.snapRadius, in: 4...24, step: 1).accessibilityLabel("Snap distance")
                }.disabled(!model.snapEnabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Steadiness"); Spacer(); Text(model.smoothing == 0 ? "Off" : "\(Int(model.smoothing * 100))%").foregroundStyle(.secondary) }
                Slider(value: $model.smoothing, in: 0...1).accessibilityLabel("Steadiness")
            }
            Text(model.mode == .lasso ? "Hold Option to bypass edge help. Steadiness stays on." : "Tab switches nearby edges. Option bypasses snapping.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 270)
    }
}

struct SelectionCanvas: NSViewRepresentable {
    var model: CanvasModel
    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(model: model) }
    func updateNSView(_ view: CanvasNSView, context: Context) {
        _ = model.scale; _ = model.offset; _ = model.actualSize; _ = model.mode; _ = model.resetToken; _ = model.edgeMap; _ = model.reviewImage; _ = model.resumeToken; _ = model.restoreToken; _ = model.showCutout
        view.refresh()
    }
}

final class CanvasNSView: NSView {
    let model: CanvasModel
    private(set) var points: [CGPoint] = []
    private var hover: CGPoint?
    private var seenReset = 0
    private var tracking: NSTrackingArea?
    private let displayImage: NSImage
    private var stabilizer = LassoStabilizer()
    private var strokeEdges: ContourMap?
    private var previousHit: ContourMap.Hit?
    private var snappedPoint: CGPoint?
    private var optionDown = false
    private var strokeBounds = CGRect.null
    private var seenResume = 0
    private var seenRestore = 0
    private var reviewPicture: NSImage?
    private var displayedReview: CGImage?
    private var continuing = false
    private var draggingLasso = false
    private var alternatives: [ContourMap.Hit] = []
    private var alternativeIndex = 0
    private var lastPointer: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: CanvasModel) {
        self.model = model
        displayImage = NSImage(cgImage: model.session.image, size: .zero)
        super.init(frame: .zero)
        if model.reviewing { points = model.reviewPoints }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image selection canvas")
        setAccessibilityHelp("Choose Lasso and draw freely, or Polygon and click points. Release or press Return to review. Compare Original and Cutout. Keep Clip saves; Refine retraces; Redraw clears the outline. Command-Z restores the previous outline. Escape cancels.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    func refresh() {
        if !model.snapEnabled { previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil }
        if seenResume != model.resumeToken {
            seenResume = model.resumeToken; continuing = true; draggingLasso = false; lastPointer = nil
            previousHit = nil; snappedPoint = nil; alternatives = []; stabilizer.reset()
            strokeEdges = model.edgeMap
            window?.makeFirstResponder(self)
        }
        if seenReset != model.resetToken { points.removeAll(); lastPointer = nil; alternatives = []; continuing = false; draggingLasso = false; hover = nil; previousHit = nil; snappedPoint = nil; stabilizer.reset(); seenReset = model.resetToken }
        if seenRestore != model.restoreToken {
            seenRestore = model.restoreToken; points = model.reviewPoints
            continuing = false; draggingLasso = false; hover = nil
            previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil; stabilizer.reset()
            window?.makeFirstResponder(self)
        }
        if displayedReview !== model.reviewImage {
            displayedReview = model.reviewImage
            reviewPicture = model.reviewImage.map { NSImage(cgImage: $0, size: .zero) }
        }
        needsDisplay = true
    }
    var imageRect: CGRect {
        let image = model.session.image
        let fitting = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let scale = (model.actualSize ? 1 / (window?.backingScaleFactor ?? 1) : fitting) * model.scale
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2 + model.offset.x,
                      y: (bounds.height - size.height) / 2 + model.offset.y, width: size.width, height: size.height)
    }
    private func canvasPoint(_ p: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + p.x * rect.width / CGFloat(model.session.image.width),
                       y: rect.minY + p.y * rect.height / CGFloat(model.session.image.height))
    }
    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let p = model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect)
        return CGPoint(x: min(CGFloat(model.session.image.width), max(0, p.x)),
                       y: min(CGFloat(model.session.image.height), max(0, p.y)))
    }
    override func draw(_ dirtyRect: NSRect) {
        if model.reviewing, model.showCutout, let image = model.reviewImage {
            // Keep the cutout registered with the original while comparing and zooming.
            let p = canvasPoint(model.reviewOrigin)
            let rect = CGRect(x: p.x, y: p.y, width: CGFloat(image.width) / pixelsPerPoint,
                              height: CGFloat(image.height) / pixelsPerPoint)
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
            let visible = rect.intersection(bounds)
            if !visible.isNull {
                for y in stride(from: floor(visible.minY / 10) * 10, through: visible.maxY, by: 10) {
                    for x in stride(from: floor(visible.minX / 10) * 10, through: visible.maxX, by: 10) where (Int(x / 10) + Int(y / 10)) % 2 == 0 {
                        CGRect(x: x, y: y, width: 10, height: 10).intersection(rect).fill()
                    }
                }
            }
            reviewPicture?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        if !model.isScreen {
            let square: CGFloat = 16
            let clipped = imageRect.intersection(bounds)
            NSColor(calibratedWhite: 0.24, alpha: 1).setFill(); clipped.fill()
            NSColor(calibratedWhite: 0.29, alpha: 1).setFill()
            if !clipped.isNull {
                for y in stride(from: Int(clipped.minY / square), through: Int(clipped.maxY / square), by: 1) {
                    for x in stride(from: Int(clipped.minX / square), through: Int(clipped.maxX / square), by: 1) where (x + y) % 2 == 0 {
                        CGRect(x: CGFloat(x) * square, y: CGFloat(y) * square, width: square, height: square).intersection(clipped).fill()
                    }
                }
            }
        }
        displayImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let path = NSBezierPath()
        if let first = points.first {
            path.move(to: canvasPoint(first))
            for p in points.dropFirst() { path.line(to: canvasPoint(p)) }
            if model.mode == .polygon, !model.reviewing, let hover { path.line(to: canvasPoint(hover)) }
            if model.reviewing { path.close() }
        }
        let shade = NSBezierPath(rect: bounds)
        if points.count > 2 { let fill = path.copy() as! NSBezierPath; fill.close(); shade.append(fill) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(model.reviewing ? 0.5 : (model.selecting ? 0.22 : 0.12)).setFill(); shade.fill()
        if !points.isEmpty {
            path.lineJoinStyle = .round; path.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.55).setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1.4; path.stroke()
            if !model.reviewing, let first = points.first, let last = points.last, points.count > 2 {
                let connector = NSBezierPath()
                connector.move(to: canvasPoint(model.mode == .polygon ? (hover ?? last) : last))
                connector.line(to: canvasPoint(first))
                connector.setLineDash([4, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.45).setStroke(); connector.lineWidth = 1; connector.stroke()
            }
            if let first = points.first {
                let p = canvasPoint(first)
                NSColor.white.setStroke()
                NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).stroke()
            }
            if model.mode == .polygon {
                for point in points {
                    let p = canvasPoint(point)
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)).fill()
                }
            }
        }
        if let snappedPoint {
            let p = canvasPoint(snappedPoint)
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            ring.lineWidth = 2; ring.stroke()
        }
    }
    private var pixelsPerPoint: CGFloat { CGFloat(model.session.image.width) / max(1, imageRect.width) }
    private func edgeCandidates(at point: CGPoint) -> [ContourMap.Hit] {
        let radius = CGFloat(model.snapRadius) * pixelsPerPoint
        let contours = strokeEdges?.candidates(to: point, radius: radius, previous: previousHit) ?? []
        let movement = lastPointer.map { CGPoint(x: point.x - $0.x, y: point.y - $0.y) } ?? .zero
        // Pixels are a fallback, never a competing source while a contour is available.
        let candidates = contours.isEmpty
            ? (model.pixelEdges?.candidates(to: point, radius: radius, previous: previousHit, movement: movement) ?? [])
            : contours
        var result: [ContourMap.Hit] = []
        for hit in candidates {
            if result.allSatisfy({ hypot($0.point.x - hit.point.x, $0.point.y - hit.point.y) > 2 * pixelsPerPoint }) { result.append(hit) }
            if result.count == 6 { break }
        }
        return result
    }
    private func assisted(_ raw: CGPoint, smoothing: Bool, bypass: Bool) -> CGPoint {
        let input = smoothing ? stabilizer.append(raw, strength: CGFloat(model.smoothing), pixelsPerPoint: pixelsPerPoint) : raw
        defer { lastPointer = input }
        guard model.snapEnabled, !bypass else {
            previousHit = nil; snappedPoint = nil; alternatives = []
            return input
        }
        if model.mode == .lasso {
            previousHit = nil; snappedPoint = nil; alternatives = []
            let movement = lastPointer.map { CGPoint(x: input.x - $0.x, y: input.y - $0.y) } ?? .zero
            return strokeEdges?.nudged(input, movement: movement, pixelsPerPoint: pixelsPerPoint) ?? input
        }
        alternatives = edgeCandidates(at: input); alternativeIndex = 0
        guard let hit = alternatives.first else { previousHit = nil; snappedPoint = nil; return input }
        previousHit = hit; snappedPoint = hit.point
        return hit.point
    }
    private func appendLasso(_ event: NSEvent) {
        if let old = snappedPoint { setNeedsDisplay(ringRect(old)) }
        let point = assisted(pixelPoint(event), smoothing: true, bypass: event.modifierFlags.contains(.option))
        if points.last.map({ hypot(point.x - $0.x, point.y - $0.y) >= 0.4 * pixelsPerPoint }) ?? true {
            points.append(point)
            strokeBounds = strokeBounds.union(ringRect(point))
        }
        setNeedsDisplay(strokeBounds)
        if let snappedPoint { setNeedsDisplay(ringRect(snappedPoint)) }
    }
    private func ringRect(_ point: CGPoint) -> CGRect {
        let p = canvasPoint(point)
        return CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)
    }
    override func flagsChanged(with event: NSEvent) {
        optionDown = event.modifierFlags.contains(.option)
        if optionDown { previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        refresh()
        window?.makeFirstResponder(self)
        guard !model.reviewing else { return }
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        model.error = nil
        optionDown = event.modifierFlags.contains(.option)
        if !model.selecting || (model.mode == .lasso && !continuing) {
            stabilizer.reset()
            // Freeze detection for this stroke; an arriving Vision result must not bend a stroke in progress.
            strokeEdges = model.edgeMap
        }
        let point = assisted(pixelPoint(event), smoothing: model.mode == .lasso, bypass: optionDown)
        if continuing {
            points = LassoPath.continuing(points, near: point, radius: 12 * pixelsPerPoint)
            strokeBounds = points.reduce(CGRect.null) { $0.union(ringRect($1)) }
            continuing = false
        } else if model.mode == .lasso { points = [point]; strokeBounds = ringRect(point) }
        else {
            if points.count >= 3, let first = points.first,
               hypot(canvasPoint(first).x - canvasPoint(point).x, canvasPoint(first).y - canvasPoint(point).y) < 9 {
                finish(); return
            }
            points.append(point)
        }
        model.selecting = true
        draggingLasso = model.mode == .lasso
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard draggingLasso, model.selecting else { return }
        appendLasso(event)
    }
    override func mouseUp(with event: NSEvent) {
        if draggingLasso, model.selecting {
            draggingLasso = false
            appendLasso(event)
            finish()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard !model.reviewing else { return }
        let oldSnap = snappedPoint
        hover = pixelPoint(event)
        if !model.selecting, model.snapEnabled, !event.modifierFlags.contains(.option) {
            strokeEdges = model.edgeMap
            hover = assisted(hover!, smoothing: false, bypass: false)
        } else if model.mode == .polygon, model.selecting {
            hover = assisted(hover!, smoothing: false, bypass: event.modifierFlags.contains(.option))
        } else if !model.selecting { previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil }
        if model.selecting { needsDisplay = true }
        else {
            if let oldSnap { setNeedsDisplay(ringRect(oldSnap)) }
            if let snappedPoint { setNeedsDisplay(ringRect(snappedPoint)) }
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            model.undoSelection(); refresh(); return
        }
        switch event.keyCode {
        case 53: model.cancel()
        case 36, 76:
            if model.reviewing { model.confirm() }
            else if model.mode == .polygon || continuing { finish() }
        case 48:
            guard model.mode == .polygon, !model.reviewing, model.snapEnabled, !optionDown, alternatives.count > 1 else { return }
            alternativeIndex = (alternativeIndex + 1) % alternatives.count
            let hit = alternatives[alternativeIndex]
            previousHit = hit; snappedPoint = hit.point; hover = hit.point
            if model.selecting && !points.isEmpty { points[points.count - 1] = hit.point }
            needsDisplay = true
        case 51, 117:
            if model.reviewing { model.reset(); refresh(); return }

            if !points.isEmpty { points.removeLast(); model.selecting = !points.isEmpty; needsDisplay = true }
        default: super.keyDown(with: event)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            model.undoSelection(); refresh(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard !model.selecting else { return }
        model.offset.x -= event.scrollingDeltaX
        model.offset.y -= event.scrollingDeltaY
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard !model.selecting else { return }
        model.scale = min(16, max(0.1, model.scale * (1 + event.magnification)))
        needsDisplay = true
    }
    private func finish() {
        do { try model.prepareReview(points: points); snappedPoint = nil; hover = nil; needsDisplay = true }
        catch { model.error = error.localizedDescription; points.removeAll(); previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil; stabilizer.reset(); model.selecting = false; needsDisplay = true }
    }
}
