# Developing SnipShelf

[Back to SnipShelf](../README.md) · [Usage guide](usage.md) · [Validation notes](validation.md)

## Build and test

Install Xcode with the macOS 26 SDK or later. Run these commands from the repository root:

```sh
./scripts/build_and_run.sh          # build, sign, and launch
./scripts/build_and_run.sh --build  # create dist/SnipShelf.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The script also accepts `--verify`, `--logs`, and `--debug`. Set `DEVELOPER_DIR` to use another Xcode installation; the script does not change global `xcode-select`. Builds use local ad-hoc signing and are not notarized.

## Palette Lab

Run `./scripts/palette_lab.sh` to build and open **Palette Lab**, a separate
experimental app for image palettes. Open, paste, or drop an image; its color
strip sits directly below it, with widths based on the estimated visible-color
proportions. Click a swatch to copy its HEX. **Pin** opens a floating snapshot
that keeps its own image and palette while you try another image.

**Subject Only** is the initial default: background areas are excluded, and the
preview shows the detected subject. White subject details still count. Switch to
**Whole Image** to include backgrounds or analyze images without a clear subject.
If recognition fails, the Lab shows a message instead of a misleading palette.

Start with **Examples**, or expand **Analysis Settings** to compare the color
limit and how strongly similar shades merge. Small, distinct accents compete
for a palette slot; transparent space is excluded. Single-color images stay
single-color. Proportions are measured rather than forced to 60/30/10.

Use **Save as Default** in Analysis Settings to remember the current color
source, color limit, and merge strength for future launches. Temporary changes
stay in the current session; **Restore Default** returns to your saved settings
and updates the current palette. Existing pins keep their own results.

Palette Lab has its own executable and bundle identifier. Images and pins stay
in memory; analysis defaults use the Lab's own preferences. The Lab does not
read or write the SnipShelf library or preferences. Both apps share the analysis,
color strip, and settings components. SnipShelf imports a saved Lab default once
if it has no palette default yet. Build only:
`./scripts/palette_lab.sh --build`. Run its checks with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaletteLabTests`.

## Snip Lab

Use the separate **Snip Lab** app to tune selection feel without screen-recording
permission. It uses the same native canvas, lasso, polygon, edge assistance and
crop code as SnipShelf. Start with the built-in practice board or open your own
image; change steadiness and edge help, compare Raw with App Defaults, then
redraw or refine repeatedly. Review removes the subject's background within your
selection using Apple Vision; turn off **Remove Background** to restore the original cutout. Return starts
the next try; Escape redraws.
Settings are saved separately and trial cutouts stay in memory.

Both the main app and Lab start in **Fluid** drawing mode. Switch **Drawing feel** between Classic and
Fluid to compare on the same image, and use Steadiness to tune either mode.
Fluid adjusts smoothing by elapsed time and pointer speed, lands at the release
position, and lights the start ring when releasing will close the lasso. Hold
Option to bypass closing help. In the main app, Drawing feel is in the wand menu.

The main app’s resizable **Capture Preview** includes **Restore** and **Erase**
brushes directly, using the same brush engine as Lab. Restore
brings back original pixels inside the lasso; Erase removes unwanted areas.
Zoom in for detail, adjust brush size in source pixels (or use `[` / `]`), and
hold Space while dragging to pan. Command–Z undoes a whole stroke;
Command–Shift–Z redoes it. **View** or Escape leaves the brush without clearing
the selection. Switching Remove Background off and back on preserves your touch-ups.
In Capture Preview, **R / E / V** select Restore / Erase / View; **Command–Plus / Minus**
zoom, **Command–0** fits, and **Command–1** shows actual pixels. Shortcuts also work
after clicking the brush slider or preview controls; Undo and Redo have visible buttons.
In **Original** view, **Show removed areas** is on by default: cyan stripes mark
pixels removed inside your lasso, including brush edits, while kept pixels retain
their original colors. Toggle it off for an unobstructed comparison. This guide
never appears in Cutout or the saved PNG.
Only **Refine Outline** and **Redraw** return to the original selection canvas.
Refine computes a new mask; its undo restores the previous outline and touch-ups
together. Preview zoom and pan are independent of the source canvas, and the
floating window retains its size and position when returning from refinement.

```sh
./scripts/build_and_run.sh --lab        # build once; thereafter open the existing lab
./scripts/build_and_run.sh --lab-build  # rebuild the lab after changing Swift code
```

You can also open `dist/SnipLab.app` directly, or use the **Snip Lab** development
action. Changing the controls, loading images and repeating trials need no build.
Swift code changes still require `--lab-build`; neither lab command rebuilds or
relaunches the regular app.

## Release packaging

Official releases are built on GitHub. Update the version and build number in
`scripts/build_and_run.sh` and `scripts/check_release.py`, add the matching notes
under `docs/releases/`, and commit and push to `main`. Then run the
[Release workflow](../.github/workflows/release.yml) from Actions, or use:

```sh
gh workflow run release.yml --ref main
```

The workflow runs `swift test` on macOS 26, builds the Apple Silicon ZIP, and
verifies the package and SHA-256. It uploads the ZIP and checksum to a draft
release, then publishes it with a version tag pointing to the tested commit.
Release builds and their temporary files stay on the GitHub runner.

Packaging reuses `scripts/build_and_run.sh --release`: an optimized build with
mapped source paths, stripped debug symbols, and the MIT license. It checks the
extracted ZIP's signature, architecture, version, contents, and common private
build paths before writing the checksum. To reproduce a release locally:

```sh
./scripts/build_and_run.sh --release
python3 scripts/check_release.py dist/SnipShelf-0.3.0-arm64.zip
(cd dist && shasum -a 256 -c SnipShelf-0.3.0-arm64.zip.sha256)
```

Ad-hoc signing uses no developer certificate or Team ID. Downloads are **not
notarized** and require the first-launch steps in the [usage guide](usage.md).
The scan is a packaging safeguard, not a guarantee of anonymity.

## Isolated manual QA

For isolated manual QA, close the normal app and launch with separate storage and preferences:

```sh
open -n dist/SnipShelf.app --args --qa-directory "$PWD/.local/qa/storage"
```

## HTML interface previews

Open `docs/demo.html` directly in a browser. It contains four interface scenes,
embedded sample PNGs, and native symbol images, with no web dependencies.
Desktop windows follow the source sizes: a 340-point Shelf, a 440-point capture
review, 340-point references, and a 330-point analysis popover. CSS reproduces
the native materials; this is a UI recreation, not a screenshot of the Mac app.

Sample interactions are held in memory. Actual capture, mask painting, and
palette analysis remain in the Mac app. The scene links are `#shelf`, `#capture`,
`#references`, and `#palette`. Add `?theme=dark` for dark appearance.

To check the sample workflow, open `docs/demo.html?check` in a browser. Its
built-in checks cover group navigation, search, pinning, capture review states,
save destinations, undo, palette defaults, clipboard success/failure, and
appearance. Results appear at the end of the page and in `window.demoCheck`.

For README images, open `docs/demo.html?export#shelf` (or another scene) at
1120 × 700 CSS pixels with a 2× pixel ratio. Export hides the surrounding site
navigation. Save each image as lossless WebP under `docs/screenshots/`.

## App icon

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
Package.swift        SwiftPM package
Sources/SnipShelf/    Application code
Sources/PaletteKit/   Shared palette analysis and controls
Sources/PaletteLab/   Experimental palette app
Tests/               App and palette checks
Assets/              App icon
scripts/             Build, run, and icon tools
docs/                Usage, development, validation, and screenshots
.github/workflows/   GitHub release build and publication
.codex/              Local development action
dist/SnipShelf.app    Latest local app (rebuilt in place, ignored)
.local/              Generated QA output (ignored)
```

`.build/`, `dist/`, and `.local/` are generated as needed and ignored. They hold build caches, packaged apps, and local QA output. Keep disposable layout studies and historical build/QA archives outside the checkout. Normal user clips live in `~/Library/Application Support/SnipShelf/`, outside this repository.
