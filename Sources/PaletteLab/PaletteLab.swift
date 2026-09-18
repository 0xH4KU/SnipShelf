import AppKit
import SwiftUI
import PaletteKit
import UniformTypeIdentifiers

@main
struct PaletteLabMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = PaletteLabController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        withExtendedLifetime(controller) { app.run() }
    }
}

extension PaletteModel {
    func example(_ example: PaletteExample) { analyze(name: example.rawValue) { try example.image() } }
}

@MainActor
final class PaletteLabController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: PaletteModel
    private var window: NSWindow?
    private var pins: [NSWindow] = []

    init(preferences: UserDefaults = .standard) {
        model = PaletteModel(preferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        for (title, entries): (String, [(String, Selector, String)]) in [
            ("Palette Lab", [("Quit Palette Lab", #selector(NSApplication.terminate(_:)), "q")]),
            ("File", [("Open Image…", #selector(chooseImage), "o"), ("Paste Image", #selector(pasteImage), "v"),
                      ("Pin Image", #selector(pinImage), "p"), ("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        ] {
            let item = NSMenuItem(); item.submenu = NSMenu(title: title)
            for (name, action, key) in entries {
                let command = item.submenu!.addItem(withTitle: name, action: action, keyEquivalent: key)
                if [#selector(chooseImage), #selector(pasteImage), #selector(pinImage)].contains(action) { command.target = self }
            }
            menu.addItem(item)
        }
        NSApp.mainMenu = menu
        show()
        if model.result == nil && !model.busy { model.example(.stillLife) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { show(); model.open(url) }
    }
    private func show() {
        if window == nil {
            let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 740, height: 680),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "Palette Lab"
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = CGSize(width: 520, height: 440)
            panel.contentView = NSHostingView(rootView: PaletteLabView(model: model, open: { [weak self] in self?.chooseImage() },
                                                                     pin: { [weak self] in self?.pinImage() }))
            panel.center(); window = panel
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    @objc private func chooseImage() {
        show()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.title = "Open an image in Palette Lab"
        panel.beginSheetModal(for: window!) { [weak self] response in
            if response == .OK, let url = panel.url { self?.model.open(url) }
        }
    }
    @objc private func pasteImage() { show(); model.paste() }
    @objc func pinImage() {
        guard let result = model.result, !result.colors.isEmpty, !model.busy else { return }
        let size = CGSize(width: 360, height: min(520, max(240, 360 * Double(result.image.height) / Double(result.image.width) + 64)))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = result.name + " — Palette"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentMinSize = CGSize(width: 220, height: 180)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PaletteImageView(result: result))
        panel.delegate = self
        let visible = window?.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let offset = CGFloat(pins.count % 6) * 24
        panel.setFrameOrigin(CGPoint(x: visible.maxX - panel.frame.width - 24 - offset, y: visible.maxY - panel.frame.height - 40 - offset))
        pins.append(panel); panel.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { pins.removeAll { $0 === notification.object as? NSWindow } }
}

struct PaletteLabView: View {
    @Bindable var model: PaletteModel
    let open: () -> Void
    let pin: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu("Examples", systemImage: "square.grid.2x2") {
                    ForEach(PaletteExample.allCases, id: \.self) { example in
                        Button(example.rawValue) { model.example(example) }
                    }
                }.fixedSize()
                Button("Open Image…", action: open)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Pin", systemImage: "pin", action: pin).disabled(model.result?.colors.isEmpty != false || model.busy)
            }.padding(12).background(.bar)
            Divider()
            if let result = model.result { PaletteImageView(result: result) }
            else { ContentUnavailableView("Drop an Image", systemImage: "photo", description: Text("Open, paste, or drop an image to explore its colors.")) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.result?.name ?? "Palette Lab").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("Drop an image to try another").foregroundStyle(.secondary)
                }.font(.caption)
                Picker("Color source", selection: $model.subjectOnly) {
                    Text("Whole Image").tag(false)
                    Text("Subject Only").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                    .help("Subject Only excludes the detected background and previews the area used for the palette.")
                    .disabled(model.busy)
                DisclosureGroup("Analysis Settings") {
                    PaletteSettingsView(model: model, includesSource: false).padding(.top, 8)
                }.font(.callout)
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(12).background(.bar)
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            model.open(url); return true
        } isTargeted: { targeted = $0 }
    }
}

struct PaletteImageView: View {
    let result: PaletteResult
    @Environment(\.colorScheme) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Image(result.preview, scale: 1, label: Text(result.name)).resizable().interpolation(.high).scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityLabel(result.name)
            }.background {
                Canvas { context, size in
                    let base = appearance == .dark ? 0.16 : 0.96
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: base)))
                    for y in stride(from: 0.0, to: size.height, by: 12) {
                        for x in stride(from: 0.0, to: size.width, by: 12) where (Int(x / 12) + Int(y / 12)).isMultiple(of: 2) {
                            context.fill(Path(CGRect(x: x, y: y, width: 12, height: 12)), with: .color(Color(white: base - 0.035)))
                        }
                    }
                }.accessibilityHidden(true)
            }.clipped()
            PaletteStripView(colors: result.colors, subjectOnly: result.subjectOnly)
        }
    }
}
