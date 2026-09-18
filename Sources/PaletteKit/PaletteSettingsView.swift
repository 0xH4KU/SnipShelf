import SwiftUI

package struct PaletteSettingsView: View {
    @Bindable var model: PaletteModel
    let includesSource: Bool

    package init(model: PaletteModel, includesSource: Bool = true) {
        self.model = model; self.includesSource = includesSource
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if includesSource {
                Picker("Color source", selection: $model.subjectOnly) {
                    Text("Whole Image").tag(false)
                    Text("Subject Only").tag(true)
                }.pickerStyle(.segmented)
                    .help("Subject Only excludes the detected background from the color proportions.")
            }
            Stepper("Up to \(model.limit) colors", value: $model.limit, in: 2...6)
            Slider(value: $model.mergeDistance, in: 0.03...0.16, onEditingChanged: { editing in
                if !editing { model.reanalyze() }
            }) { Text("Merge similar colors") }
                .help("Higher values combine more shades into each color.")
            HStack {
                Button("Save as Default") { model.saveDefaults() }
                    .help("Remember these settings for new images and future launches.")
                Button("Restore Default") { model.restoreDefaults() }
                    .help("Return to your saved color source, color limit, and merge strength.")
            }.disabled(model.usesSavedDefaults)
            Text(model.usesSavedDefaults ? "Using default" : "Unsaved changes")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy)
    }
}
