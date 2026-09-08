# SnipShelf

**Keep the part you love.** A native macOS shelf for freehand cutouts and visual references.

Draw around part of an image, review the transparent cutout, and keep it nearby to copy or drag into your work. Built with SwiftUI, AppKit, ScreenCaptureKit, and Apple Vision. All processing and storage stay on your Mac; no third-party dependencies or account required.

![Review a selection before keeping it](docs/review.jpg)

## Features

- Freehand lasso with light stabilization and gentle edge assistance that yields to your gesture.
- Polygon selection, zoom and pan, and Delete / Continue / Confirm review controls.
- A floating shelf that tucks against the screen edge, with multi-selection, preview, clipboard support, and deletion undo.
- PNG cutouts with transparency, stored locally and available to other apps through copy and drag.

Requires **macOS 26+**. Local builds have been tested on Apple Silicon. The app lives in the menu bar, with **Command–Shift–2** as the default capture shortcut. Screen capture requires macOS screen-recording permission; image import and recropping do not.

See the [usage guide](docs/usage.md) for shortcuts, selection behavior, and data recovery, and [validation notes](docs/validation.md) for test coverage and current limitations.

## Build and test

Install Xcode with the macOS 26 SDK or later. Run these commands from the repository root:

```sh
./scripts/build_and_run.sh          # build, sign, and launch
./scripts/build_and_run.sh --build  # create dist/SnipShelf.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The script also accepts `--verify`, `--logs`, and `--debug`. Set `DEVELOPER_DIR` to use another Xcode installation; the script does not change global `xcode-select`. Builds use local ad-hoc signing and are not notarized.

For isolated manual QA, close the normal app and launch with separate storage and preferences:

```sh
open -n dist/SnipShelf.app --args --qa-directory "$PWD/.local/qa/storage"
```

To regenerate the icon:

```sh
mkdir -p .build/AppIcon.iconset
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/make_icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o Assets/AppIcon.icns
```

## Repository layout

```text
Package.swift       SwiftPM package
Sources/SnipShelf/  Application code
Tests/SnipShelfTests/
Assets/             App icon
scripts/            Build, run, and icon tools
docs/               Usage, validation, and screenshots
.codex/             Local development action
```

`.build/`, `dist/`, and `.local/` are ignored. They hold build caches, packaged apps, and local QA/archive material. Normal user clips live in `~/Library/Application Support/SnipShelf/`, outside this repository.

## License

[MIT](LICENSE).
