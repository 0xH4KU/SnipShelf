import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class CanvasModel {
    enum Mode: String, CaseIterable { case lasso = "Lasso", polygon = "Polygon" }
    enum MaskTool: String, CaseIterable { case view = "View", restore = "Restore", erase = "Erase" }
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
    var fluidDrawing: Bool { didSet { preferences?.set(fluidDrawing, forKey: "labFluidDrawing") } }
    var maskTool: MaskTool = .view
    var brushSize: Double = 24
    private(set) var paintingMask = false
    private(set) var canUndoMask = false
    private(set) var canRedoMask = false
    var canTouchUp: Bool { reviewing && subjectMaskEnabled && !correcting }
    var editingMask: Bool { canTouchUp && maskTool != .view }
    var canUndo: Bool { !paintingMask && ((canTouchUp && canUndoMask) || previousOutline != nil) }
    var subjectMaskEnabled: Bool {
        didSet {
            preferences?.set(subjectMaskEnabled, forKey: "visionCorrection")
            if !subjectMaskEnabled { leaveMaskEditing() }
            if reviewing { applyReviewChoice(); startCorrection() }
        }
    }
    var edgeMap: ContourMap?
    let pixelEdges: PixelEdges?
    var reviewImage: CGImage?
    var showCutout = true
    var showRemovedAreas = false { didSet { preferences?.set(showRemovedAreas, forKey: "labShowRemovedAreas") } }
    var originalReviewImage: CGImage? { drawnReview?.image }
    private(set) var reviewPoints: [CGPoint] = []
    private(set) var reviewOrigin = CGPoint.zero
    private typealias Outline = (points: [CGPoint], image: CGImage)
    private var drawnReview: Outline?
    private var correctedReview: Outline?
    private var editedReview: CGImage?
    private var previousReview: (drawn: Outline, corrected: Outline?, edited: CGImage?)?
    var previousOutline: [CGPoint]? { previousReview?.drawn.points }
    private(set) var correcting = false
    var restoreToken = 0
    var resumeToken = 0
    var reviewing: Bool { reviewImage != nil }
    var hasOutline: Bool { selecting || reviewing }
    var canConfirm: Bool { reviewing && !paintingMask && (!subjectMaskEnabled || !correcting) }
    var correctionStatus: String {
        if !subjectMaskEnabled { return "Using your drawn outline" }
        if correcting { return "Finding the subject…" }
        if editedReview != nil { return "Subject mask with your touch-ups" }
        return correctedReview == nil ? "No subject mask available · kept your selection" : "Background removed within your selection"
    }
    var edgeStatus = "Freehand ready · preparing edge help…"
    @ObservationIgnored private var edgeTask: Task<ContourMap, Error>?
    @ObservationIgnored private(set) var correctionTask: Task<Void, Never>?
    @ObservationIgnored private var maskBrush: MaskBrush?
    @ObservationIgnored private let maskUndo = UndoManager()
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private let subjectCutout: @Sendable (CGImage, [CGPoint]) throws -> CGImage?
    var complete: (CGImage) -> Void
    var cancel: () -> Void
    @ObservationIgnored var reviewReady: (() -> Void)?
    init(image: CGImage, isScreen: Bool, preferences: UserDefaults? = nil, fluidDrawing: Bool = false,
         subjectCutout: @escaping @Sendable (CGImage, [CGPoint]) throws -> CGImage? = { try SubjectMask.cutout($0, points: $1) },
         complete: @escaping (CGImage) -> Void, cancel: @escaping () -> Void) {
        session = CaptureSession(image: image)
        pixelEdges = PixelEdges(image)
        self.preferences = preferences
        self.fluidDrawing = fluidDrawing
        self.subjectCutout = subjectCutout
        maskUndo.groupsByEvent = false
        smoothing = min(1, max(0, preferences?.object(forKey: "lassoSmoothing") as? Double ?? 0.55))
        snapEnabled = preferences?.object(forKey: "lassoSnap") as? Bool ?? true
        snapRadius = min(24, max(4, preferences?.object(forKey: "lassoSnapRadius") as? Double ?? 10))
        subjectMaskEnabled = preferences?.object(forKey: "visionCorrection") as? Bool ?? true
        self.isScreen = isScreen; self.complete = complete; self.cancel = cancel
    }
    deinit { edgeTask?.cancel(); correctionTask?.cancel() }
    private func edgeDetection() -> Task<ContourMap, Error> {
        if let edgeTask { return edgeTask }
        let image = session.image
        let task = Task.detached(priority: .userInitiated) { try ContourMap.detect(in: image) }
        edgeTask = task
        return task
    }
    func analyzeEdges() async {
        guard edgeMap == nil else { return }
        do {
            let map = try await edgeDetection().value
            guard !Task.isCancelled else { return }
            edgeMap = map
            edgeStatus = map.isEmpty ? "Freehand ready" : "Gentle edge help ready"
        } catch {
            guard !Task.isCancelled else { return }
            edgeStatus = "Freehand ready"
        }
    }
    func reset() {
        cancelMaskStroke()
        if reviewing { checkpointReview() }
        clearMaskEdits()
        stopCorrection(); drawnReview = nil; correctedReview = nil
        reviewImage = nil; selecting = false; error = nil; resetToken += 1
    }
    func prepareReview(points: [CGPoint]) throws {
        let image = try ImageCore.crop(session.image, points: points)
        clearMaskEdits()
        stopCorrection()
        drawnReview = (points, image); correctedReview = nil
        selecting = false
        applyReviewChoice(); startCorrection()
        reviewReady?()
    }
    private func checkpointReview() {
        if let drawnReview { previousReview = (drawnReview, correctedReview, editedReview) }
    }
    private func applyReviewChoice() {
        guard let drawnReview, !selecting else { return }
        let outline = subjectMaskEnabled ? (correctedReview ?? drawnReview) : drawnReview
        reviewPoints = outline.points
        reviewOrigin = CGPoint(x: max(0, floor(outline.points.map(\.x).min() ?? 0)),
                               y: max(0, floor(outline.points.map(\.y).min() ?? 0)))
        reviewImage = subjectMaskEnabled ? (editedReview ?? outline.image) : outline.image
    }
    private func startCorrection() {
        guard reviewing, subjectMaskEnabled, correctionTask == nil, correctedReview == nil, let drawnReview else { return }
        correcting = true
        let image = session.image, subjectCutout = subjectCutout
        let worker = Task.detached(priority: .userInitiated) { () throws -> Outline? in
            guard let cutout = try subjectCutout(image, drawnReview.points) else { return nil }
            try Task.checkCancellation()
            return (drawnReview.points, cutout)
        }
        correctionTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                try? await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.reviewing else { return }
            self.correcting = false
            self.correctedReview = result
            self.applyReviewChoice()
        }
    }
    private func stopCorrection() {
        correctionTask?.cancel(); correctionTask = nil; correcting = false
    }
    func beginMaskStroke(at point: CGPoint) {
        guard editingMask, !paintingMask, let image = reviewImage, let original = drawnReview?.image else { return }
        do {
            maskBrush = try MaskBrush(image: image, original: original, origin: reviewOrigin, start: point,
                diameter: CGFloat(brushSize), restoring: maskTool == .restore)
            // Keep whole-stroke undo bounded for large images while retaining at least one undo.
            maskUndo.levelsOfUndo = max(1, min(20, 64 * 1024 * 1024 / (image.width * image.height * 4)))
            paintingMask = true; error = nil
            paintMaskStroke(to: point)
        } catch { self.error = error.localizedDescription }
    }
    func paintMaskStroke(to point: CGPoint) {
        guard let maskBrush else { return }
        do { reviewImage = try maskBrush.paint(to: point) }
        catch { cancelMaskStroke(); self.error = error.localizedDescription }
    }
    func endMaskStroke() {
        guard let maskBrush, let image = reviewImage else { return }
        guard ImageCore.hasVisibleCoverage(maskBrush.context) else {
            cancelMaskStroke(); error = "Keep some visible pixels. The last stroke was reverted."; return
        }
        self.maskBrush = nil; paintingMask = false
        setMaskEdit(image)
    }
    func cancelMaskStroke() {
        guard paintingMask else { return }
        maskBrush = nil; paintingMask = false; applyReviewChoice()
    }
    func leaveMaskEditing() { cancelMaskStroke(); maskTool = .view }
    private func setMaskEdit(_ image: CGImage?) {
        let previous = editedReview
        maskUndo.beginUndoGrouping()
        maskUndo.registerUndo(withTarget: self) { $0.setMaskEdit(previous) }
        maskUndo.setActionName("Mask stroke")
        maskUndo.endUndoGrouping()
        editedReview = image; applyReviewChoice(); updateMaskUndo()
    }
    private func updateMaskUndo() { canUndoMask = maskUndo.canUndo; canRedoMask = maskUndo.canRedo }
    private func clearMaskEdits() {
        maskBrush = nil; paintingMask = false; maskTool = .view; editedReview = nil
        maskUndo.removeAllActions(); updateMaskUndo()
    }
    func redoMaskStroke() {
        guard canTouchUp, !paintingMask else { return }
        maskUndo.redo(); updateMaskUndo()
    }
    func continueSelection() {
        guard reviewing else { return }
        cancelMaskStroke()
        // ponytail: one outline checkpoint; use UndoManager if multi-step editing is needed.
        checkpointReview(); stopCorrection()
        clearMaskEdits()
        reviewImage = nil; selecting = true; resumeToken += 1
    }
    func undoSelection() {
        guard !paintingMask else { return }
        if canTouchUp, maskUndo.canUndo { maskUndo.undo(); updateMaskUndo(); return }
        guard let previousReview else { return }
        stopCorrection(); clearMaskEdits()
        drawnReview = previousReview.drawn; correctedReview = previousReview.corrected
        editedReview = previousReview.edited
        self.previousReview = nil; selecting = false; error = nil; restoreToken += 1
        applyReviewChoice(); startCorrection()
        reviewReady?()
    }
    func confirm() {
        guard canConfirm, let image = reviewImage else { return }
        clearMaskEdits()
        stopCorrection(); drawnReview = nil; correctedReview = nil
        reviewImage = nil
        complete(image)
    }
    func fit() { scale = 1; actualSize = false; offset = .zero }
}

struct CaptureReviewView: View {
    @Bindable var model: CanvasModel
    let refine: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            if let image = model.reviewImage {
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable().scaledToFit().padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Selected cutout")
            }
            SubjectMaskControl(model: model)
            HStack {
                Button("Refine", action: refine).buttonStyle(.borderless)
                Spacer()
                Button("Keep Clip") { model.confirm() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
            }
        }.padding(14).background(.regularMaterial)
    }
}

struct SubjectMaskControl: View {
    @Bindable var model: CanvasModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Subject mask", isOn: $model.subjectMaskEnabled)
                .toggleStyle(.checkbox).help("Remove background around the subject inside your selection. Turn off to restore your original cutout.")
            HStack(spacing: 6) {
                if model.subjectMaskEnabled && model.correcting { ProgressView().controlSize(.mini) }
                Text(model.correctionStatus).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
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
                                .gesture(DragGesture(coordinateSpace: .named("captureCanvas")).onChanged { value in
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
                                .disabled(model.selecting).popover(isPresented: $showAssist) {
                                    SelectionAssistanceView(model: model).padding(20).frame(width: 270)
                                }
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
                            VStack(spacing: 10) {
                                SubjectMaskControl(model: model)
                                HStack(spacing: 12) {
                                    Button("Redraw", systemImage: "arrow.counterclockwise") { model.reset() }
                                        .help("Start again · ⌘Z restores this outline")
                                    Button("Refine", systemImage: "pencil.tip") { model.continueSelection() }
                                        .help("Drag from the outline to retrace · ⌘Z restores the previous outline")
                                    Divider().frame(height: 22)
                                    Button("Keep Clip", systemImage: "checkmark") { model.confirm() }
                                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                                        .disabled(!model.canConfirm)
                                        .help("Save this cutout to the shelf (Return)")
                                }.buttonStyle(.bordered).controlSize(.large)
                            }.fixedSize(horizontal: true, vertical: false)
                                .padding(12).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
                        } else if model.hasOutline {
                            Button("Redraw", systemImage: "arrow.counterclockwise") { model.reset() }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                    }.padding(.bottom, 22)
                }
            }
        }.coordinateSpace(name: "captureCanvas")
            .task { await model.analyzeEdges() }
    }
    private var hint: String {
        if let error = model.error { return error }
        if model.reviewing { return "Compare the cutout · Refine the edge · Return to keep" }
        if model.previousOutline != nil && model.selecting { return "Retrace or redraw · ⌘Z restores the previous outline" }
        return model.mode == .lasso ? "Draw around an element · Release to review · ⌥ bypasses edge help" : "Click to add points · Return to review · Delete to undo"
    }
}

struct SelectionAssistanceView: View {
    @Bindable var model: CanvasModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selection Assistance").font(.headline)
            Text(model.edgeStatus).font(.caption).foregroundStyle(.secondary)
            Picker("Tool", selection: $model.mode) {
                ForEach(CanvasModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(model.hasOutline)
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
        }
    }
}

struct SelectionCanvas: NSViewRepresentable {
    var model: CanvasModel
    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(model: model) }
    func updateNSView(_ view: CanvasNSView, context: Context) {
        _ = model.scale; _ = model.offset; _ = model.actualSize; _ = model.mode; _ = model.resetToken; _ = model.edgeMap; _ = model.reviewImage; _ = model.resumeToken; _ = model.restoreToken; _ = model.showCutout; _ = model.snapEnabled
        _ = model.maskTool; _ = model.brushSize; _ = model.showRemovedAreas
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
    private var removalMask: CGImage?
    private var removalPreviewFor: CGImage?
    private var continuing = false
    private var draggingLasso = false
    private var fluidStroke = false
    private var alternatives: [ContourMap.Hit] = []
    private var alternativeIndex = 0
    private var lastPointer: CGPoint?
    private var spaceDown = false
    private var panStart: CGPoint?
    private var seenMaskTool: CanvasModel.MaskTool = .view
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
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: panStart != nil ? .closedHand : (spaceDown ? .openHand : .crosshair))
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    func refresh() {
        if !model.reviewing { panStart = nil; spaceDown = false }
        if seenMaskTool != model.maskTool {
            seenMaskTool = model.maskTool; hover = nil
            window?.makeFirstResponder(self)
        }
        window?.invalidateCursorRects(for: self)
        if !model.snapEnabled { previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil }
        if seenResume != model.resumeToken {
            seenResume = model.resumeToken; continuing = true; draggingLasso = false; lastPointer = nil
            fluidStroke = model.fluidDrawing
            points = model.reviewPoints
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
            if model.reviewing { points = model.reviewPoints }
            displayedReview = model.reviewImage
            reviewPicture = model.reviewImage.map { NSImage(cgImage: $0, size: .zero) }
            removalMask = nil; removalPreviewFor = nil
        }
        if model.showRemovedAreas, model.canTouchUp, !model.showCutout,
           let image = model.reviewImage, let original = model.originalReviewImage, removalPreviewFor !== image {
            removalPreviewFor = image
            do { removalMask = try ImageCore.removedPixels(original: original, current: image) }
            catch { model.error = error.localizedDescription }
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
    var reviewScreenRect: CGRect? {
        guard let window, let image = model.reviewImage else { return nil }
        let rect = CGRect(origin: canvasPoint(model.reviewOrigin),
                          size: CGSize(width: CGFloat(image.width) / pixelsPerPoint,
                                       height: CGFloat(image.height) / pixelsPerPoint))
        return window.convertToScreen(convert(rect, to: nil))
    }
    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let p = model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect)
        return CGPoint(x: min(CGFloat(model.session.image.width), max(0, p.x)),
                       y: min(CGFloat(model.session.image.height), max(0, p.y)))
    }
    override func draw(_ dirtyRect: NSRect) {
        defer { drawMaskCursor() }
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
        if !model.reviewing, points.count > 2 { let fill = path.copy() as! NSBezierPath; fill.close(); shade.append(fill) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(model.reviewing ? 0.5 : (model.selecting ? 0.22 : 0.12)).setFill(); shade.fill()
        if model.reviewing, let image = model.reviewImage {
            // Highlight the actual mask while keeping the lasso available for refinement.
            let rect = CGRect(origin: canvasPoint(model.reviewOrigin),
                              size: CGSize(width: CGFloat(image.width) / pixelsPerPoint, height: CGFloat(image.height) / pixelsPerPoint))
            reviewPicture?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            drawRemovedAreas(in: rect)
        }
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
                let closing = canCloseLasso
                let radius: CGFloat = closing ? 7 : 4
                let ring = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
                if closing { NSColor.controlAccentColor.withAlphaComponent(0.25).setFill(); ring.fill() }
                (closing ? NSColor.controlAccentColor : NSColor.white).setStroke()
                ring.lineWidth = closing ? 2 : 1; ring.stroke()
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
    private func drawRemovedAreas(in rect: CGRect) {
        guard model.showRemovedAreas, model.canTouchUp, let removalMask,
              let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Register the mask with the top-left image coordinates, then draw stripes in screen points.
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(origin: .zero, size: rect.size), mask: removalMask)
        context.scaleBy(x: 1, y: -1); context.translateBy(x: -rect.minX, y: -rect.maxY)
        NSColor(calibratedRed: 0, green: 0.8, blue: 1, alpha: 0.45).setFill(); rect.fill()
        let visible = rect.intersection(bounds)
        if !visible.isNull {
            let stripes = NSBezierPath()
            for x in stride(from: visible.minX - visible.height, through: visible.maxX, by: 12) {
                stripes.move(to: CGPoint(x: x, y: visible.maxY))
                stripes.line(to: CGPoint(x: x + visible.height, y: visible.minY))
            }
            NSColor(calibratedRed: 0.55, green: 1, blue: 1, alpha: 0.8).setStroke()
            stripes.lineWidth = 1.5; stripes.stroke()
        }
    }
    private func drawMaskCursor() {
        guard model.editingMask, !spaceDown, panStart == nil, let hover else { return }
        let center = canvasPoint(hover), radius = CGFloat(model.brushSize) / (2 * pixelsPerPoint)
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSColor.black.withAlphaComponent(0.75).setStroke(); ring.lineWidth = 3; ring.stroke()
        NSColor.white.setStroke(); ring.lineWidth = 1; ring.stroke()
    }
    private var pixelsPerPoint: CGFloat { CGFloat(model.session.image.width) / max(1, imageRect.width) }
    var canCloseLasso: Bool {
        guard fluidStroke, draggingLasso, !optionDown, points.count > 2, let first = points.first, let hover,
              max(strokeBounds.width, strokeBounds.height) > 44 else { return false }
        return hypot(hover.x - first.x, hover.y - first.y) <= 9 * pixelsPerPoint
    }
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
    private func assisted(_ raw: CGPoint, smoothing: Bool, bypass: Bool, timestamp: TimeInterval? = nil) -> CGPoint {
        let input = smoothing ? stabilizer.append(raw, strength: CGFloat(model.smoothing), pixelsPerPoint: pixelsPerPoint,
                                                  timestamp: fluidStroke ? timestamp : nil) : raw
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
        let raw = pixelPoint(event)
        hover = raw
        optionDown = event.modifierFlags.contains(.option)
        let point = assisted(raw, smoothing: true, bypass: optionDown, timestamp: event.timestamp)
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
        if model.reviewing {
            if spaceDown, !model.paintingMask {
                panStart = convert(event.locationInWindow, from: nil)
                window?.invalidateCursorRects(for: self)
            } else if imageRect.contains(convert(event.locationInWindow, from: nil)) {
                hover = model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect)
                model.beginMaskStroke(at: hover!); refresh()
            }
            return
        }
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        model.error = nil
        optionDown = event.modifierFlags.contains(.option)
        if !model.selecting || (model.mode == .lasso && !continuing) {
            stabilizer.reset()
            fluidStroke = model.fluidDrawing
            // Freeze detection for this stroke; an arriving Vision result must not bend a stroke in progress.
            strokeEdges = model.edgeMap
        }
        if model.mode == .lasso { hover = pixelPoint(event) }
        let point = assisted(pixelPoint(event), smoothing: model.mode == .lasso, bypass: optionDown, timestamp: event.timestamp)
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
        if let panStart {
            let location = convert(event.locationInWindow, from: nil)
            model.offset.x += location.x - panStart.x; model.offset.y += location.y - panStart.y
            self.panStart = location; hover = nil; needsDisplay = true; return
        }
        if model.paintingMask {
            hover = model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect)
            model.paintMaskStroke(to: hover!); refresh(); return
        }
        guard draggingLasso, model.selecting else { return }
        appendLasso(event)
    }
    override func mouseUp(with event: NSEvent) {
        if panStart != nil {
            panStart = nil; window?.invalidateCursorRects(for: self); return
        }
        if model.paintingMask {
            hover = model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect)
            model.paintMaskStroke(to: hover!); model.endMaskStroke(); refresh(); return
        }
        if draggingLasso, model.selecting {
            appendLasso(event)
            if fluidStroke, let first = points.first, let last = points.last {
                let endpoint = canCloseLasso ? first : pixelPoint(event)
                if hypot(last.x - endpoint.x, last.y - endpoint.y) > 0.001 { points.append(endpoint) }
            }
            draggingLasso = false
            finish()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        if model.reviewing {
            hover = imageRect.contains(convert(event.locationInWindow, from: nil))
                ? model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect) : nil
            needsDisplay = true; return
        }
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
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { model.redoMaskStroke() } else { model.undoSelection() }
            refresh(); return
        }
        if model.reviewing, event.keyCode == 49, !model.paintingMask {
            spaceDown = true; window?.invalidateCursorRects(for: self); needsDisplay = true; return
        }
        if model.editingMask, !model.paintingMask, let key = event.charactersIgnoringModifiers, key == "[" || key == "]" {
            model.brushSize = min(128, max(1, model.brushSize + (key == "[" ? -2 : 2)))
            needsDisplay = true; return
        }
        switch event.keyCode {
        case 53:
            if model.editingMask { model.leaveMaskEditing(); refresh() } else { model.cancel() }
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
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false; window?.invalidateCursorRects(for: self); needsDisplay = true }
        else { super.keyUp(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { model.redoMaskStroke() } else { model.undoSelection() }
            refresh(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard !model.selecting, !model.paintingMask else { return }
        model.offset.x -= event.scrollingDeltaX
        model.offset.y -= event.scrollingDeltaY
        hover = nil; needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard !model.selecting, !model.paintingMask else { return }
        model.scale = min(16, max(0.1, model.scale * (1 + event.magnification)))
        hover = nil; needsDisplay = true
    }
    private func finish() {
        do { try model.prepareReview(points: points); snappedPoint = nil; hover = nil; needsDisplay = true }
        catch { model.error = error.localizedDescription; points.removeAll(); previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil; stabilizer.reset(); model.selecting = false; needsDisplay = true }
    }
}
