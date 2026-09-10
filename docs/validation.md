# Validation

Last checked: 2026-09-10. Host: Apple Silicon, macOS 27.0 (26A428). Builds use the locally installed Xcode and macOS SDK. Deployment target: macOS 26. Local app bundles are ad-hoc signed, not notarized.

## Automated checks

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build_and_run.sh --build
codesign --verify --strict dist/SnipShelf.app
```

The suite contains **33 behavioral tests** plus one optional interface-rendering check covering:

| Area | Coverage |
| --- | --- |
| Freehand assistance | Light stabilization, bounded edge nudges at multiple scales, crossing edges, ambiguous/dense regions, sharp turns, Option bypass, and late Vision results. Each drag adds at most one point; review output matches the displayed path. |
| Polygon assistance | Local contour selection, release distance, alternate candidates, and pixel fallback on thin borders. |
| Selection review | Continue from the middle of an existing segment, Redraw/Refine/Keep Clip transitions, one-step refinement undo restoring outline and PNG pixels, and exactly-once confirmation. |
| Image processing | Coordinate mapping, orientation, concave and self-intersecting selections, invalid input, transparency, anti-aliasing, and PNG round-trips. |
| Local storage | New-clip selection and failed-save selection preservation, persistence, deletion/undo, batch deletion with newer clips, missing assets, failed writes, corrupt index recovery, and 100 mixed-size clips. |
| Drag import | Internal drags are rejected without writes; independent external PNG drops still import. |
| Menu icon | Template rendering at 1× and 2×, transparent padding, opaque sticker, and a transparent peeled-corner crease. |
| Compact capture review | Actual canvas events open a small floating preview and hide the editor; Refine preserves the outline, zoom and pan; undo restores the cutout; Return saves once; Escape and window-close cancel. Placement stays on screen for corner selections. Screen capture and recropping share this path. |
| AppKit interaction | Canvas mouse event flows, actual-size scaling, shelf move/dock state, continuous inward pulls from both edges, preview navigation/closing, native preview Fit/100%, background-picker insets after repeated zoom resets and resizing, and clear thumbnail backgrounds. |

Freehand tests bound filter lag to one screen point and edge correction to 1.1 screen points. The tested combined trace stays within 2.1 points of the pointer. These are synthetic behavior checks, not proof of subjective smoothness on arbitrary artwork or devices.

## Release packaging

```sh
./scripts/build_and_run.sh --release
python3 scripts/check_release.py dist/SnipShelf-0.1.1-arm64.zip
(cd dist && shasum -a 256 -c SnipShelf-0.1.1-arm64.zip.sha256)
```

The check verifies the exact bundled file list, version 0.1.1/build 2, arm64
architecture, and the ad-hoc signature after extraction. It rejects common
local-user/build paths and private-key markers in bundled files. Only the app
executable, plist, icon, MIT license, and signature resources are distributed;
debug symbols, extended attributes, and provisioning profiles are excluded.
This targeted scan does not establish complete anonymity. The downloaded-app
Gatekeeper flow still needs a manual check on another Mac.

## Interface rendering

To render the shelf, settings, selection comparison and preview with synthetic artwork:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SNIPSHELF_RENDER_QA="$PWD/.local/ux-qa" swift test --filter InteractionTests/testRenderInterfaceWhenRequested
```

The September 10 render checks cover light and dark content layouts. AppKit cached-view PNGs do **not** capture compositor-backed Liquid Glass and vibrant controls faithfully, so they are not final appearance screenshots. The direct Computer Use plugin successfully inspected the running app and dragged the capture toolbar in Crop a Copy: a 100-point horizontal, 140-point vertical drag moved the toolbar by that amount. Its gesture now uses the fixed canvas coordinate space. The full screen-capture flow was blocked by macOS screen-recording permission; arbitrary canvas clicks also encountered the plugin's `windowNotFoundAtPosition` error. Compact-preview lifecycle checks use native AppKit tests, and trackpad feel still needs manual verification.

## Previous manual checks

Earlier local QA sessions verified image import, selection review and confirmation, recropping, multi-selection deletion/undo, shelf docking, preview, and clipboard exchange with Preview. The clipboard round-trip preserved PNG bytes. Those sessions used isolated QA storage and synthetic artwork; they are not a new manual test of every build.

## Remaining manual checks and limits

- Physical mouse/trackpad feel on complex artwork, low-contrast edges, and dense textures.
- The complete screen-recording permission and real screen-capture flow, including scale and window exclusion.
- Physical drag/drop into Figma and Finder, and hover-open during an external drag. Clipboard checks do not establish drag/drop interoperability.
- Global shortcut activation from other apps and shortcut conflict recovery.
- Mixed-density displays, display removal, Dock relocation, and fullscreen Spaces.
- Light appearance, Reduce Transparency, Reduce Motion, and spoken VoiceOver navigation.
- HEIC/WebP sample files, macOS 26 runtime, and Intel hardware. Current local runtime tests use macOS 27 on Apple Silicon.
- Developer ID signing, notarization, and the downloaded-app Gatekeeper flow.

Freehand remains manual selection with conservative assistance, not semantic object segmentation. Very large images can briefly block during encoding or disk writes. Undo history lasts for the app session; see the [usage guide](usage.md) for storage and recovery behavior.
