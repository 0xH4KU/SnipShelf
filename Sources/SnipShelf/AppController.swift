import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon
import UniformTypeIdentifiers
import Observation
import Darwin

@main
struct SnipShelfMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        if Bundle.main.bundleIdentifier == "org.snipshelf.lab" {
            let controller = SnipLabController()
            application.delegate = controller
            application.setActivationPolicy(.regular)
            withExtendedLifetime(controller) { application.run() }
            return
        }
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { application.run() }
    }
}

@MainActor @Observable
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: ShelfStore
    let shelf: ShelfWindow
    let defaults: UserDefaults
    var busy = false
    var isDraggingClips = false
    var draggedClipIDs: Set<UUID> = []
    var backdrop: Int { didSet { defaults.set(backdrop, forKey: "backdrop") } }
    var shortcutLabel: String
    var previewClip: Clip? { didSet { updatePreview() } }
    var status: String?
    @ObservationIgnored private var statusItem: NSStatusItem!
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var hotKeyHandler: EventHandlerRef?
    @ObservationIgnored private var captureWindow: NSWindow?
    @ObservationIgnored private(set) var captureModel: CanvasModel?
    @ObservationIgnored private var captureReviewWindow: ShelfPanel?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var aboutWindow: NSWindow?
    @ObservationIgnored private var previewWindow: ShelfPanel?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    @ObservationIgnored private var terminationSignal: DispatchSourceSignal?

    init(store: ShelfStore? = nil, preferences: UserDefaults? = nil) {
        let args = ProcessInfo.processInfo.arguments
        var qaRoot: URL?
        if let index = args.firstIndex(of: "--qa-directory"), args.count > index + 1 {
            qaRoot = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        defaults = preferences ?? (qaRoot == nil ? .standard : UserDefaults(suiteName: "org.snipshelf.app.qa")!)
        self.store = store ?? ShelfStore(root: qaRoot)
        shelf = ShelfWindow(defaults: defaults)
        backdrop = defaults.integer(forKey: "backdrop")
        shortcutLabel = defaults.string(forKey: "shortcutLabel") ?? "⌘⇧2"
        super.init()
    }

    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            let paper = CGMutablePath()
            paper.move(to: CGPoint(x: 8, y: 1.5))
            paper.addCurve(to: CGPoint(x: 10.4, y: 3.2), control1: CGPoint(x: 9.3, y: 1.4), control2: CGPoint(x: 9.8, y: 1.8))
            paper.addCurve(to: CGPoint(x: 13.1, y: 4.7), control1: CGPoint(x: 11, y: 4.5), control2: CGPoint(x: 11.8, y: 4.8))
            paper.addCurve(to: CGPoint(x: 16.4, y: 6.8), control1: CGPoint(x: 14.8, y: 4.3), control2: CGPoint(x: 16.3, y: 5.2))
            paper.addCurve(to: CGPoint(x: 15.4, y: 9.5), control1: CGPoint(x: 16.8, y: 7.8), control2: CGPoint(x: 16.2, y: 8.8))
            paper.addCurve(to: CGPoint(x: 13.1, y: 14.2), control1: CGPoint(x: 14.4, y: 10.4), control2: CGPoint(x: 14.1, y: 12.7))
            paper.addCurve(to: CGPoint(x: 9.7, y: 16.5), control1: CGPoint(x: 12.3, y: 15.7), control2: CGPoint(x: 11.4, y: 16.5))
            paper.addCurve(to: CGPoint(x: 6.2, y: 14.8), control1: CGPoint(x: 8.1, y: 16.7), control2: CGPoint(x: 7.1, y: 16.2))
            paper.addCurve(to: CGPoint(x: 4.4, y: 12), control1: CGPoint(x: 5.5, y: 14.1), control2: CGPoint(x: 5.7, y: 12.7))
            paper.addCurve(to: CGPoint(x: 1.7, y: 9.8), control1: CGPoint(x: 3.5, y: 11.5), control2: CGPoint(x: 1.6, y: 11.3))
            paper.addCurve(to: CGPoint(x: 3.4, y: 7.1), control1: CGPoint(x: 1.5, y: 8.4), control2: CGPoint(x: 2.1, y: 7.7))
            paper.addCurve(to: CGPoint(x: 5.4, y: 5.8), control1: CGPoint(x: 4.4, y: 6.7), control2: CGPoint(x: 5.6, y: 6.8))
            paper.addCurve(to: CGPoint(x: 5.5, y: 3.7), control1: CGPoint(x: 5.7, y: 5.1), control2: CGPoint(x: 5.1, y: 4.4))
            paper.addCurve(to: CGPoint(x: 8, y: 1.5), control1: CGPoint(x: 5.7, y: 2.4), control2: CGPoint(x: 6.8, y: 1.5))
            paper.closeSubpath()
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(paper); context.fillPath()
            // A transparent crease keeps the peeled corner legible in either appearance.
            context.setBlendMode(.clear)
            context.setLineWidth(1)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: 15.1, y: 9.2))
            context.addCurve(to: CGPoint(x: 12.3, y: 10.9), control1: CGPoint(x: 14.6, y: 10.3), control2: CGPoint(x: 12.8, y: 10))
            context.addCurve(to: CGPoint(x: 12.1, y: 14), control1: CGPoint(x: 11.6, y: 11.8), control2: CGPoint(x: 12.4, y: 13))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SnipShelf"
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination
        shelf.install(content: ShelfView(app: self), key: { [weak self] in self?.handleKey($0) ?? false })
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.setAccessibilityLabel("SnipShelf")
        statusItem.button?.toolTip = "SnipShelf"
        let menu = NSMenu()
        menu.addItem(actionItem("Capture Element", action: #selector(captureAction)))
        menu.addItem(actionItem("Show Shelf", action: #selector(showAction)))
        menu.addItem(actionItem("Import Images…", action: #selector(importAction)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Settings…", action: #selector(settingsAction), key: ","))
        menu.addItem(actionItem("About SnipShelf", action: #selector(aboutAction)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit SnipShelf", action: #selector(quitAction), key: "q"))
        statusItem.menu = menu
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activatedApp(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        installHotKeyHandler()
        let code = defaults.object(forKey: "shortcutCode") as? UInt32 ?? UInt32(kVK_ANSI_2)
        let modifiers = defaults.object(forKey: "shortcutModifiers") as? UInt32 ?? UInt32(cmdKey | shiftKey)
        registerShortcut(code: code, modifiers: modifiers, label: shortcutLabel)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if captureModel?.hasOutline == true {
            let alert = NSAlert()
            alert.messageText = "A selection has not been confirmed"
            alert.informativeText = "Keep working to confirm it, or discard it and quit."
            alert.addButton(withTitle: "Keep Working"); alert.addButton(withTitle: "Discard and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        if store.pendingImage != nil {
            let alert = NSAlert()
            alert.messageText = "An unsaved clip is still in memory"
            alert.informativeText = "Retry saving or export the clip before quitting. Quitting now discards it."
            alert.addButton(withTitle: "Keep Working"); alert.addButton(withTitle: "Discard and Quit")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        shelf.persist()
        return .terminateNow
    }
    func application(_ application: NSApplication, open urls: [URL]) { importURLs(urls) }
    private func actionItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    @objc private func activatedApp(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalApp = app }
    }
    private func rememberFocus() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : front
    }
    @objc func captureAction() { capture() }
    @objc func showAction() { shelf.expand(); shelf.panel.makeKeyAndOrderFront(nil) }
    @objc func importAction() { chooseImages() }
    @objc func settingsAction() { showSettings() }
    @objc func aboutAction() { showAbout() }
    @objc func quitAction() { NSApp.terminate(nil) }
    @objc private func selectedCopy() { if let clip = store.selectedClip { copy(clip) } }
    @objc private func selectedCrop() { if let clip = store.selectedClip { recrop(clip) } }
    @objc private func selectedExport() { if let clip = store.selectedClip { export(clip) } }
    @objc private func selectedDelete() { store.delete(store.selectedIDs) }
    @objc private func selectedPreview() { previewClip = store.selectedClip }
    @objc private func selectedNewFolder() { editFolder(including: store.selectedIDs) }
    @objc private func selectedMove(_ sender: NSMenuItem) {
        store.move(store.selectedIDs, to: (sender.representedObject as? String).flatMap(UUID.init(uuidString:)))
    }

    func openFolder(_ id: UUID?) {
        previewClip = nil
        store.openFolder(id)
    }

    func editFolder(_ folder: ShelfFolder? = nil, including ids: Set<UUID> = []) {
        let alert = NSAlert()
        alert.messageText = folder == nil ? "New Group" : "Rename Group"
        alert.informativeText = folder == nil && !ids.isEmpty ? "Move \(ids.count) selected clips into this group." : "Give these references a name."
        let field = NSTextField(string: folder?.name ?? "")
        field.placeholderString = "Group name"
        field.setAccessibilityLabel("Group name")
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: folder == nil ? "Create" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if let folder { try store.renameFolder(folder.id, name: field.stringValue) }
            else { openFolder(try store.createFolder(name: field.stringValue, including: ids).id) }
        } catch { store.message = error.localizedDescription }
    }

    func folderMenu(_ folder: ShelfFolder) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [("Rename Group…", #selector(renameFolderAction(_:))),
                                ("Dissolve Group — Keep Clips", #selector(dissolveFolderAction(_:)))] {
            let item = actionItem(title, action: action)
            item.representedObject = folder
            item.isEnabled = !store.isReadOnly
            menu.addItem(item)
        }
        return menu
    }
    @objc private func renameFolderAction(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? ShelfFolder { editFolder(folder) }
    }
    @objc private func dissolveFolderAction(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? ShelfFolder { store.dissolveFolder(folder.id) }
    }

    func clipMenu(_ clip: Clip) -> NSMenu {
        if !store.selectedIDs.contains(clip.id) { store.selection = clip.id }
        let menu = NSMenu()
        if store.selectedIDs.count == 1 {
        menu.addItem(actionItem("Preview", action: #selector(selectedPreview)))
        menu.addItem(actionItem("Copy Image", action: #selector(selectedCopy)))
        menu.addItem(actionItem("Export PNG…", action: #selector(selectedExport)))
        menu.addItem(actionItem("Crop a Copy…", action: #selector(selectedCrop)))
        menu.addItem(.separator())
        }
        menu.addItem(actionItem("New Group with Selection…", action: #selector(selectedNewFolder)))
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let destinations = NSMenu()
        if store.currentFolderID != nil { destinations.addItem(actionItem("Shelf", action: #selector(selectedMove(_:)))) }
        for folder in store.folders where folder.id != store.currentFolderID {
            let item = actionItem(folder.name, action: #selector(selectedMove(_:)))
            item.representedObject = folder.id.uuidString
            destinations.addItem(item)
        }
        if !destinations.items.isEmpty { move.submenu = destinations; menu.addItem(move) }
        menu.addItem(.separator())
        menu.addItem(actionItem(store.selectedIDs.count > 1 ? "Delete \(store.selectedIDs.count) Clips" : "Delete", action: #selector(selectedDelete)))
        return menu
    }

    private func readyForNewImage() -> Bool {
        guard store.pendingImage == nil else {
            store.message = "Save or export your unsaved clip before adding another image."; return false
        }
        return !busy && captureWindow == nil
    }
    func capture() {
        guard readyForNewImage() else { return }
        rememberFocus()
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            store.message = "Allow SnipShelf in System Settings → Privacy & Security → Screen & System Audio Recording, then try Capture again. Importing images works without this permission."
            return
        }
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let frame = screen.frame
        busy = true
        Task {
            defer { busy = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screenNumber.uint32Value }) else {
                    throw ShelfError("This display is no longer connected. Try Capture again.")
                }
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                // display.width can already be pixels; use the filter's point rect to avoid double scaling.
                configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                configuration.showsCursor = false
                configuration.captureResolution = .best
                configuration.colorSpaceName = CGColorSpace.sRGB
                let raw = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let image = try ImageCore.sRGB(raw)
                guard NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenNumber.uint32Value }) else {
                    throw ShelfError("The display was disconnected. Try Capture on another screen.")
                }
                presentCanvas(image: image, frame: frame, screenCapture: true, name: "Clip \(Date().formatted(date: .omitted, time: .shortened))")
            } catch { restoreFocus(); store.message = "Capture failed. \(error.localizedDescription)" }
        }
    }

    func recrop(_ clip: Clip) {
        guard readyForNewImage() else { return }
        do {
            let image = try ImageCore.load(store.url(for: clip))
            rememberFocus()
            let visible = shelf.screen.visibleFrame
            let size = CGSize(width: min(960, visible.width - 60), height: min(720, visible.height - 60))
            presentCanvas(image: image, frame: CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
                          screenCapture: false, name: "\(clip.name) — crop")
        } catch { store.message = error.localizedDescription }
    }
    func presentCanvas(image: CGImage, frame: CGRect, screenCapture: Bool, name: String) {
        let folderID = store.currentFolderID
        let model = CanvasModel(image: image, isScreen: screenCapture, preferences: defaults, complete: { [weak self] output in
            guard let self else { return }
            self.dismissCanvas()
            self.store.receive(output, name: name, folderID: folderID)
        }, cancel: { [weak self] in self?.dismissCanvas() })
        let style: NSWindow.StyleMask = screenCapture ? [.borderless] : [.titled, .resizable]
        let window = ShelfPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "Crop a Copy"
        window.isReleasedWhenClosed = false
        window.level = screenCapture ? .screenSaver : .floating
        window.minSize = CGSize(width: 640, height: 420)
        window.contentView = NSHostingView(rootView: CaptureView(model: model))
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        captureModel = model; captureWindow = window
        model.reviewReady = { [weak self] in self?.presentCaptureReview() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    private func dismissCanvas() {
        captureReviewWindow?.delegate = nil
        captureReviewWindow?.close(); captureReviewWindow = nil
        captureWindow?.orderOut(nil); captureWindow?.close(); captureWindow = nil; captureModel = nil
        restoreFocus()
    }
    private func presentCaptureReview() {
        guard let model = captureModel, let image = model.reviewImage, let canvasWindow = captureWindow else { return }
        func canvas(in view: NSView) -> CanvasNSView? {
            if let view = view as? CanvasNSView { return view }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        let selection = canvasWindow.contentView.flatMap { canvas(in: $0)?.reviewScreenRect } ?? canvasWindow.frame
        let visible = canvasWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? canvasWindow.frame
        let size = CGSize(width: min(340, visible.width),
                          height: min(visible.height - 30, max(110, min(250, 288 * CGFloat(image.height) / CGFloat(image.width))) + 126))
        let panel = ShelfPanel(contentRect: CGRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Capture Preview"
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CaptureReviewView(model: model, refine: { [weak self] in
            self?.editCapture(refineOutline: true)
        }, touchUp: { [weak self] in self?.editCapture(refineOutline: false) }))
        panel.onKey = { [weak model] event in
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            switch event.keyCode {
            case 36, 76: model?.confirm()
            case 53: model?.cancel()
            default: return false
            }
            return true
        }
        var origin = CGPoint(x: selection.midX - panel.frame.width / 2, y: selection.minY - panel.frame.height - 12)
        if origin.y < visible.minY { origin.y = selection.maxY + 12 }
        origin.x = min(max(visible.minX, origin.x), visible.maxX - panel.frame.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
        captureReviewWindow?.delegate = nil
        captureReviewWindow?.close()
        captureReviewWindow = panel
        canvasWindow.orderOut(nil)
        panel.makeKeyAndOrderFront(nil)
    }
    func editCapture(refineOutline: Bool) {
        guard let model = captureModel, model.reviewing, !model.paintingMask,
              refineOutline || model.canTouchUp else { return }
        captureReviewWindow?.delegate = nil
        captureReviewWindow?.close(); captureReviewWindow = nil
        if refineOutline { model.continueSelection() }
        else { model.showCutout = false; model.maskTool = .restore }
        captureWindow?.makeKeyAndOrderFront(nil)
    }
    private func restoreFocus() {
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp.activate() }
        previousApp = nil
    }

    func chooseImages() {
        guard readyForNewImage() else { return }
        let panel = NSOpenPanel()
        panel.title = "Add images to your shelf"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }
    func importURLs(_ urls: [URL]) {
        guard readyForNewImage() else { return }
        let folderID = store.currentFolderID
        busy = true
        Task {
            defer { busy = false }
            var failures: [String] = []
            for url in urls {
                guard store.pendingImage == nil else { break }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard url.isFileURL else { throw ShelfError("Only local image files can be imported.") }
                    let image = try await Task.detached(priority: .userInitiated) { try ImageCore.load(url) }.value
                    store.receive(image, name: url.deletingPathExtension().lastPathComponent, folderID: folderID)
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { store.message = failures.prefix(5).joined(separator: "\n") }
        }
    }
    func dropIntoFolder(_ providers: [NSItemProvider], folderID: UUID?) -> Bool {
        shelf.dropTargeted = false
        shelf.dropFinished()
        if isDraggingClips { return store.move(draggedClipIDs, to: folderID) }
        return acceptDrop(providers, folderID: folderID)
    }
    func acceptDrop(_ providers: [NSItemProvider], folderID: UUID? = nil) -> Bool {
        guard !isDraggingClips, readyForNewImage() else { return false }
        shelf.dropFinished()
        busy = true
        Task {
            defer { busy = false }
            for provider in providers {
                guard store.pendingImage == nil else { break }
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await provider.data(for: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw ShelfError("Drop a local image file.") }
                        let image = try await Task.detached { try ImageCore.load(url) }.value
                        store.receive(image, name: url.deletingPathExtension().lastPathComponent, folderID: folderID)
                    } else {
                        let type = [UTType.png.identifier, UTType.tiff.identifier, UTType.image.identifier].first { provider.hasItemConformingToTypeIdentifier($0) }
                        guard let type else { continue }
                        let data = try await provider.data(for: type)
                        let image = try await Task.detached { try ImageCore.load(data) }.value
                        let name = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "Dropped image"
                        store.receive(image, name: name, folderID: folderID)
                    }
                } catch { store.message = error.localizedDescription }
            }
        }
        return true
    }
    func paste() {
        guard readyForNewImage() else { return }
        let board = NSPasteboard.general
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            do { store.receive(try ImageCore.load(data), name: "Pasted image", folderID: store.currentFolderID) }
            catch { store.message = error.localizedDescription }
        } else if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importURLs(urls)
        } else { store.message = "Copy an image or a local image file, then paste it here." }
    }
    func copy(_ clip: Clip) {
        do {
            let data = try Data(contentsOf: store.url(for: clip))
            let image = try ImageCore.load(data)
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { item.setData(tiff, forType: .tiff) }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else { throw ShelfError("The image could not be copied.") }
            flash("Copied image")
        } catch { store.message = error.localizedDescription }
    }
    func export(_ clip: Clip) {
        do { try exportData(Data(contentsOf: store.url(for: clip)), name: clip.name) }
        catch { store.message = error.localizedDescription }
    }
    func exportPending() {
        guard let image = store.pendingImage else { return }
        do {
            if try exportData(ImageCore.png(image), name: store.pendingName) { store.pendingImage = nil }
        } catch { store.message = error.localizedDescription }
    }
    @discardableResult private func exportData(_ data: Data, name: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try data.write(to: url, options: .atomic); return true
    }
    func clearShelf() {
        let alert = NSAlert()
        alert.messageText = "Clear all \(store.clips.count) clips?"
        alert.informativeText = "You can undo this until you quit SnipShelf. Exported files are unaffected."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear Shelf")
        if alert.runModal() == .alertSecondButtonReturn { store.delete(Set(store.clips.map(\.id))) }
    }
    func flash(_ value: String) {
        status = value
        Task { [weak self] in try? await Task.sleep(for: .seconds(2)); if self?.status == value { self?.status = nil } }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": paste()
            case "c": if let clip = store.selectedClip { copy(clip) }
            case "z": store.undo()
            case "a": store.selectedIDs = Set(store.visibleClips.map(\.id))
            case "o": chooseImages()
            case "n" where event.modifierFlags.contains(.shift): editFolder(including: store.selectedIDs)
            case "[": openFolder(nil)
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 49:
            if let id = store.selectedFolderID { openFolder(id) }
            else { previewClip = store.selectedClip }
        case 36:
            guard let id = store.selectedFolderID else { return false }
            openFolder(id)
        case 51, 117: store.delete(store.selectedIDs)
        case 53:
            if previewClip != nil { previewClip = nil }
            else if !store.selectedIDs.isEmpty || store.selectedFolderID != nil { store.selectedIDs = [] }
            else if store.currentFolderID != nil { openFolder(nil) }
            else { shelf.collapse() }
        case 123, 124, 125, 126:
            if event.modifierFlags.contains(.shift) { return false }
            let ids = (store.currentFolderID == nil ? store.folders.map(\.id) : []) + store.visibleClips.map(\.id)
            guard !ids.isEmpty else { return true }
            let current = ids.firstIndex { $0 == store.selection }
            let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? 2 : -2
            store.selection = ids[min(ids.count - 1, max(0, current.map { $0 + delta } ?? 0))]
        default: return false
        }
        return true
    }

    private func updatePreview() {
        guard let clip = previewClip else { previewWindow?.orderOut(nil); return }
        if store.currentFolderID != clip.folderID { store.openFolder(clip.folderID) }
        store.selection = clip.id
        if previewWindow == nil {
            let window = ShelfPanel(contentRect: CGRect(x: 0, y: 0, width: 720, height: 580),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = CGSize(width: 560, height: 420)
            window.level = .floating
            window.delegate = self
            window.contentView = NSHostingView(rootView: PreviewView(app: self))
            window.onKey = { [weak self] in self?.handlePreviewKey($0) ?? false }
            window.center()
            previewWindow = window
        }
        previewWindow?.title = clip.name
        NSApp.activate(ignoringOtherApps: true)
        previewWindow?.makeKeyAndOrderFront(nil)
    }
    var previewClips: [Clip] {
        guard let clip = store.clips.first(where: { $0.id == previewClip?.id }) else { return [] }
        return store.clips.filter { $0.folderID == clip.folderID }
    }
    func adjacentPreview(_ delta: Int) -> Clip? {
        guard let clip = previewClip else { return nil }
        let clips = previewClips
        guard let index = clips.firstIndex(where: { $0.id == clip.id }), clips.indices.contains(index + delta) else { return nil }
        return clips[index + delta]
    }
    func movePreview(_ delta: Int) {
        if let clip = adjacentPreview(delta) { previewClip = clip }
    }
    func handlePreviewKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 49, 53: previewClip = nil
            case 123: movePreview(-1)
            case 124: movePreview(1)
            default: return false
            }
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            if let clip = previewClip { copy(clip) }
            return true
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === previewWindow { previewClip = nil }
        if notification.object as? NSWindow === captureReviewWindow { dismissCanvas() }
    }

    private func installHotKeyHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in app.capture() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }
    func recordShortcut(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
            store.message = "Include Command or Control in your shortcut."; return
        }
        var modifiers: UInt32 = 0
        var label = ""
        for (flag, carbon, symbol): (NSEvent.ModifierFlags, Int, String) in [(.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if event.modifierFlags.contains(flag) { modifiers |= UInt32(carbon); label += symbol }
        }
        label += event.characters(byApplyingModifiers: [])?.uppercased() ?? "Key \(event.keyCode)"
        registerShortcut(code: UInt32(event.keyCode), modifiers: modifiers, label: label)
    }
    private func registerShortcut(code: UInt32, modifiers: UInt32, label: String) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let result = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x534E4950, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard result == noErr else {
            shortcutLabel = "Unavailable — choose another"
            store.message = "That shortcut could not be registered (\(result)). Choose another in Settings. Capture is still available in the menu bar."
            return
        }
        defaults.set(code, forKey: "shortcutCode"); defaults.set(modifiers, forKey: "shortcutModifiers")
        defaults.set(label, forKey: "shortcutLabel"); shortcutLabel = label
    }
    func showSettings() {
        if settingsWindow == nil { settingsWindow = utilityWindow(title: "SnipShelf Settings", size: CGSize(width: 460, height: 360), content: SettingsView(app: self)) }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func showAbout() {
        if aboutWindow == nil { aboutWindow = utilityWindow(title: "About SnipShelf", size: CGSize(width: 350, height: 290), content: AboutView()) }
        NSApp.activate(ignoringOtherApps: true); aboutWindow?.makeKeyAndOrderFront(nil)
    }
    private func utilityWindow(title: String, size: CGSize, content: some View) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content); window.center(); return window
    }
}

extension NSItemProvider {
    func data(for type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ShelfError("This dragged image could not be read.")) }
            }
        }
    }
}
