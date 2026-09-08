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
    var resumeToken = 0
    var reviewing: Bool { reviewImage != nil }
    var hasOutline: Bool { selecting || reviewing }
    var edgeStatus = "Pixel edges ready · refining contours…"
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
                edgeStatus = map.isEmpty ? "Using local pixel edges" : "Edges ready · Tab switches · ⌥ bypasses"
            } catch {
                guard !Task.isCancelled else { return }
                edgeStatus = "Using local pixel edges"
            }
        } onCancel: { task.cancel() }
    }
    func reset() { reviewImage = nil; selecting = false; error = nil; resetToken += 1 }
    func prepareReview(points: [CGPoint]) throws {
        reviewImage = try ImageCore.crop(session.image, points: points)
        selecting = false
    }
    func continueSelection() {
        guard reviewing else { return }
        reviewImage = nil; selecting = true; resumeToken += 1
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
        ZStack(alignment: .top) {
            SelectionCanvas(model: model)
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        .frame(width: 24, height: 26).contentShape(Rectangle())
                        .help("Drag to move the selection toolbar")
                        .gesture(DragGesture().onChanged { value in
                            let limitX = max(0, (geometry.size.width - 620) / 2)
                            toolbarOffset = CGSize(width: min(limitX, max(-limitX, toolbarStart.width + value.translation.width)),
                                                   height: min(max(0, geometry.size.height - 190), max(0, toolbarStart.height + value.translation.height)))
                        }.onEnded { _ in toolbarStart = toolbarOffset })
                    Picker("Selection", selection: $model.mode) {
                        ForEach(CanvasModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 155).disabled(model.selecting)
                    Button { showAssist.toggle() } label: {
                        Image(systemName: model.snapEnabled ? "wand.and.stars" : "slider.horizontal.3")
                    }.help("Lasso assistance · \(model.edgeStatus)").accessibilityLabel("Lasso assistance")
                        .disabled(model.selecting)
                        .popover(isPresented: $showAssist) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Lasso assistance").font(.headline)
                                Text(model.edgeStatus).font(.caption).foregroundStyle(.secondary)
                                Toggle("Snap to edges", isOn: $model.snapEnabled)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text("Snap distance"); Spacer(); Text("\(Int(model.snapRadius)) pt").foregroundStyle(.secondary) }
                                    Slider(value: $model.snapRadius, in: 4...24, step: 1).accessibilityLabel("Snap distance")
                                }.disabled(!model.snapEnabled)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text("Steadiness"); Spacer(); Text(model.smoothing == 0 ? "Off" : "\(Int(model.smoothing * 100))%").foregroundStyle(.secondary) }
                                    Slider(value: $model.smoothing, in: 0...1).accessibilityLabel("Steadiness")
                                }
                                Text("Slow strokes are steadied; quick movements stay responsive. Hold Option to bypass snapping.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.padding(20).frame(width: 270)
                        }
                    Group {
                        Button("Fit") { model.fit() }.disabled(model.selecting).help("Fit image · scroll to pan · pinch to zoom")
                        Button("100%") { model.actualSize = true; model.scale = 1; model.offset = .zero }.disabled(model.selecting)
                        Button { model.scale = max(0.1, model.scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                            .help("Zoom out").disabled(model.selecting)
                        Button { model.scale = min(16, model.scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                            .help("Zoom in").disabled(model.selecting)
                    }
                    Divider().frame(height: 18)
                    Button("Reset") { model.reset() }.disabled(!model.hasOutline && model.error == nil)
                    Button { model.cancel() } label: { Image(systemName: "xmark") }.help("Cancel (Esc)").keyboardShortcut(.cancelAction)
                }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 12)
                    .glassEffect(.regular, in: Capsule())
                Text(model.error ?? (model.mode == .lasso ? "Draw freely · release to review · Tab switches edges · ⌥ bypasses" : "Click points · Return to review · Delete to undo"))
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular, in: Capsule())
                    .allowsHitTesting(false)
            }.padding(.top, 18).offset(toolbarOffset)
            if model.reviewing {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        reviewButton("Delete", icon: "trash", color: .red) { model.reset() }
                            .help("Discard this selection and start again")
                        reviewButton("Continue", icon: "pencil.tip", color: .yellow) { model.continueSelection() }
                            .help("Keep the path. Drag from its outline to retrace, or extend from its end")
                        reviewButton("Confirm", icon: "checkmark", color: .green) { model.confirm() }
                            .keyboardShortcut(.defaultAction).help("Add this clip to the shelf")
                    }.padding(12).glassEffect(.regular, in: Capsule())
                    Text("Nothing is added to the shelf until you confirm.")
                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }.padding(.bottom, 22)
            }
        }
        }.task { await model.analyzeEdges() }
    }
    private func reviewButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8)).frame(width: 27, height: 27).background(color, in: Circle())
                Text(title).font(.system(size: 13, weight: .semibold))
            }.padding(.horizontal, 10).padding(.vertical, 4)
        }.buttonStyle(.plain).accessibilityLabel(title + " selection")
    }
}

struct SelectionCanvas: NSViewRepresentable {
    var model: CanvasModel
    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(model: model) }
    func updateNSView(_ view: CanvasNSView, context: Context) {
        _ = model.scale; _ = model.offset; _ = model.actualSize; _ = model.mode; _ = model.resetToken; _ = model.edgeMap; _ = model.reviewImage; _ = model.resumeToken
        view.refresh()
    }
}

final class CanvasNSView: NSView {
    let model: CanvasModel
    private var points: [CGPoint] = []
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
    private var continuing = false
    private var draggingLasso = false
    private var alternatives: [ContourMap.Hit] = []
    private var alternativeIndex = 0
    private var lastPointer: CGPoint?
    private var manualTarget: (edge: CGPoint, pointer: CGPoint)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: CanvasModel) {
        self.model = model
        displayImage = NSImage(cgImage: model.session.image, size: .zero)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image selection canvas")
        setAccessibilityHelp("Choose Lasso and drag, or Polygon and click points. Release or press Return to review. Tab switches edges. Confirm saves; Continue retraces; Delete discards the current selection. Escape cancels.")
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
        if !model.snapEnabled { snappedPoint = nil }
        if seenResume != model.resumeToken {
            seenResume = model.resumeToken; continuing = true; draggingLasso = false; manualTarget = nil
            previousHit = nil; snappedPoint = nil; stabilizer.reset()
            window?.makeFirstResponder(self)
        }
        if seenReset != model.resetToken { points.removeAll(); manualTarget = nil; continuing = false; draggingLasso = false; hover = nil; previousHit = nil; snappedPoint = nil; stabilizer.reset(); seenReset = model.resetToken }
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
        let pixels = model.pixelEdges?.candidates(to: point, radius: radius) ?? []
        func score(_ hit: ContourMap.Hit) -> CGFloat {
            hit.distance + (hit.contour < 0 ? pixelsPerPoint : 0)
                - (hit.contour >= 0 && hit.contour == previousHit?.contour ? radius * 0.15 : 0)
        }
        let sorted = (contours + pixels).sorted { score($0) < score($1) }
        var result: [ContourMap.Hit] = []
        for hit in sorted {
            if result.allSatisfy({ hypot($0.point.x - hit.point.x, $0.point.y - hit.point.y) > 2 * pixelsPerPoint }) { result.append(hit) }
            if result.count == 6 { break }
        }
        return result
    }
    private func assisted(_ raw: CGPoint, smoothing: Bool, bypass: Bool) -> [CGPoint] {
        let input = smoothing ? stabilizer.append(raw, strength: CGFloat(model.smoothing), pixelsPerPoint: pixelsPerPoint) : raw
        lastPointer = input
        guard model.snapEnabled, !bypass else {
            manualTarget = nil
            previousHit = nil; snappedPoint = nil; alternatives = []
            return [input]
        }
        alternatives = edgeCandidates(at: input); alternativeIndex = 0
        guard var hit = alternatives.first else { manualTarget = nil; previousHit = nil; snappedPoint = nil; return [input] }
        if let target = manualTarget {
            let predicted = CGPoint(x: target.edge.x + input.x - target.pointer.x, y: target.edge.y + input.y - target.pointer.y)
            if let chosen = alternatives.min(by: { hypot($0.point.x - predicted.x, $0.point.y - predicted.y) < hypot($1.point.x - predicted.x, $1.point.y - predicted.y) }),
               hypot(chosen.point.x - predicted.x, chosen.point.y - predicted.y) <= CGFloat(model.snapRadius) * pixelsPerPoint * 0.75 {
                hit = chosen
                manualTarget = (chosen.point, input)
            } else { manualTarget = nil }
        }
        let route = smoothing ? (strokeEdges?.bridge(from: previousHit, to: hit, radius: CGFloat(model.snapRadius) * pixelsPerPoint) ?? [hit.point]) : [hit.point]
        previousHit = hit; snappedPoint = hit.point
        return route
    }
    private func appendLasso(_ event: NSEvent) {
        if let old = snappedPoint { setNeedsDisplay(ringRect(old)) }
        for point in assisted(pixelPoint(event), smoothing: true, bypass: event.modifierFlags.contains(.option)) {
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.4 * pixelsPerPoint { continue }
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
        if optionDown { manualTarget = nil; previousHit = nil; snappedPoint = nil }
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
            stabilizer.reset(); previousHit = nil; snappedPoint = nil
            // Freeze detection for this stroke; an arriving Vision result must not bend a stroke in progress.
            strokeEdges = model.edgeMap
        }
        let point = assisted(pixelPoint(event), smoothing: model.mode == .lasso, bypass: optionDown).last!
        if continuing {
            points = LassoPath.continuing(points, near: point, radius: 12 * pixelsPerPoint)
            strokeBounds = points.reduce(CGRect.null) { $0.union(ringRect($1)) }
            continuing = false; strokeEdges = model.edgeMap
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
        lastPointer = hover
        if !model.selecting, model.snapEnabled, !event.modifierFlags.contains(.option) {
            strokeEdges = model.edgeMap
            alternatives = edgeCandidates(at: hover!); alternativeIndex = 0
            snappedPoint = alternatives.first?.point
        } else if model.mode == .polygon, model.selecting {
            hover = assisted(hover!, smoothing: false, bypass: event.modifierFlags.contains(.option)).last
        } else if !model.selecting { snappedPoint = nil }
        if model.selecting { needsDisplay = true }
        else {
            if let oldSnap { setNeedsDisplay(ringRect(oldSnap)) }
            if let snappedPoint { setNeedsDisplay(ringRect(snappedPoint)) }
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: model.cancel()
        case 36, 76:
            if model.reviewing { model.confirm() }
            else if model.mode == .polygon || continuing { finish() }
        case 48:
            guard !model.reviewing, model.snapEnabled, !optionDown, alternatives.count > 1 else { return }
            alternativeIndex = (alternativeIndex + 1) % alternatives.count
            let hit = alternatives[alternativeIndex]
            if let lastPointer { manualTarget = (hit.point, lastPointer) }
            previousHit = hit; snappedPoint = hit.point; hover = hit.point
            if model.selecting && !points.isEmpty { points[points.count - 1] = hit.point }
            needsDisplay = true
        case 51, 117:
            if model.reviewing { model.reset(); refresh(); return }

            if !points.isEmpty { points.removeLast(); model.selecting = !points.isEmpty; needsDisplay = true }
        default: super.keyDown(with: event)
        }
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
        catch { model.error = error.localizedDescription; points.removeAll(); previousHit = nil; snappedPoint = nil; stabilizer.reset(); model.selecting = false; needsDisplay = true }
    }
}
