import AppKit
import Observation

package struct PaletteResult {
    package let image: CGImage
    package let name: String
    package let colors: [PaletteSwatch]
    package let subjectOnly: Bool
    package let subject: Result<CGImage, Error>?

    package var preview: CGImage { subjectOnly ? (try? subject?.get()) ?? image : image }
}

@MainActor @Observable
package final class PaletteModel {
    package private(set) var result: PaletteResult?
    package private(set) var busy = false
    package var error: String?
    package var settingsPresented = false
    package var limit = 3 { didSet { if limit != oldValue { reanalyze() } } }
    package var mergeDistance = 0.08
    package var subjectOnly = true { didSet { if subjectOnly != oldValue { reanalyze() } } }
    package let defaults: PaletteDefaults
    package var usesSavedDefaults: Bool { (limit, mergeDistance, subjectOnly) == defaults.values }
    @ObservationIgnored private var restoringDefaults = false
    @ObservationIgnored private var task: Task<Void, Never>?

    package init(defaults: PaletteDefaults) {
        self.defaults = defaults
        limit = defaults.values.limit; mergeDistance = defaults.values.mergeDistance; subjectOnly = defaults.values.subjectOnly
    }
    package convenience init(preferences: UserDefaults = .standard) {
        self.init(defaults: PaletteDefaults(preferences: preferences))
    }

    deinit { task?.cancel() }
    package func cancel() { task?.cancel(); task = nil; busy = false }
    package func saveDefaults() { defaults.save(limit: limit, mergeDistance: mergeDistance, subjectOnly: subjectOnly) }
    package func restoreDefaults() {
        restoringDefaults = true
        limit = defaults.values.limit; mergeDistance = defaults.values.mergeDistance; subjectOnly = defaults.values.subjectOnly
        restoringDefaults = false
        reanalyze()
    }
    package func open(_ url: URL) {
        analyze(name: url.lastPathComponent) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try PaletteAnalysis.load(url)
        }
    }
    package func paste() {
        let board = NSPasteboard.general
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            analyze(name: "Clipboard image") { try PaletteAnalysis.load(data) }
        } else { error = "Copy an image first, then paste it here." }
    }
    package func reanalyze() {
        guard !restoringDefaults, let result else { return }
        analyze(name: result.name, subject: result.subject) { result.image }
    }
    package func analyze(name: String, subject: Result<CGImage, Error>? = nil, source: @escaping @Sendable () throws -> CGImage) {
        task?.cancel(); busy = true; error = nil
        let limit = limit, mergeDistance = mergeDistance, subjectOnly = subjectOnly
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try source()
            // Cache recognition (including no-subject results) while tuning the same image.
            let subject = subject ?? (subjectOnly ? Result { try PaletteAnalysis.subject(in: image) } : nil)
            try Task.checkCancellation()
            let analyzedImage = subjectOnly ? try? subject?.get() : image
            return PaletteResult(image: image, name: name,
                colors: try analyzedImage.map { try PaletteAnalysis.colors(in: $0, limit: limit, mergeDistance: mergeDistance) } ?? [],
                subjectOnly: subjectOnly, subject: subject)
        }
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.busy = false
            switch outcome {
            case .success(let result):
                self.result = result
                if result.subjectOnly, case .failure(let error) = result.subject {
                    self.error = "Subject analysis unavailable: \(error.localizedDescription)"
                }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
}
