import SwiftUI

struct ClipImageControls: View {
    let app: AppController
    let clip: Clip
    @Binding var backdrop: Int
    @Binding var actualSize: Bool
    @Binding var zoomReset: Int

    var body: some View {
        HStack(spacing: 8) {
            Menu("Image Background", systemImage: "circle.lefthalf.filled") {
                Picker("Background", selection: $backdrop) {
                    Text("Checkerboard").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }
            }.labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize().buttonHover().help("Image background")
            ControlGroup {
                Button("Fit") { actualSize = false; zoomReset += 1 }.buttonHover().help("Fit image (⌘0)")
                Button("100%") { actualSize = true; zoomReset += 1 }.buttonHover().help("Actual pixels (⌘1)")
            }.fixedSize()
            Spacer(minLength: 0)
            Button(app.copiedClipID == clip.id ? "Copied" : "Copy",
                   systemImage: app.copiedClipID == clip.id ? "checkmark" : "doc.on.doc") { app.copy(clip) }
                .buttonHover()
                .help("Copy image (⌘C)").accessibilityInputLabels(["Copy", "Copy Image"])
        }.buttonStyle(.bordered).controlSize(.small).padding(10).background(.bar)
            .help("\(clip.width) × \(clip.height) px · Pinch to zoom · Scroll to pan")
    }
}
