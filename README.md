# SnipShelf

**Keep the part you love.** A native macOS shelf for freehand cutouts and visual references.

Draw around part of an image, review the transparent cutout, and keep it nearby to copy or drag into your work. Built with SwiftUI, AppKit, ScreenCaptureKit, and Apple Vision. All processing and storage stay on your Mac; no third-party dependencies or account required.

**Version 0.1.1** · [Release notes](docs/releases/0.1.1.md)

![Review a selection before keeping it](docs/review.jpg)

## Features

- Freehand lasso with adaptive stabilization and gentle edge assistance that yields to your gesture.
- Default-on native subject masks in review, with an instant switch back to the original cutout.
- Polygon selection, zoom and pan, compact cutout confirmation, refinement undo, and Redraw / Refine / Keep Clip controls.
- A floating shelf that tucks against the screen edge, with multi-selection, a resizable image preview, clipboard support, and deletion undo.
- PNG cutouts with transparency, stored locally and available to other apps through copy and drag.

Requires **macOS 26+**. Local builds have been tested on Apple Silicon. The app lives in the menu bar, with **Command–Shift–2** as the default capture shortcut. Screen capture requires macOS screen-recording permission; image import and recropping do not.

See the [usage guide](docs/usage.md) for shortcuts, selection behavior, and data recovery, and [validation notes](docs/validation.md) for test coverage and current limitations.

## Build and test

Install Xcode with the macOS 26 SDK or later. Run these commands from the repository root:

```sh
./scripts/build_and_run.sh          # build, sign, and launch
./scripts/build_and_run.sh --build  # create dist/SnipShelf.app
./scripts/build_and_run.sh --release # create the arm64 release ZIP and SHA-256
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The script also accepts `--verify`, `--logs`, and `--debug`. Set `DEVELOPER_DIR` to use another Xcode installation; the script does not change global `xcode-select`. Builds use local ad-hoc signing and are not notarized.

### Snip Lab

Use the separate **Snip Lab** app to tune selection feel without screen-recording
permission. It uses the same native canvas, lasso, polygon, edge assistance and
crop code as SnipShelf. Start with the built-in practice board or open your own
image; change steadiness and edge help, compare Raw with App Defaults, then
redraw or refine repeatedly. Review removes the subject's background within your
selection using Apple Vision; turn off **Subject mask** to restore the original cutout. Return starts
the next try; Escape redraws.
Settings are saved separately and trial cutouts stay in memory.

Lab starts in **Fluid** drawing mode. Switch **Drawing feel** between Classic and
Fluid to compare on the same image, and use Steadiness to tune either mode.
Fluid adjusts smoothing by elapsed time and pointer speed, lands at the release
position, and lights the start ring when releasing will close the lasso. Hold
Option to bypass closing help. These drawing changes are being tested in Lab;
the main app still uses Classic.

```sh
./scripts/build_and_run.sh --lab        # build once; thereafter open the existing lab
./scripts/build_and_run.sh --lab-build  # rebuild the lab after changing Swift code
```

You can also open `dist/SnipLab.app` directly, or use the **Snip Lab** development
action. Changing the controls, loading images and repeating trials need no build.
Swift code changes still require `--lab-build`; neither lab command rebuilds or
relaunches the regular app.

Release packaging uses an optimized Apple Silicon build, maps source paths,
strips debug symbols, and bundles the MIT license. It checks the extracted ZIP's
signature, architecture, version, contents, and common private build paths before
writing `dist/SnipShelf-0.1.1-arm64.zip.sha256`. To repeat the checks:

```sh
python3 scripts/check_release.py dist/SnipShelf-0.1.1-arm64.zip
(cd dist && shasum -a 256 -c SnipShelf-0.1.1-arm64.zip.sha256)
```

Ad-hoc signing uses no developer certificate or Team ID. Downloads are **not
notarized** and require the first-launch steps in the [usage guide](docs/usage.md).
The scan is a packaging safeguard, not a guarantee of anonymity.

For isolated manual QA, close the normal app and launch with separate storage and preferences:

```sh
open -n dist/SnipShelf.app --args --qa-directory "$PWD/.local/qa/storage"
```

The approved sticker icon is stored in `Assets/AppIcon.png`: a 1024 × 1024 sRGB
PNG with transparent outer padding. `Assets/AppIcon.icns` contains the ten standard
and Retina representations (16–1024 pixels) used by the app bundle. This is a
flattened macOS icon; its baked lighting is not a layered Liquid Glass asset.

To regenerate and validate the icon:

```sh
mkdir -p .build/AppIcon.iconset
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/make_icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o Assets/AppIcon.icns
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/check_icon.swift
./scripts/build_and_run.sh --build
```

The check decodes the packaged icon and verifies its pixel sizes, transparent
corners, and ivory sticker, catching incomplete or stale exports. The menu-bar
icon uses a separate 18-point vector template of the same sticker and peeled
corner, drawn in `AppController.menuBarIcon()`. AppKit supplies its color for the
current background and selection state; no extra raster assets are required.

For a future Icon Composer version, prepare full-bleed, unmasked artwork and let
the system apply the corners; do not import this padded `.icns` master as a
full-bleed background. See Apple's [app icon guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons)
and [iconset packaging reference](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html).

## Repository layout

```text
Package.swift       SwiftPM package
Sources/SnipShelf/  Application code
Tests/SnipShelfTests/
Assets/             App icon
scripts/            Build, run, and icon tools
docs/               Usage, validation, and screenshots
.codex/             Local development action
dist/SnipShelf.app  Latest local app (rebuilt in place, ignored)
.local/archives/    Compressed older apps (ignored)
```

`.build/`, `dist/`, and `.local/` are ignored. They hold build caches, packaged apps, and local QA/archive material. Normal user clips live in `~/Library/Application Support/SnipShelf/`, outside this repository.

## License

[MIT](LICENSE).
