import XCTest
import AppKit
@testable import SnipShelf
@testable import PaletteKit

final class PaletteIntegrationTests: XCTestCase {
    @MainActor func testPreviewPaletteFollowsImageSharesDefaultsAndCancelsOnClose() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests.preview-palette." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(["limit": 3, "mergeDistance": 0.08, "subjectOnly": false], forKey: "analysisDefaults")
        let store = ShelfStore(root: root)
        let original = try SnipShelfTests().image(width: 400, height: 300)
        let firstClip = try store.add(original, name: "Preview colors")
        let context = try ImageCore.context(width: 300, height: 400)
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        let secondClip = try store.add(XCTUnwrap(context.makeImage()), name: "Next preview colors")
        let app = AppController(store: store, preferences: preferences)
        app.previewClip = firstClip
        let window = try XCTUnwrap(NSApp.windows.first { $0 is ShelfPanel && $0.title == firstClip.name })
        defer {
            window.close()
            for panel in Array(app.referenceWindows.values) { panel.close() }
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func finished(_ model: PaletteModel) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.busy)
            XCTAssertNil(model.error)
        }
        let first = try XCTUnwrap(app.previewPalette)
        try await finished(first)
        XCTAssertEqual(first.result?.colors.count, 2)
        XCTAssertEqual(first.result?.colors.first?.fraction ?? 0, 0.5, accuracy: 0.005)
        app.openReference(.clip(firstClip.id))
        try await finished(XCTUnwrap(app.referencePalettes[firstClip.id]))
        let pin = try XCTUnwrap(app.referenceWindows[.clip(firstClip.id)])
        try await Task.sleep(for: .milliseconds(100))
        let previewContent = try XCTUnwrap(window.contentView), pinContent = try XCTUnwrap(pin.contentView)
        previewContent.layoutSubtreeIfNeeded(); pinContent.layoutSubtreeIfNeeded()
        XCTAssertEqual(previewContent.bounds.width, 340)
        XCTAssertEqual(previewContent.bounds.width, pinContent.bounds.width)
        XCTAssertEqual(previewContent.bounds.height - pinContent.bounds.height, 42, accuracy: 1)
        func viewport(_ view: NSView) -> PreviewImage.ImageScrollView? {
            (view as? PreviewImage.ImageScrollView) ?? view.subviews.lazy.compactMap(viewport).first
        }
        let previewImage = try XCTUnwrap(viewport(previewContent)), pinnedImage = try XCTUnwrap(viewport(pinContent))
        XCTAssertEqual(previewImage.contentSize.height, pinnedImage.contentSize.height, accuracy: 1,
                       "Preview and Pin should give the image the same space")
        XCTAssertEqual(previewImage.magnification, pinnedImage.magnification, accuracy: 0.01)
        XCTAssertEqual(app.clipPasteboardItem(firstClip)?.data(forType: .png), try Data(contentsOf: store.url(for: firstClip)))
        if let destination = ProcessInfo.processInfo.environment["SNIPSHELF_RENDER_QA"] {
            let directory = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (appearance, suffix): (NSAppearance.Name, String) in [(.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(100))
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("preview-palette-" + suffix + ".png"))
            }
        }
        first.settingsPresented = true
        try await Task.sleep(for: .milliseconds(80))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        XCTAssertTrue(window.performKeyEquivalent(with: escape))
        XCTAssertFalse(first.settingsPresented)
        XCTAssertEqual(app.previewClip, firstClip, "Escape dismisses analysis settings before closing the preview")
        XCTAssertTrue(window.isVisible)
        first.limit = 5; first.saveDefaults()
        let firstName = first.result?.name
        first.analyze(name: "Stale preview") { Thread.sleep(forTimeInterval: 0.15); return original }
        app.previewClip = secondClip
        let second = try XCTUnwrap(app.previewPalette)
        XCTAssertFalse(first.busy)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.limit, 5)
        app.previewClip = secondClip
        XCTAssertTrue(app.previewPalette === second, "Focusing the same preview must reuse its analysis")
        try await finished(second)
        XCTAssertEqual(second.result?.name, store.url(for: secondClip).lastPathComponent)
        XCTAssertEqual(second.result?.colors.count, 1)
        XCTAssertEqual(second.result?.colors.first?.hex, "#00FF00")
        app.openReference(.clip(secondClip.id))
        XCTAssertEqual(app.referencePalettes[secondClip.id]?.limit, 5, "Preview and Pin share saved analysis defaults")
        let secondName = second.result?.name
        second.analyze(name: "Closed preview") { Thread.sleep(forTimeInterval: 0.15); return original }
        window.close()
        XCTAssertNil(app.previewPalette)
        XCTAssertFalse(second.busy)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(first.result?.name, firstName)
        XCTAssertEqual(second.result?.name, secondName, "Closed and replaced previews must discard pending results")
        app.previewClip = firstClip
        store.delete([firstClip.id])
        app.refreshPreviewTitle()
        XCTAssertNil(app.previewPalette)
        XCTAssertFalse(window.isVisible, "Deleting the previewed image also closes its palette")
    }

    @MainActor func testPinsAnalyzeIndependentlyShareDefaultsAndCancelOnClose() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "org.snipshelf.tests.palette-integration." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(["limit": 3, "mergeDistance": 0.08, "subjectOnly": false], forKey: "analysisDefaults")
        let store = ShelfStore(root: root)
        let original = try SnipShelfTests().image(width: 400, height: 300)
        let a = try store.add(original, name: "First palette")
        let b = try store.add(original, name: "Second palette")
        let c = try store.add(original, name: "New defaults")
        let bytes = try Data(contentsOf: store.url(for: a))
        let app = AppController(store: store, preferences: preferences)
        defer {
            for panel in Array(app.referenceWindows.values) { panel.close() }
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func finished(_ model: PaletteModel) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.busy)
        }
        app.openReference(.clip(a.id)); app.openReference(.clip(b.id))
        let first = try XCTUnwrap(app.referencePalettes[a.id])
        let second = try XCTUnwrap(app.referencePalettes[b.id])
        XCTAssertFalse(first === second)
        try await finished(first); try await finished(second)
        XCTAssertEqual(first.result?.colors.count, 2)
        XCTAssertEqual(first.result?.colors.first?.fraction ?? 0, 0.5, accuracy: 0.005)
        let secondResult = try XCTUnwrap(second.result)
        app.openReference(.clip(a.id))
        XCTAssertTrue(app.referencePalettes[a.id] === first, "Focusing an existing pin must reuse its palette")
        first.limit = 6; first.mergeDistance = 0.16; first.reanalyze()
        try await finished(first)
        first.saveDefaults()
        XCTAssertEqual(second.limit, 3, "Saving a default must not change another open pin")
        XCTAssertEqual(second.result?.colors, secondResult.colors)
        XCTAssertFalse(second.usesSavedDefaults)
        second.restoreDefaults()
        try await finished(second)
        XCTAssertEqual(second.limit, 6)
        XCTAssertEqual(second.mergeDistance, 0.16)
        XCTAssertTrue(second.usesSavedDefaults)
        app.paletteSettings.restoreDefaults()
        app.paletteSettings.limit = 4; app.paletteSettings.saveDefaults()
        app.openReference(.clip(c.id))
        let third = try XCTUnwrap(app.referencePalettes[c.id])
        try await finished(third)
        XCTAssertEqual(third.limit, 4)
        XCTAssertEqual(first.limit, 6)
        XCTAssertEqual(try Data(contentsOf: store.url(for: a)), bytes)
        XCTAssertEqual(app.clipPasteboardItem(a)?.data(forType: .png), bytes, "Image copying must still export the original PNG")

        let pin = try XCTUnwrap(app.referenceWindows[.clip(a.id)])
        first.settingsPresented = true
        try await Task.sleep(for: .milliseconds(80))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: pin.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        XCTAssertTrue(pin.performKeyEquivalent(with: escape))
        XCTAssertFalse(first.settingsPresented)
        XCTAssertTrue(app.referenceWindows[.clip(a.id)] === pin, "Escape dismisses analysis settings before closing the pin")

        if let destination = ProcessInfo.processInfo.environment["SNIPSHELF_RENDER_QA"] {
            let directory = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let panel = try XCTUnwrap(app.referenceWindows[.clip(a.id)])
            for (appearance, suffix): (NSAppearance.Name, String) in [(.aqua, "light"), (.darkAqua, "dark")] {
                panel.appearance = NSAppearance(named: appearance); panel.setContentSize(CGSize(width: 220, height: 240))
                try await Task.sleep(for: .milliseconds(100))
                let view = try XCTUnwrap(panel.contentView)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                XCTAssertEqual(view.bounds.width, 220, accuracy: 1)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("pin-palette-" + suffix + ".png"))
            }
        }
        let name = first.result?.name
        first.analyze(name: "Pending") { Thread.sleep(forTimeInterval: 0.15); return original }
        app.closeReference(.clip(a.id))
        XCTAssertNil(app.referencePalettes[a.id])
        XCTAssertFalse(first.busy)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(first.result?.name, name, "A closed pin must discard pending results")
        XCTAssertNil(app.referenceWindows[.clip(a.id)])
    }
}
