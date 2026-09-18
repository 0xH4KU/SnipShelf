import SwiftUI
import PaletteKit

struct ClipPaletteView: View {
    @Bindable var palette: PaletteModel
    let backdrop: Int

    var body: some View {
        VStack(spacing: 0) {
            if let result = palette.result, !palette.busy, !result.colors.isEmpty {
                PaletteStripView(colors: result.colors, subjectOnly: result.subjectOnly, settings: { palette.settingsPresented = true })
            } else {
                HStack {
                    if palette.busy { ProgressView().controlSize(.mini) }
                    Text(palette.busy ? "Analyzing colors…" : "No palette available").lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Analysis Settings", systemImage: "slider.horizontal.3") { palette.settingsPresented = true }
                        .labelStyle(.iconOnly).buttonStyle(.plain).help("Palette analysis settings")
                }.font(.caption).padding(10)
            }
        }.background(.bar)
            .popover(isPresented: $palette.settingsPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Analysis Settings").font(.headline)
                    if let result = palette.result {
                        Image(result.preview, scale: 1, label: Text("Area used for color analysis"))
                            .resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 120)
                            .background { ImageBackdrop(style: backdrop) }
                    }
                    PaletteSettingsView(model: palette)
                    if let error = palette.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(16).frame(width: 330)
            }
    }
}
