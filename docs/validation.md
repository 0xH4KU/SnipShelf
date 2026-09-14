# Validation

Last automated check: 2026-09-14. Host: Apple Silicon, macOS 27.0 (26A428). Builds use the locally installed Xcode and macOS SDK. Deployment target: macOS 26. Local app bundles are ad-hoc signed, not notarized. Manual evidence is dated below.

## Automated checks

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build_and_run.sh --build
codesign --verify --strict dist/SnipShelf.app
```

The suite contains **45 behavioral tests** plus one optional interface-rendering check covering:

| Area | Coverage |
| --- | --- |
| Freehand assistance | Stronger adaptive stabilization, bounded edge nudges at multiple scales, crossing edges, ambiguous/dense regions, sharp turns, Option bypass, and late Vision results. Each drag adds at most one point; review output matches the displayed path. |
| Subject mask | Instance selection follows the lasso in top-left image coordinates and excludes background labels. Alpha application preserves white subject interiors, source colors, existing transparency, soft alpha, holes and concave selection bounds; mismatched mask dimensions are rejected. Blank-image fallback and existing opt-out preferences are covered. |
| Review lifecycle | Default-on subject masking can be toggled back to exact original PNG pixels, including after refinement undo. The editable lasso and crop registration survive masking. Pending work cannot save an unseen result or resurrect a reset/confirmed selection. Lifecycle checks use a fixed mask independently of Vision's versioned recognition model. |
| Polygon assistance | Local contour selection, release distance, alternate candidates, and pixel fallback on thin borders. |
| Selection review | Continue from the middle of an existing segment, Redraw/Refine/Keep Clip transitions, one-step refinement undo restoring outline and PNG pixels, and exactly-once confirmation. |
| Snip Lab | Classic/Fluid comparison with settings retained across images, repeated strokes on the real canvas, in-window review matching exported crop pixels, Refine/Undo, Next Try and Escape resetting the same source, and unreadable files preserving the current trial. |
| Fluid drawing experiment | Timestamp-based smoothing at 60, 120, 240 and 1000 Hz, scale equivalence, immediate start, bounded lag, deliberate fast sweeps, and stale-velocity reset after pauses. Native canvas events cover the closing cue, 9-screen-point closing reach at different zoom levels, Option bypass, exact release endpoints, and refinement/export consistency. Enabled by default in Lab; the main app remains on Classic. |
| Manual mask touch-up in Lab | Restore/Erase connect sparse pointer events and preserve source colors, partial alpha, transparency and the lasso boundary. Whole-stroke undo/redo, toggle preservation, cancelled strokes, pending-recognition guards, empty-result rollback, refinement undo and exact saved pixels are covered. Native canvas events verify brush registration in Original/Cutout at different zooms, Space-drag panning without painting, Escape leaving the brush, and keyboard undo/redo. |
| Removed-area guide in Lab | Native renders verify visible cyan hatching on a red background, correct crop/zoom registration, no markings on retained pixels or outside the lasso, and immediate brush updates. Alpha-loss checks distinguish removed pixels from original transparency and soft alpha. Cutout rendering and saved PNGs stay unchanged; the guide preference survives opening another image. |
| Image processing | Coordinate mapping, orientation, concave and self-intersecting selections, invalid input, transparency, anti-aliasing, and PNG round-trips. |
| Local storage | New-clip selection and failed-save selection preservation, persistence, deletion/undo, batch deletion with newer clips, missing assets, failed writes, corrupt index recovery, and 100 mixed-size clips. |
| Drag import | Internal drags are rejected without writes; independent external PNG drops still import. |
| Menu icon | Template rendering at 1× and 2×, transparent padding, opaque sticker, and a transparent peeled-corner crease. |
| Compact capture review | Actual canvas events open a small floating preview and hide the editor; Refine preserves the outline, zoom and pan; undo restores the cutout; Return saves once; Escape and window-close cancel. Placement stays on screen for corner selections. Screen capture and recropping share this path. |
| AppKit interaction | Canvas mouse event flows, actual-size scaling, shelf move/dock state, continuous inward pulls from both edges, preview navigation/closing, native preview Fit/100%, background-picker insets after repeated zoom resets and resizing, and clear thumbnail backgrounds. |

At the default 55% steadiness, freehand tests bound filter lag to 1.8 screen points and edge correction to 1.1 screen points. The tested combined trace stays within 2.9 points of the pointer. On the alternating-jitter fixture, filtered vertical variation is below 8% of the input while deliberate fast motion follows immediately. These are synthetic behavior checks, not proof of subjective smoothness on arbitrary artwork or devices.

The Lab-only Fluid experiment uses elapsed time and filtered pointer velocity
to adapt a low-pass filter, following the approach described in the
[1€ filter research](https://gery.casiez.net/1euro/), with an explicit lag ceiling
and a faster response for deliberate sweeps. On the 40-point/second trace with
0.9-point, 18-Hz jitter, output RMS stays below 0.2 points at all four tested
event rates, and mean lag differs by less than 0.4 points between rates. The
start ring highlights within 9 screen points after a sufficient stroke span;
closing help only changes the endpoint on release. Physical mouse/trackpad
comparison is still needed before promoting this mode to the main app.

On September 14, the faint ellipse was reproduced from the exact practice-board
pixels with a reconstructed rough lasso. Full-image Vision detection missed it,
including stronger contrast settings. A local pass with 4× contrast and an
automatic intensity pivot recovered it, as did OpenCV 5.0.0 GrabCut using the same
lasso. This is one synthetic comparison, not a photo-segmentation benchmark.
That local contour retry was subsequently replaced by subject masking after the
real-image comparison below. OpenCV was used in an isolated experiment and is
not an app dependency.

Six fixed selections (whole subject and head on each of three supplied images)
were then compared using the actual app review pipeline, OpenCV GrabCut, and
Apple's native `VNGenerateForegroundInstanceMaskRequest`. All processing stayed
local. GrabCut used the same canonical source pixels, five iterations, a fixed
random seed, probable foreground inside the lasso and definite background
outside, with a 1536-pixel analysis cap and no corrective strokes. The native
foreground experiment selected the instance overlapping the lasso most, then
clipped its alpha to that lasso.

| Supplied material | Previous contour correction | GrabCut experiment | Native foreground mask |
| --- | --- | --- | --- |
| Person on a pale background | Whole selection stayed manual; head correction lost the white bonnet and some hair. | Whole figure mostly retained; head selection lost the bonnet. | Retained the bonnet, hair and white clothing more completely. |
| Gray line art on white | Whole correction cut away parts of the hair and clothing; head stayed manual. | Removed much of the interior white; head output was empty. | Retained the white face, body and clothing interiors. |
| Colored figure over other characters | Previously collapsed to a leg patch; the new span check retains the original whole selection. Head correction still loses dark details. | Lost black clothing, accessories and some skin regions. | Retained the foreground figure more completely, but included parts of background characters. |

These are visible-error comparisons without hand-labeled ground-truth masks,
not accuracy scores or physical pointer tests. Subject masking is now the sole
review-correction backend in SnipShelf and Snip Lab; the contour matcher and its
span/contrast heuristics were removed. Live drawing assistance still uses edges.
The six supplied selections were rerun through the integrated review and save
pipeline: each produced a mask, toggled back to the exact original crop, restored
the same masked PNG on re-enabling, and saved the displayed bytes. Native canvas
renders verified Original highlighting and Cutout transparency on the line art.
Masks are applied to source alpha without recoloring or replacing the editable
lasso. The comparison and integrated outputs are kept under ignored
`.local/vision-comparison/real/` and `.local/subject-mask/`; supplied images are
not committed as test fixtures.

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

On September 12, Snip Lab passed native canvas event tests and launched as a
separate foreground app. Reopening with `--lab` preserved both app binaries and
the existing Snip Lab and SnipShelf processes. The Computer Use plugin's direct
MCP entrypoint returned `Sender process is not authenticated`, so a live pointer
check was not completed in this session.

On September 14, the three supplied whole-subject selections were also tested
with Lab's manual brushes after native subject masking. Erasing, restoring,
whole-stroke undo/redo and toggle preservation passed on the photo, line art and
illustration. A cached native Lab render checked the review inspector layout;
outputs are under ignored `.local/mask-touchup/`. These checks exercise editing
and pixel preservation, not segmentation accuracy or physical pointer feel.
The rebuilt Lab launched successfully. A fresh direct Computer Use request for
its app state timed out, so live pointer QA remains unverified.

The removed-area guide was rendered on the supplied red-background artwork
using its local source file and a reconstructed coarse lasso. The guide compares
original and current alpha with [Core Image filters](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/subtractblendmode%28%29),
then draws cyan hatching in canvas coordinates; it never modifies export pixels.
On that roughly 356k-pixel selection, 30 brush updates plus native-view refreshes
took 62 ms in a debug build, compared with 793 ms for the initial scalar loop.
This measures that update path, not end-to-end frame timing or physical mouse
latency. Native renders and the probe are under ignored `.local/removed-overlay/`.

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

Vision subject masking can include background people when they are recognized as part of the same foreground instance, or miss detail on ambiguous artwork and simple geometric shapes. It selects one instance with the most overlap and stays inside the lasso. Refine changes that lasso; Lab additionally exposes manual Restore/Erase brushes in review. These brushes cannot restore pixels outside the lasso. Brush undo retains at most 20 source-resolution snapshots, reduced toward a 64 MiB budget for large cutouts (at least one undo remains available); very large selections may still need tiled rendering for responsive painting. The review toggle restores the original selection and retains touch-ups for re-enabling. Very large images can briefly block during encoding or disk writes. Undo history lasts for the app session; see the [usage guide](usage.md) for storage and recovery behavior.
