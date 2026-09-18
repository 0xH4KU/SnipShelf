import XCTest
import AppKit
import SwiftUI
@testable import PaletteLab
@testable import PaletteKit

final class PaletteLabTests: XCTestCase {
    private func image(_ stripes: [(Int, CGColor)], width: Int = 200, height: Int = 100) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: PaletteAnalysis.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        var x = 0
        for (span, color) in stripes {
            context.setFillColor(color); context.fill(CGRect(x: x, y: 0, width: span, height: height)); x += span
        }
        return try XCTUnwrap(context.makeImage())
    }
    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    func testMergingProportionsAndDistinctSmallAccent() throws {
        let source = try image([(80, color(0.92, 0.89, 0.83)), (55, color(0.94, 0.91, 0.85)),
                                (60, color(0.15, 0.4, 0.3)), (5, color(0.95, 0.3, 0.05))])
        let colors = try PaletteAnalysis.colors(in: source)
        XCTAssertEqual(colors.count, 3)
        XCTAssertEqual(colors.reduce(0) { $0 + $1.fraction }, 1, accuracy: 0.00001)
        for (swatch, expected) in zip(colors, [0.675, 0.3, 0.025]) { XCTAssertEqual(swatch.fraction, expected, accuracy: 0.002) }
        XCTAssertEqual(colors[1].rgb.x, 0.15, accuracy: 0.008)
        XCTAssertEqual(colors[1].rgb.y, 0.4, accuracy: 0.008)
        XCTAssertEqual(colors[2].rgb.x, 0.95, accuracy: 0.008)
        XCTAssertEqual(colors[2].rgb.y, 0.3, accuracy: 0.008)
        XCTAssertEqual(colors[2].rgb.z, 0.05, accuracy: 0.008)

        let competing = try image([(120, color(0.93, 0.9, 0.84)), (40, color(0.12, 0.4, 0.3)),
                                   (36, color(0.52, 0.52, 0.52)), (4, color(0.96, 0.27, 0.04))])
        let reduced = try PaletteAnalysis.colors(in: competing, limit: 3, mergeDistance: 0.03)
        XCTAssertEqual(reduced.count, 3)
        let accent = try XCTUnwrap(reduced.first { $0.rgb.x > 0.85 && $0.rgb.y < 0.4 })
        XCTAssertEqual(accent.fraction, 0.02, accuracy: 0.002, "A distinct small accent must survive the color limit")
        let expanded = try PaletteAnalysis.colors(in: competing, limit: 6, mergeDistance: 0.03)
        XCTAssertEqual(expanded.count, 4)
    }

    func testTransparencySingleColorAndValidation() throws {
        let source = try image([(100, color(1, 0, 0)), (50, color(0, 0, 1, 0.5))])
        let colors = try PaletteAnalysis.colors(in: source)
        XCTAssertEqual(colors.count, 2, "Transparent space must not become a black or white swatch")
        let red = try XCTUnwrap(colors.first { $0.rgb.x > 0.95 })
        let blue = try XCTUnwrap(colors.first { $0.rgb.z > 0.95 })
        XCTAssertEqual(red.fraction, 0.8, accuracy: 0.005, "Coverage is weighted by opacity")
        XCTAssertEqual(blue.fraction, 0.2, accuracy: 0.005)
        XCTAssertTrue(try PaletteAnalysis.colors(in: image([])).isEmpty)
        let mono = try PaletteAnalysis.colors(in: image([(200, color(0.2, 0.4, 0.6))]))
        XCTAssertEqual(mono.count, 1)
        XCTAssertEqual(mono[0].fraction, 1, accuracy: 0.00001)
        XCTAssertEqual(mono[0].rgb.x, 0.2, accuracy: 0.008)
        XCTAssertEqual(mono[0].rgb.y, 0.4, accuracy: 0.008)
        XCTAssertEqual(mono[0].rgb.z, 0.6, accuracy: 0.008)
        XCTAssertEqual(PaletteSwatch(rgb: SIMD3(0.2, 0.4, 0.6), fraction: 1).hex, "#336699")
        XCTAssertThrowsError(try PaletteAnalysis.colors(in: source, limit: 0))
        XCTAssertThrowsError(try PaletteAnalysis.colors(in: source, mergeDistance: .nan))
        XCTAssertThrowsError(try PaletteAnalysis.load(Data("not an image".utf8)))
    }

    func testSubjectMaskPreservesWhiteAndExistingTransparency() throws {
        let source = try image([(150, color(1, 1, 1)), (50, color(0, 0, 1, 0.5))])
        let mask = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 200, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        mask.setFillColor(gray: 1, alpha: 1); mask.fill(CGRect(x: 100, y: 0, width: 50, height: 100))
        mask.setFillColor(gray: 0.5, alpha: 1); mask.fill(CGRect(x: 150, y: 0, width: 50, height: 100))
        let cutout = try PaletteAnalysis.applying(mask: XCTUnwrap(mask.makeImage()), to: source)
        let colors = try PaletteAnalysis.colors(in: cutout)
        XCTAssertEqual(colors.count, 2)
        let white = try XCTUnwrap(colors.first { $0.hex == "#FFFFFF" })
        let blue = try XCTUnwrap(colors.first { $0.hex == "#0000FF" })
        XCTAssertEqual(white.fraction, 0.8, accuracy: 0.005, "White subject pixels remain; white background pixels do not")
        XCTAssertEqual(blue.fraction, 0.2, accuracy: 0.005, "Mask coverage multiplies the original alpha")
        XCTAssertThrowsError(try PaletteAnalysis.applying(mask: image([], width: 2), to: source))
    }

    @MainActor func testDefaultsPersistOnlyWhenSavedAndValidateStoredValues() throws {
        let suite = "org.snipshelf.tests.palette-defaults." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = PaletteModel(preferences: preferences)
        XCTAssertEqual(model.limit, 3)
        XCTAssertEqual(model.mergeDistance, 0.08)
        XCTAssertTrue(model.subjectOnly)
        XCTAssertTrue(model.usesSavedDefaults)
        model.limit = 6; model.mergeDistance = 0.16; model.subjectOnly = false
        XCTAssertFalse(model.usesSavedDefaults)
        XCTAssertNil(preferences.object(forKey: "analysisDefaults"), "Trials must not overwrite the user's default")
        model.saveDefaults()
        XCTAssertTrue(model.usesSavedDefaults)
        let reopened = PaletteModel(preferences: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.limit, 6)
        XCTAssertEqual(reopened.mergeDistance, 0.16)
        XCTAssertFalse(reopened.subjectOnly)
        reopened.limit = 2; reopened.mergeDistance = 0.03; reopened.subjectOnly = true
        reopened.restoreDefaults()
        XCTAssertEqual(reopened.limit, 6)
        XCTAssertEqual(reopened.mergeDistance, 0.16)
        XCTAssertFalse(reopened.subjectOnly)
        XCTAssertTrue(reopened.usesSavedDefaults)

        preferences.set(["limit": 99, "mergeDistance": Double.nan, "subjectOnly": "invalid"], forKey: "analysisDefaults")
        let invalid = PaletteModel(preferences: preferences)
        XCTAssertEqual(invalid.limit, 3)
        XCTAssertEqual(invalid.mergeDistance, 0.08)
        XCTAssertTrue(invalid.subjectOnly)
    }

    @MainActor func testLatestAnalysisWinsAndPinKeepsItsOwnPalette() async throws {
        _ = NSApplication.shared
        let originalMenu = NSApp.mainMenu
        let suite = "org.snipshelf.tests.palette-window." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = PaletteLabController(preferences: preferences)
        controller.model.subjectOnly = false
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            for window in NSApp.windows where window.title == "Palette Lab" || window.title.hasSuffix("— Palette") { window.close() }
            NSApp.mainMenu = originalMenu
        }
        let model = controller.model
        func finished() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.busy)
        }
        let red = try image([(200, color(1, 0, 0))]), blue = try image([(200, color(0, 0, 1))])
        model.analyze(name: "Slow") { Thread.sleep(forTimeInterval: 0.15); return red }
        model.analyze(name: "Current") { blue }
        try await finished()
        XCTAssertEqual(model.result?.name, "Current")
        controller.pinImage()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Current — Palette" })
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(try XCTUnwrap(panel as? NSPanel).hidesOnDeactivate)
        let hosted = try XCTUnwrap(panel.contentView as? NSHostingView<PaletteImageView>)
        XCTAssertEqual(hosted.rootView.result.colors.first?.hex, "#0000FF")
        model.analyze(name: "Next") { red }
        try await finished()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.result?.name, "Next")
        XCTAssertEqual(hosted.rootView.result.name, "Current")
        XCTAssertEqual(hosted.rootView.result.colors.first?.hex, "#0000FF")
        model.analyze(name: "Unreadable") { throw PaletteError(message: "Could not decode") }
        try await finished()
        XCTAssertEqual(model.result?.name, "Next")
        XCTAssertEqual(model.error, "Could not decode")

        let original = try image([(100, color(1, 1, 1)), (100, color(0, 0, 1))])
        let cutout = try image([(100, color(0, 0, 0, 0)), (100, color(0, 0, 1))])
        model.subjectOnly = true
        model.analyze(name: "Subject", subject: .success(cutout)) { original }
        try await finished()
        XCTAssertEqual(model.result?.colors.map(\.hex), ["#0000FF"])
        XCTAssertTrue(model.result?.preview === cutout)
        model.saveDefaults()
        controller.pinImage()
        let subjectPanel = try XCTUnwrap(NSApp.windows.first { $0.title == "Subject — Palette" })
        let subjectPin = try XCTUnwrap(subjectPanel.contentView as? NSHostingView<PaletteImageView>)
        model.subjectOnly = false
        try await finished()
        XCTAssertEqual(model.result?.colors.count, 2)
        XCTAssertTrue(model.result?.preview === original)
        XCTAssertTrue(subjectPin.rootView.result.preview === cutout)
        model.limit = 6; model.mergeDistance = 0.16
        model.restoreDefaults()
        try await finished()
        XCTAssertEqual(model.limit, 3)
        XCTAssertEqual(model.mergeDistance, 0.08)
        XCTAssertTrue(model.result?.subjectOnly == true)
        XCTAssertEqual(model.result?.colors.map(\.hex), ["#0000FF"])
        XCTAssertTrue(model.result?.preview === cutout, "Tuning and toggling must reuse the recognized subject")

        model.analyze(name: "No subject", subject: .failure(PaletteError(message: "No subject found"))) { red }
        try await finished()
        XCTAssertEqual(model.result?.name, "No subject")
        XCTAssertEqual(model.result?.colors, [], "A failed subject analysis must not display the whole-image palette")
        XCTAssertNotNil(model.error)
        model.subjectOnly = false
        try await finished()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.result?.colors.first?.hex, "#FF0000")
        model.subjectOnly = true
        try await finished()
        XCTAssertEqual(model.result?.colors, [])
        XCTAssertNotNil(model.error, "No-subject results are cached too")
    }
}
