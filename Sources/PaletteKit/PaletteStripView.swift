import AppKit
import SwiftUI

package struct PaletteStripView: View {
    let colors: [PaletteSwatch]
    let subjectOnly: Bool
    let settings: (() -> Void)?
    @State private var hovered: Int?
    @State private var copied: (id: UUID, hex: String)?

    package init(colors: [PaletteSwatch], subjectOnly: Bool, settings: (() -> Void)? = nil) {
        self.colors = colors; self.subjectOnly = subjectOnly; self.settings = settings
    }

    package var body: some View {
        VStack(spacing: 0) {
            if !colors.isEmpty {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(colors.indices, id: \.self) { i in
                            let swatch = colors[i]
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(swatch.hex, forType: .string)
                                copied = (UUID(), swatch.hex)
                            } label: {
                                Rectangle().fill(Color(.sRGB, red: swatch.rgb.x, green: swatch.rgb.y, blue: swatch.rgb.z))
                                    .overlay { if hovered == i { Rectangle().strokeBorder(.white.opacity(0.85), lineWidth: 2) } }
                            }.buttonStyle(.plain).frame(width: geometry.size.width * swatch.fraction)
                                .accessibilityLabel("\(swatch.hex), \(swatch.percentage). Copy HEX")
                                .help("\(swatch.hex) · \(swatch.percentage) · Click to copy")
                                .onHover { inside in hovered = inside ? i : nil }
                        }
                    }
                }.frame(height: 36)
            }
            HStack(spacing: 8) {
                if let copied { Text("Copied \(copied.hex)").foregroundStyle(.tint) }
                else if let hovered, colors.indices.contains(hovered) {
                    Text("\(colors[hovered].hex) · \(colors[hovered].percentage)").monospaced()
                } else { Text(colors.isEmpty ? "No visible colors" : "\(colors.count) colors · \(subjectOnly ? "Subject" : "Whole image")") }
                Spacer(minLength: 0)
                if let settings {
                    Button("Analysis Settings", systemImage: "slider.horizontal.3", action: settings)
                        .labelStyle(.iconOnly).buttonStyle(.plain).help("Palette analysis settings")
                } else if !colors.isEmpty { Text("Click a color to copy HEX").foregroundStyle(.secondary) }
            }.font(.caption).lineLimit(1).padding(.horizontal, 10).frame(height: 30).background(.bar)
        }
        .task(id: copied?.id) {
            guard copied != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = nil } catch { }
        }
        .onChange(of: colors) { hovered = nil; copied = nil }
    }
}
