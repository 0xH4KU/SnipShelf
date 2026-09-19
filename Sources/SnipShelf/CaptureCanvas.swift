import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class CanvasModel {
    enum Mode: String, CaseIterable { case lasso = "Lasso", polygon = "Polygon", rectangle = "Rectangle" }
    enum MaskTool: String, CaseIterable {
        case view = "View", restore = "Restore", erase = "Erase"
        var shortcut: String {
            switch self { case .view: "V"; case .restore: "R"; case .erase: "E" }
        }
    }
    let session: CaptureSession
    let isScreen: Bool
    var mode: Mode = .lasso {
        didSet {
            guard oldValue != mode else { return }
            preferences?.set(mode.rawValue, forKey: "selectionMode")
            subjectMaskEnabled = mode == .rectangle ? rectangleMaskEnabled : outlineMaskEnabled
        }
    }
    private var outlineMaskEnabled = true
    private var rectangleMaskEnabled = false
    private(set) var continuingCapture = false
    var selecting = false
    var scale: CGFloat = 1
    var offset = CGPoint.zero
    var error: String?
    var resetToken = 0
    var actualSize = false
    var reviewScale: CGFloat = 1
    var reviewOffset = CGPoint.zero
    var reviewActualSize = false
    var smoothing: Double { didSet { preferences?.set(smoothing, forKey: "lassoSmoothing") } }
    var snapEnabled: Bool { didSet { preferences?.set(snapEnabled, forKey: "lassoSnap") } }
    var snapRadius: Double { didSet { preferences?.set(snapRadius, forKey: "lassoSnapRadius") } }
    var fluidDrawing: Bool { didSet { preferences?.set(fluidDrawing, forKey: "fluidDrawing") } }
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
            if mode == .rectangle { rectangleMaskEnabled = subjectMaskEnabled }
            else { outlineMaskEnabled = subjectMaskEnabled }
            preferences?.set(subjectMaskEnabled, forKey: mode == .rectangle ? "rectangleRemoveBackground" : "visionCorrection")
            if !subjectMaskEnabled { leaveMaskEditing() }
            if reviewing { applyReviewChoice(); startCorrection() }
        }
    }
    var edgeMap: ContourMap?
    let pixelEdges: PixelEdges?
    var reviewImage: CGImage?
    var showCutout = true
    var showRemovedAreas: Bool { didSet { preferences?.set(showRemovedAreas, forKey: "showRemovedAreas") } }
    var originalReviewImage: CGImage? { drawnReview?.image }
    private(set) var reviewPoints: [CGPoint] = []
    private(set) var reviewOrigin = CGPoint.zero
    private typealias Outline = (points: [CGPoint], image: CGImage)
    private var drawnReview: Outline?
    private var correctedReview: Outline?
    private var editedReview: CGImage?
    private var previousReview: (drawn: Outline, corrected: Outline?, edited: CGImage?, mode: Mode, removeBackground: Bool)?
    var previousOutline: [CGPoint]? { previousReview?.drawn.points }
    private(set) var correcting = false
    private(set) var correctionError: String?
    var canRetryCorrection: Bool { reviewing && subjectMaskEnabled && !correcting && correctedReview == nil && editedReview == nil && !paintingMask }
    var restoreToken = 0
    var resumeToken = 0
    var reviewing: Bool { reviewImage != nil }
    var hasOutline: Bool { selecting || reviewing }
    var canConfirm: Bool { reviewing && !paintingMask && (!subjectMaskEnabled || !correcting) }
    var correctionStatus: String {
        if !subjectMaskEnabled { return mode == .rectangle ? "Background kept inside your rectangle" : "Using your drawn outline" }
        if correcting { return "Finding the subject…" }
        if editedReview != nil { return "Subject mask with your touch-ups" }
        if let correctionError { return "Background removal failed: \(correctionError) · kept your selection" }
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
    init(image: CGImage, isScreen: Bool, preferences: UserDefaults? = nil, fluidDrawing: Bool? = nil,
         subjectCutout: @escaping @Sendable (CGImage, [CGPoint]) throws -> CGImage? = { try SubjectMask.cutout($0, points: $1) },
         complete: @escaping (CGImage) -> Void, cancel: @escaping () -> Void) {
        session = CaptureSession(image: image)
        pixelEdges = PixelEdges(image)
        self.preferences = preferences
        self.fluidDrawing = fluidDrawing ?? preferences?.object(forKey: "fluidDrawing") as? Bool
            ?? preferences?.object(forKey: "labFluidDrawing") as? Bool ?? true
        showRemovedAreas = preferences?.object(forKey: "showRemovedAreas") as? Bool
            ?? preferences?.object(forKey: "labShowRemovedAreas") as? Bool ?? true
        self.subjectCutout = subjectCutout
        maskUndo.groupsByEvent = false
        smoothing = min(1, max(0, preferences?.object(forKey: "lassoSmoothing") as? Double ?? 0.55))
        snapEnabled = preferences?.object(forKey: "lassoSnap") as? Bool ?? true
        snapRadius = min(24, max(4, preferences?.object(forKey: "lassoSnapRadius") as? Double ?? 10))
        let initialMode = preferences?.string(forKey: "selectionMode").flatMap(Mode.init(rawValue:)) ?? .lasso
        mode = initialMode
        let outlineMask = preferences?.object(forKey: "visionCorrection") as? Bool ?? true
        let rectangleMask = preferences?.object(forKey: "rectangleRemoveBackground") as? Bool ?? false
        outlineMaskEnabled = outlineMask; rectangleMaskEnabled = rectangleMask
        subjectMaskEnabled = initialMode == .rectangle ? rectangleMask : outlineMask
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
        guard edgeMap == nil, mode != .rectangle else { return }
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
        fitReview()
        applyReviewChoice(); startCorrection()
        reviewReady?()
    }
    private func checkpointReview() {
        if let drawnReview { previousReview = (drawnReview, correctedReview, editedReview, mode, subjectMaskEnabled) }
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
        correctionError = nil
        let image = session.image, subjectCutout = subjectCutout
        let worker = Task.detached(priority: .userInitiated) { () throws -> Outline? in
            guard let cutout = try subjectCutout(image, drawnReview.points) else { return nil }
            try Task.checkCancellation()
            return (drawnReview.points, cutout)
        }
        correctionTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.reviewing else { return }
            self.correcting = false
            switch result {
            case .success(let outline): self.correctedReview = outline
            case .failure(let error): self.correctionError = error.localizedDescription
            }
            self.applyReviewChoice()
        }
    }
    func retryCorrection() {
        guard canRetryCorrection else { return }
        stopCorrection()
        startCorrection()
    }
    private func stopCorrection() {
        correctionTask?.cancel(); correctionTask = nil; correcting = false; correctionError = nil
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
        mode = previousReview.mode; subjectMaskEnabled = previousReview.removeBackground
        drawnReview = previousReview.drawn; correctedReview = previousReview.corrected
        editedReview = previousReview.edited
        self.previousReview = nil; selecting = false; error = nil; restoreToken += 1
        fitReview()
        applyReviewChoice(); startCorrection()
        reviewReady?()
    }
    func confirm(keepSelecting: Bool = false) {
        guard canConfirm, let image = reviewImage else { return }
        clearMaskEdits()
        stopCorrection(); drawnReview = nil; correctedReview = nil
        reviewImage = nil
        previousReview = nil; selecting = false; resetToken += 1
        continuingCapture = keepSelecting
        complete(image)
    }
    func fit() { scale = 1; actualSize = false; offset = .zero }
    func fitReview() { reviewScale = 1; reviewActualSize = false; reviewOffset = .zero }
}

struct CaptureReviewView: View {
    @Bindable var model: CanvasModel
    let refine: () -> Void
    var app: AppController? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Preview", selection: $model.showCutout) {
                    Text("Original").tag(false)
                    Text("Cutout").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Spacer()
                Button("Fit") { model.fitReview() }.buttonHover().help("Fit selection (⌘0)").keyboardShortcut("0", modifiers: .command)
                Button("100%") { model.reviewActualSize = true; model.reviewScale = 1; model.reviewOffset = .zero }
                    .buttonHover()
                    .help("Actual pixels (⌘1)").keyboardShortcut("1", modifiers: .command)
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.reviewScale = max(0.1, model.reviewScale / 1.25) }
                    .labelStyle(.iconOnly).buttonHover().help("Zoom out (⌘−)")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { model.reviewScale = min(16, model.reviewScale * 1.25) }
                    .labelStyle(.iconOnly).buttonHover().help("Zoom in (⌘+ or ⌘=) · Pinch to zoom, scroll to pan")
            }.buttonStyle(.borderless).controlSize(.small).padding(12).disabled(model.paintingMask)
            Divider()
            SelectionCanvas(model: model, reviewOnly: true).clipped()
                .frame(minHeight: 160)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                SubjectMaskControl(model: model)
                if model.subjectMaskEnabled {
                    HStack(spacing: 6) {
                        Picker("Touch-up tool", selection: $model.maskTool) {
                            ForEach(CanvasModel.MaskTool.allCases, id: \.self) { Text("\($0.rawValue) (\($0.shortcut))").tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().disabled(!model.canTouchUp)
                        Button("Undo", systemImage: "arrow.uturn.backward") { model.undoSelection() }
                            .buttonHover()
                            .disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command)
                            .help("Undo last edit (⌘Z)")
                        Button("Redo", systemImage: "arrow.uturn.forward") { model.redoMaskStroke() }
                            .buttonHover()
                            .disabled(!model.canTouchUp || !model.canRedoMask).keyboardShortcut("z", modifiers: [.command, .shift])
                            .help("Redo last stroke (⇧⌘Z)")
                    }.labelStyle(.titleOnly)
                    HStack(spacing: 10) {
                        Text("Brush [ / ]")
                        Slider(value: $model.brushSize, in: 1...128, step: 1).accessibilityLabel("Brush size")
                            .help("[ makes the brush smaller; ] makes it larger")
                        Text("\(Int(model.brushSize)) px").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }.font(.caption).disabled(!model.editingMask)
                    HStack {
                        Toggle("Show removed areas", isOn: $model.showRemovedAreas).toggleStyle(.checkbox)
                            .disabled(model.showCutout || !model.canTouchUp)
                        Spacer()
                        if let image = model.reviewImage {
                            Text("\(image.width) × \(image.height) px").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.font(.caption)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("⌘+ / ⌘− zoom · ⌘Z undo · ⇧⌘Z redo")
                    Text(model.editingMask ? "Space-drag pans · Esc leaves the brush" : "Drag to pan · Pinch to zoom")
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error) }
                Divider()
                if let app {
                    @Bindable var app = app
                    HStack {
                        Picker("Save to", selection: $app.captureFolderID) {
                            Text("Shelf").tag(nil as UUID?)
                            ForEach(app.store.folders) { Text($0.name).tag(Optional($0.id)) }
                        }.lineLimit(1)
                        Button("Keep & Continue") { model.confirm(keepSelecting: true) }
                            .buttonHover()
                            .disabled(!model.canConfirm).help("Save this clip and select another area of the same image (⌘Return)")
                    }
                }
                HStack(spacing: 8) {
                    Button("Redraw") { refine(); model.reset() }.buttonHover().help("Draw a new selection on the same image")
                    Button(model.mode == .rectangle ? "Adjust Rectangle" : "Refine Outline", action: refine)
                        .buttonHover()
                        .help("Return to the original image to adjust the selection")
                    Spacer()
                    Button("Keep Clip") { model.confirm() }.buttonStyle(.borderedProminent).buttonHover()
                        .keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
                }
            }.buttonStyle(.bordered).controlSize(.small).padding(14).disabled(model.paintingMask)
        }.background(.regularMaterial)
    }
}

struct SubjectMaskControl: View {
    @Bindable var model: CanvasModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Remove Background", isOn: $model.subjectMaskEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Remove background around the subject inside your selection. Turn off to restore your original cutout.")
                if model.canRetryCorrection {
                    Button("Retry") { model.retryCorrection() }.controlSize(.small).buttonHover()
                        .help("Try removing the background again")
                }
            }
            HStack(spacing: 6) {
                if model.subjectMaskEnabled && model.correcting { ProgressView().controlSize(.mini) }
                Text(model.correctionStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(model.correctionStatus)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).disabled(model.paintingMask)
    }
}

struct SelectionReviewTools: View {
    @Bindable var model: CanvasModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Refine Your Clip").font(.title3).bold()
            SubjectMaskControl(model: model)
            if let image = model.reviewImage {
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 110)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Selected cutout")
            }
            Picker("Canvas preview", selection: $model.showCutout) {
                Text("Original").tag(false)
                Text("Cutout").tag(true)
            }.pickerStyle(.segmented).disabled(model.paintingMask)
            if !model.showCutout {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show removed areas", isOn: $model.showRemovedAreas).toggleStyle(.checkbox)
                    Text("Cyan stripes = removed · Original color = kept")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!model.canTouchUp || model.paintingMask)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Touch Up").font(.headline)
                Picker("Touch-up tool", selection: $model.maskTool) {
                    ForEach(CanvasModel.MaskTool.allCases, id: \.self) { Text("\($0.rawValue) (\($0.shortcut))").tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if model.maskTool != .view {
                    HStack {
                        Text("Brush size")
                        Spacer()
                        Text("\(Int(model.brushSize)) px").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $model.brushSize, in: 1...128, step: 1).accessibilityLabel("Brush size")
                    Text("[ / ] resize · Space-drag pans · ⌘Z undoes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.subjectMaskEnabled
                    ? "Restore brings back original pixels inside your lasso. Erase removes unwanted areas."
                    : "Turn on Remove Background to touch up the result.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!model.canTouchUp || model.paintingMask)
            if let image = model.reviewImage {
                Text("\(image.width) × \(image.height) px")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct CaptureView: View {
    @Bindable var model: CanvasModel
    @State private var toolbarOffset = CGSize.zero
    @State private var toolbarStart = CGSize.zero
    @State private var showAssist = false
    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                GlassEffectContainer(spacing: 16) {
                    ZStack(alignment: .top) {
                        SelectionCanvas(model: model)
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                if !model.reviewing {
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                        .frame(width: 24, height: 28).contentShape(Rectangle())
                                        .accessibilityLabel("Move selection toolbar")
                                        .help("Drag to move the toolbar")
                                        .gesture(DragGesture(coordinateSpace: .named("captureCanvas")).onChanged { value in
                                            let limitX = max(0, (geometry.size.width - 640) / 2)
                                            toolbarOffset = CGSize(width: min(limitX, max(-limitX, toolbarStart.width + value.translation.width)),
                                                                   height: min(max(0, geometry.size.height - 200), max(0, toolbarStart.height + value.translation.height)))
                                        }.onEnded { _ in toolbarStart = toolbarOffset })
                                    Picker("Selection", selection: $model.mode) {
                                        ForEach(CanvasModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                    }.pickerStyle(.segmented).labelsHidden().frame(width: 232).disabled(model.selecting)
                                    Button { showAssist.toggle() } label: { Image(systemName: "wand.and.stars") }
                                        .buttonHover()
                                        .help("Selection assistance").accessibilityLabel("Selection assistance")
                                        .disabled(model.selecting).popover(isPresented: $showAssist) {
                                            SelectionAssistanceView(model: model).padding(20).frame(width: 270)
                                        }
                                    Divider().frame(height: 18)
                                }
                                Button("Fit") { model.fit() }.buttonHover().help("Fit image (⌘0)").disabled(model.selecting)
                                Button("100%") { model.actualSize = true; model.scale = 1; model.offset = .zero }.buttonHover().help("Actual pixels (⌘1)").disabled(model.selecting)
                                Button { model.scale = max(0.1, model.scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                                    .buttonHover()
                                    .help("Zoom out (⌘−)").accessibilityLabel("Zoom out").disabled(model.selecting)
                                Button { model.scale = min(16, model.scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                                    .buttonHover()
                                    .help("Zoom in (⌘+ or ⌘=)").accessibilityLabel("Zoom in").disabled(model.selecting)
                                if !model.reviewing {
                                    Divider().frame(height: 18)
                                    Button { model.undoSelection() } label: { Image(systemName: "arrow.uturn.backward") }
                                        .buttonHover()
                                        .help("Undo last refinement (⌘Z)").accessibilityLabel("Undo last refinement")
                                        .disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command)
                                    Button { model.cancel() } label: { Image(systemName: "xmark") }
                                        .buttonHover()
                                        .help("Cancel (Esc)").accessibilityLabel("Cancel capture").keyboardShortcut(.cancelAction)
                                }
                            }.buttonStyle(.borderless).controlSize(.regular).disabled(model.paintingMask)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                            if !model.reviewing {
                                Text(hint)
                                    .font(.callout).foregroundStyle(model.error == nil ? Color.secondary : Color.primary)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule()).allowsHitTesting(false)
                            }
                        }.padding(.top, 18).offset(model.reviewing ? .zero : toolbarOffset)
                        VStack {
                            Spacer()
                            if !model.reviewing && model.hasOutline {
                                Button("Redraw", systemImage: "arrow.counterclockwise") { model.reset() }
                                    .buttonStyle(.glass).controlSize(.large)
                            }
                        }.padding(.bottom, 22)
                    }
                }
            }.coordinateSpace(name: "captureCanvas")
                .task(id: model.mode) { await model.analyzeEdges() }
        }
    }
    private var hint: String {
        if let error = model.error { return error }
        if model.mode == .rectangle { return "Drag a rectangle · Release to review · \(model.subjectMaskEnabled ? "Remove Background is on" : "Background is kept")" }
        if model.previousOutline != nil && model.selecting { return "Retrace or redraw · ⌘Z restores the previous outline" }
        return model.mode == .lasso
            ? (model.subjectMaskEnabled ? "Draw around the subject · Release to remove background · ⌥ bypasses edge help"
               : "Draw around an element · Release to review · ⌥ bypasses edge help")
            : "Click to add points · Return to review · Delete to undo"
    }
}

struct SelectionAssistanceView: View {
    @Bindable var model: CanvasModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selection Assistance").font(.headline)
            Text(model.edgeStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("Remove Background", isOn: $model.subjectMaskEnabled)
                .help("Find the subject inside your selection after you finish drawing.")
                .disabled(model.hasOutline)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Drawing feel", selection: $model.fluidDrawing) {
                    Text("Classic").tag(false)
                    Text("Fluid").tag(true)
                }.pickerStyle(.segmented)
                Text(model.fluidDrawing
                    ? "Steady slow strokes, responsive sweeps. The start ring lights up when you can release to close. Option bypasses closing help."
                    : "Classic stabilization without closing help.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.selecting)
            Picker("Tool", selection: $model.mode) {
                ForEach(CanvasModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(model.hasOutline)
            Toggle(model.mode == .lasso ? "Gentle edge help" : "Snap to edges", isOn: $model.snapEnabled)
                .disabled(model.mode == .rectangle)
            if model.mode == .polygon {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Snap distance"); Spacer(); Text("\(Int(model.snapRadius)) pt").foregroundStyle(.secondary) }
                    Slider(value: $model.snapRadius, in: 4...24, step: 1).accessibilityLabel("Snap distance")
                }.disabled(!model.snapEnabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Steadiness"); Spacer(); Text(model.smoothing == 0 ? "Off" : "\(Int(model.smoothing * 100))%").foregroundStyle(.secondary) }
                Slider(value: $model.smoothing, in: 0...1).accessibilityLabel("Steadiness")
            }.disabled(model.mode == .rectangle)
            Text(model.mode == .lasso ? "Hold Option to bypass edge help. Steadiness stays on." : "Tab switches nearby edges. Option bypasses snapping.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SelectionCanvas: NSViewRepresentable {
    var model: CanvasModel
    var reviewOnly = false
    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(model: model, reviewOnly: reviewOnly) }
    func updateNSView(_ view: CanvasNSView, context: Context) {
        _ = model.scale; _ = model.offset; _ = model.actualSize; _ = model.mode; _ = model.resetToken; _ = model.edgeMap; _ = model.reviewImage; _ = model.resumeToken; _ = model.restoreToken; _ = model.showCutout; _ = model.snapEnabled
        _ = model.maskTool; _ = model.brushSize; _ = model.showRemovedAreas
        if reviewOnly { _ = model.reviewScale; _ = model.reviewOffset; _ = model.reviewActualSize }
        view.refresh()
    }
}

final class CanvasNSView: NSView {
    let model: CanvasModel
    let reviewOnly: Bool
    private var zoomScale: CGFloat {
        get { reviewOnly ? model.reviewScale : model.scale }
        set { if reviewOnly { model.reviewScale = newValue } else { model.scale = newValue } }
    }
    private var panOffset: CGPoint {
        get { reviewOnly ? model.reviewOffset : model.offset }
        set { if reviewOnly { model.reviewOffset = newValue } else { model.offset = newValue } }
    }
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
    private var rectangleStart: CGPoint?
    private var fluidStroke = false
    private var alternatives: [ContourMap.Hit] = []
    private var alternativeIndex = 0
    private var lastPointer: CGPoint?
    private var spaceDown = false
    private var panStart: CGPoint?
    private var seenMaskTool: CanvasModel.MaskTool = .view
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: CanvasModel, reviewOnly: Bool = false) {
        self.model = model; self.reviewOnly = reviewOnly
        displayImage = NSImage(cgImage: model.session.image, size: .zero)
        super.init(frame: .zero)
        if model.reviewing { points = model.reviewPoints }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(reviewOnly ? "Editable cutout preview" : "Image selection canvas")
        setAccessibilityHelp((reviewOnly ? "Drag to pan or pinch to zoom the selection. " : "Choose Lasso and draw freely, or Polygon and click points. Release or press Return to review. ") + "R restores pixels; E erases; V leaves the brush. Command-plus/minus zoom; Command-0 fits; Command-1 shows actual pixels. Cyan stripes mark removed pixels in Original view. Space-drag pans; brackets resize the brush; Command-Z undoes; Command-Shift-Z redoes. Keep Clip saves; Refine Outline retraces; Redraw clears the outline. Escape leaves the brush or cancels capture.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? ShelfPanel)?.captureCanvas = self
        window?.makeFirstResponder(self)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: panStart != nil ? .closedHand : (spaceDown || (reviewOnly && !model.editingMask) ? .openHand : .crosshair))
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
        if !model.snapEnabled || model.mode == .rectangle { previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil }
        if seenResume != model.resumeToken {
            seenResume = model.resumeToken; continuing = true; draggingLasso = false; lastPointer = nil
            fluidStroke = model.fluidDrawing
            points = model.reviewPoints
            previousHit = nil; snappedPoint = nil; alternatives = []; stabilizer.reset()
            strokeEdges = model.edgeMap
            window?.makeFirstResponder(self)
        }
        if seenReset != model.resetToken { points.removeAll(); rectangleStart = nil; lastPointer = nil; alternatives = []; continuing = false; draggingLasso = false; hover = nil; previousHit = nil; snappedPoint = nil; stabilizer.reset(); seenReset = model.resetToken }
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
        let region: CGRect
        if reviewOnly, let cutout = model.reviewImage {
            region = CGRect(origin: model.reviewOrigin, size: CGSize(width: cutout.width, height: cutout.height))
        } else { region = CGRect(x: 0, y: 0, width: image.width, height: image.height) }
        let padding: CGFloat = reviewOnly ? 24 : 0
        let fitting = min(max(1, bounds.width - padding) / region.width, max(1, bounds.height - padding) / region.height)
        let actualSize = reviewOnly ? model.reviewActualSize : model.actualSize
        let scale = (actualSize ? 1 / (window?.backingScaleFactor ?? 1) : fitting) * zoomScale
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: bounds.midX - region.midX * scale + panOffset.x,
                      y: bounds.midY - region.midY * scale + panOffset.y, width: size.width, height: size.height)
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
        if reviewOnly, !model.reviewing { NSColor.windowBackgroundColor.setFill(); bounds.fill(); return }
        if model.reviewing, model.showCutout || reviewOnly, let image = model.reviewImage {
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
            if !model.showCutout {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                displayImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSColor.black.withAlphaComponent(0.5).setFill(); rect.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            reviewPicture?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            if !model.showCutout { drawRemovedAreas(in: rect) }
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
            if model.reviewing || model.mode == .rectangle { path.close() }
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
            if !model.reviewing, model.mode != .rectangle, let first = points.first, let last = points.last, points.count > 2 {
                let connector = NSBezierPath()
                connector.move(to: canvasPoint(model.mode == .polygon ? (hover ?? last) : last))
                connector.line(to: canvasPoint(first))
                connector.setLineDash([4, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.45).setStroke(); connector.lineWidth = 1; connector.stroke()
            }
            if model.mode != .rectangle, let first = points.first {
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
            if spaceDown || (reviewOnly && !model.editingMask), !model.paintingMask {
                panStart = convert(event.locationInWindow, from: nil)
                window?.invalidateCursorRects(for: self)
            } else if imageRect.contains(convert(event.locationInWindow, from: nil)) {
                hover = model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect)
                model.beginMaskStroke(at: hover!); refresh()
            }
            return
        }
        guard !reviewOnly else { return }
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        model.error = nil
        if model.mode == .rectangle {
            let start = pixelPoint(event)
            rectangleStart = start; points = [start]; model.selecting = true
            continuing = false; snappedPoint = nil; hover = nil; needsDisplay = true
            return
        }
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
            panOffset.x += location.x - panStart.x; panOffset.y += location.y - panStart.y
            self.panStart = location; hover = nil; needsDisplay = true; return
        }
        if model.paintingMask {
            hover = model.session.pixelPoint(convert(event.locationInWindow, from: nil), in: imageRect)
            model.paintMaskStroke(to: hover!); refresh(); return
        }
        if rectangleStart != nil { updateRectangle(to: pixelPoint(event)); return }
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
        if rectangleStart != nil {
            updateRectangle(to: pixelPoint(event)); rectangleStart = nil; finish(); return
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
        if model.mode == .rectangle { return }
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
        if !handleKey(event) { super.keyDown(with: event) }
    }
    @discardableResult func handleKey(_ event: NSEvent) -> Bool {
        guard !(window?.firstResponder is NSTextView),
              event.modifierFlags.intersection([.control, .option]).isEmpty else { return false }
        var key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Keep canvas shortcuts usable while a non-Latin input source is active.
        if key.isEmpty || key.unicodeScalars.contains(where: { !$0.isASCII }) {
            switch event.keyCode {
            case 6: key = "z"
            case 9: key = "v"
            case 14: key = "e"
            case 15: key = "r"
            case 18, 83: key = "1"
            case 29, 82: key = "0"
            case 24, 69: key = "+"
            case 27, 78: key = "-"
            case 30: key = "]"
            case 33: key = "["
            default: break
            }
        }
        if event.modifierFlags.contains(.command) {
            if event.keyCode == 36 || event.keyCode == 76 {
                if model.reviewing { model.confirm(keepSelecting: true) }
                refresh(); return true
            }
            switch key {
            case "z":
                if event.modifierFlags.contains(.shift) { model.redoMaskStroke() } else { model.undoSelection() }
            case "+", "=", "-":
                zoom(by: key == "-" ? 1 / 1.25 : 1.25, at: CGPoint(x: bounds.midX, y: bounds.midY))
            case "0", "1":
                guard !model.selecting, !model.paintingMask else { return true }
                if reviewOnly { model.fitReview(); model.reviewActualSize = key == "1" }
                else { model.fit(); model.actualSize = key == "1" }
            default: return false
            }
            refresh(); return true
        }
        if model.reviewing {
            if ["v", "r", "e", "[", "]"].contains(key) {
                guard model.canTouchUp, !model.paintingMask else { return true }
                switch key {
                case "v": model.leaveMaskEditing()
                case "r": model.maskTool = .restore
                case "e": model.maskTool = .erase
                default:
                    if model.editingMask { model.brushSize = min(128, max(1, model.brushSize + (key == "[" ? -2 : 2))) }
                }
                refresh(); return true
            }
            if event.keyCode == 49 {
                if !model.paintingMask { spaceDown = true; window?.makeFirstResponder(self); refresh() }
                return true
            }
        }
        switch event.keyCode {
        case 53:
            if model.editingMask { model.leaveMaskEditing(); refresh() } else { model.cancel() }
        case 36, 76:
            if model.reviewing { model.confirm() }
            else if model.mode == .polygon || continuing { finish() }
        case 48:
            guard model.mode == .polygon, !model.reviewing, model.snapEnabled, !optionDown, alternatives.count > 1 else { return false }
            alternativeIndex = (alternativeIndex + 1) % alternatives.count
            let hit = alternatives[alternativeIndex]
            previousHit = hit; snappedPoint = hit.point; hover = hit.point
            if model.selecting && !points.isEmpty { points[points.count - 1] = hit.point }
            needsDisplay = true
        case 51, 117:
            if model.reviewing {
                if !reviewOnly { model.reset() }
                refresh(); return true
            }

            if !points.isEmpty { points.removeLast(); model.selecting = !points.isEmpty; needsDisplay = true }
        default: return false
        }
        refresh(); return true
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false; window?.invalidateCursorRects(for: self); needsDisplay = true }
        else { super.keyUp(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard !model.selecting, !model.paintingMask else { return }
        panOffset.x -= event.scrollingDeltaX
        panOffset.y -= event.scrollingDeltaY
        hover = nil; needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }
    func zoom(by factor: CGFloat, at anchor: CGPoint) {
        guard !model.selecting, !model.paintingMask else { return }
        let before = imageRect
        guard before.width > 0, before.height > 0, factor.isFinite, factor > 0 else { return }
        let pixel = model.session.pixelPoint(anchor, in: before)
        zoomScale = min(16, max(0.1, zoomScale * factor))
        let moved = canvasPoint(pixel)
        panOffset.x += anchor.x - moved.x
        panOffset.y += anchor.y - moved.y
        hover = nil; needsDisplay = true
    }
    private func finish() {
        do { try model.prepareReview(points: points); snappedPoint = nil; hover = nil; needsDisplay = true }
        catch { model.error = error.localizedDescription; points.removeAll(); previousHit = nil; snappedPoint = nil; alternatives = []; lastPointer = nil; stabilizer.reset(); model.selecting = false; needsDisplay = true }
    }

    private func updateRectangle(to point: CGPoint) {
        guard let start = rectangleStart else { return }
        let minX = floor(min(start.x, point.x)), minY = floor(min(start.y, point.y))
        let maxX = ceil(max(start.x, point.x)), maxY = ceil(max(start.y, point.y))
        points = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
                  CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
        needsDisplay = true
    }
}
