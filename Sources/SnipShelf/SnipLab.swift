import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SnipLabController: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow?
    private(set) var model: CanvasModel?
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Snip Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        NSApp.mainMenu = menu
        show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Snip Lab"
            window.isReleasedWhenClosed = false
            window.minSize = CGSize(width: 900, height: 600)
            window.center()
            self.window = window
            practice()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showImage(_ image: CGImage, name: String) {
        let next = CanvasModel(image: image, isScreen: false, preferences: preferences,
            fluidDrawing: preferences.object(forKey: "labFluidDrawing") as? Bool ?? true, complete: { _ in }, cancel: {})
        next.mode = model?.mode ?? .lasso
        next.showCutout = false
        // A trial stays in memory; Return and Escape both prepare the same image for another try.
        next.complete = { [weak next] _ in next?.reset() }
        next.cancel = { [weak next] in next?.reset() }
        model = next
        window?.contentView = NSHostingView(rootView: SnipLabView(model: next, sourceName: name,
            openImage: { [weak self] in self?.chooseImage() }, practice: { [weak self] in self?.practice() }))
    }

    func openImage(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { showImage(try ImageCore.load(url), name: url.lastPathComponent) }
        catch { report(error) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Snip Lab image"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic]
        if panel.runModal() == .OK, let url = panel.url { openImage(url) }
    }

    private func practice() {
        do { showImage(try Self.practiceImage(), name: "Practice board") }
        catch { report(error) }
    }

    private func report(_ error: Error) {
        if let model { model.error = error.localizedDescription }
        else { NSAlert(error: error).runModal() }
    }

    static func practiceImage() throws -> CGImage {
        let context = try ImageCore.context(width: 1200, height: 900)
        context.setFillColor(CGColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        context.setFillColor(CGColor(srgbRed: 0.17, green: 0.48, blue: 0.4, alpha: 1))
        let curve = CGMutablePath()
        curve.move(to: CGPoint(x: 130, y: 530))
        curve.addCurve(to: CGPoint(x: 440, y: 760), control1: CGPoint(x: 65, y: 790), control2: CGPoint(x: 390, y: 880))
        curve.addCurve(to: CGPoint(x: 510, y: 510), control1: CGPoint(x: 460, y: 670), control2: CGPoint(x: 615, y: 680))
        curve.addCurve(to: CGPoint(x: 130, y: 530), control1: CGPoint(x: 450, y: 345), control2: CGPoint(x: 220, y: 430))
        curve.closeSubpath(); context.addPath(curve); context.fillPath()

        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.38, blue: 0.64, alpha: 1))
        context.addLines(between: [CGPoint(x: 720, y: 770), CGPoint(x: 1030, y: 770),
            CGPoint(x: 1030, y: 610), CGPoint(x: 930, y: 610), CGPoint(x: 1030, y: 440),
            CGPoint(x: 690, y: 480), CGPoint(x: 770, y: 610)])
        context.closePath(); context.fillPath()

        context.setFillColor(CGColor(srgbRed: 0.28, green: 0.32, blue: 0.36, alpha: 1))
        for x in stride(from: 140, through: 510, by: 12) {
            context.fill(CGRect(x: x, y: 130, width: 4, height: 160))
        }
        context.setFillColor(CGColor(srgbRed: 0.84, green: 0.83, blue: 0.8, alpha: 1))
        context.fillEllipse(in: CGRect(x: 730, y: 95, width: 300, height: 235))
        guard let image = context.makeImage() else { throw ShelfError("The practice board could not be created.") }
        return image
    }
}

struct SnipLabView: View {
    @Bindable var model: CanvasModel
    let sourceName: String
    let openImage: () -> Void
    let practice: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(sourceName).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Practice Board", action: practice)
                Button("Open Image…", action: openImage).keyboardShortcut("o", modifiers: .command)
                Divider().frame(height: 18)
                HStack {
                    Button("Fit") { model.fit() }
                    Button("100%") { model.actualSize = true; model.scale = 1; model.offset = .zero }
                    Button { model.scale = max(0.1, model.scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .accessibilityLabel("Zoom out")
                    Button { model.scale = min(16, model.scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .accessibilityLabel("Zoom in")
                }.disabled(model.selecting || model.paintingMask)
            }.padding(14)
            Divider()
            HStack(spacing: 0) {
                SelectionCanvas(model: model)
                    .accessibilityHint("Draw to review. Restore and Erase touch up the mask. Hold Space and drag to pan. Command-Z undoes a stroke. Escape leaves touch-up; Return starts another try.")
                    .task { await model.analyzeEdges() }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !model.reviewing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Drawing feel").font(.headline)
                                Picker("Drawing feel", selection: $model.fluidDrawing) {
                                    Text("Classic").tag(false)
                                    Text("Fluid").tag(true)
                                }.pickerStyle(.segmented).labelsHidden()
                                Text(model.fluidDrawing
                                    ? "Steady slow strokes, responsive sweeps. The start ring lights up when you can release to close. Option bypasses closing help."
                                    : "The current app's drawing feel. Switch modes to compare on the same image.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.disabled(model.selecting)
                            SelectionAssistanceView(model: model).disabled(model.selecting)
                            HStack {
                                Button("Raw") { model.smoothing = 0; model.snapEnabled = false; model.subjectMaskEnabled = false; model.fluidDrawing = false }
                                    .help("Turn off drawing assistance and the subject mask")
                                Button("App Defaults") { model.smoothing = 0.55; model.snapEnabled = true; model.snapRadius = 10; model.subjectMaskEnabled = true; model.fluidDrawing = false }
                                    .help("Restore the app's default assistance for the next stroke")
                            }.disabled(model.selecting)
                            Text("Drawing settings apply to your next stroke.")
                                .font(.caption).foregroundStyle(.secondary)
                            Divider()
                        }
                        if let image = model.reviewImage {
                            Text("Selection preview").font(.headline)
                            SubjectMaskControl(model: model).disabled(model.paintingMask)
                            Image(nsImage: NSImage(cgImage: image, size: .zero))
                                .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 110)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("Trial cutout")
                            Picker("Canvas preview", selection: $model.showCutout) {
                                Text("Original").tag(false)
                                Text("Cutout").tag(true)
                            }.pickerStyle(.segmented).disabled(model.paintingMask)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Manual touch-up").font(.headline)
                                Picker("Touch-up tool", selection: $model.maskTool) {
                                    ForEach(CanvasModel.MaskTool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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
                                    : "Turn on Subject mask to touch up the result.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.disabled(!model.canTouchUp || model.paintingMask)
                            Text("\(image.width) × \(image.height) px · \(model.reviewPoints.count) points")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            HStack {
                                Button("Refine Outline") { model.continueSelection() }.disabled(model.paintingMask)
                                Spacer()
                                Button("Next Try") { model.confirm() }
                                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.canConfirm)
                            }
                        } else {
                            Text("Draw, adjust, repeat.").font(.headline)
                            Text("Try the curves, sharp corners, dense lines and faint edge. Release a lasso or finish a polygon to review.")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(model.editingMask ? "Done" : "Redraw") {
                                if model.editingMask { model.leaveMaskEditing() } else { model.reset() }
                            }.keyboardShortcut(.cancelAction)
                            Button("Undo") { model.undoSelection() }
                                .keyboardShortcut("z", modifiers: .command).disabled(!model.canUndo)
                            if model.canTouchUp {
                                Button("Redo") { model.redoMaskStroke() }
                                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedoMask || model.paintingMask)
                            }
                        }
                        if let error = model.error {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        Text("\(model.editingMask ? "Esc finishes touch-up" : "Esc redraws") · ⌘Z undoes\nTrial cutouts stay in this window.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 300)
            }
        }
    }
}
