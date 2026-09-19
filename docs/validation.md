# Validation

Last automated check: 2026-09-19. Host: Apple Silicon, macOS 27.0 (26A428). Builds use the locally installed Xcode and macOS SDK. Deployment target: macOS 26. Local app bundles are ad-hoc signed, not notarized. Manual evidence is dated below.

The most recent full-suite run, on September 18, passed all 76 tests. The separate library, capture,
and Palette Lab commit snapshots also compile and pass their focused checks.
Both build scripts pass shell syntax checks. Logs for this verification are
under `.local/commit-sequence/`, including `04-integration.log` for the full suite.

Historical `.local/` logs and fixtures, HTML layout studies, and older packaged
apps were archived outside the checkout during the September 19 cleanup.
Paths in the dated notes below refer to that archive; new QA runs recreate
`.local/` as needed. The rebuildable `.build/` cache was removed, and the running
`dist/SnipShelf.app` was retained.

## September 19 Shelf controls and scrolling

Three focused native collection tests pass, covering hidden Shelf scrollbars
during layout updates, wheel scrolling, selection and scroll restoration across
groups and tucking, grouped previews and drops, and independent floating
reference windows. The Shelf retains native scrolling while hiding only its
scroller view; floating group references keep their existing scrollbar behavior.

The app was rebuilt, signature-verified, and relaunched with the compact toolbar
and standard Capture button. Direct Computer Use plugin checks confirmed that a
24-clip group scrolls in both directions without displaying a scrollbar.

## September 18 preview palettes and compact layout

Preview now shares the pin's color strip, Analysis Settings popover, and bottom
controls. New previews use the pin's 340-point width and aspect-based height,
plus a compact navigation row. Seven focused tests pass, including equal image
space and Fit magnification in Preview and Pin, controls at 280/340/560-point
widths, resizing/reopening, palette changes and cancellation, shared saved
defaults, and the existing pin zoom/pan/export behavior. Logs and light/dark
renders are under `.local/compact-preview/`.

The preview palette integration also preserves original PNG copying and
dismisses Analysis Settings before closing the preview on Escape. Direct
Computer Use on the initial integrated build verified the supplied artwork's
subject color strip, copying `#63BAC9`, and opening its saved analysis settings.
After the compact-layout rebuild, direct Computer Use opened that artwork in
both Preview and Pin and verified matching image size, color strips, and bottom
controls. The signature-verified main app is running the updated layout.

## September 18 preview sizing

The regression reproduced a 449 × 144-point preview window with only 16 points
of image height. The preview's hosting view now leaves window sizing to AppKit,
so loading or clearing the image cannot replace the panel's size constraints.
Four focused preview tests pass, covering initial layout, image switching,
closing and reopening after 100% zoom, preserving a resized window, Fit, and
the background toolbar. The before/after logs are in `.local/preview-sizing/`.

The main app was rebuilt, signature-verified, and relaunched. Direct Computer
Use reproduced the collapsed window before the fix and verified the same
553 × 523-pixel clip opening fully visible in Fit afterward.

## September 18 pinned color palettes

All 74 tests pass, including the five Palette Lab checks and the new main-app
integration check. SnipShelf and Palette Lab now use the same `PaletteKit`
analysis, settings, and color-strip components. Each main-app pin owns its
analysis; saved defaults are shared within the app and persist separately from
the Lab. SnipShelf imports existing Lab defaults only when first initializing
its own palette preferences.

The integration check opens actual reference windows, analyzes original PNGs,
checks independent tuning and reuse when focusing a pin, applies updated saved
defaults across pins and Settings, and checks defaults on newly opened pins.
Closing a pin cancels pending work without publishing a late result. Analysis
preserves source PNG bytes and the image-copy payload. Existing capture, shelf,
zoom, dragging, reference-window, and storage tests also pass. The full log is
`.local/palette-lab/main-integration-tests.log`; compact light/dark reference
renders are in `.local/palette-integration/`.

Direct Computer Use checks in the packaged main app verified the white-haired
illustration's subject proportions, HEX copying into the system clipboard,
the analysis-area preview, Whole Image switching, and Restore Default. The Lab's
saved six-color/0.16/Subject Only default was imported into SnipShelf. Escape
dismisses the settings popover while retaining the pin and its zoom; the seven
affected tests pass after this keyboard fix (`.local/palette-lab/escape-integration-tests.log`).

## September 18 Palette Lab experiment

The independent `PaletteLab` SwiftPM executable and its five focused tests build
and pass. Known-color fixtures check near-color merging, 67.5/30/2.5 proportions,
preservation of a 2% orange accent when reducing four groups to three, centroid
color fidelity, alpha-weighted coverage, fully transparent and single-color
images, and invalid inputs. Native window checks cover cancelled analysis,
latest-result ordering, retaining the previous image on failure, and independent
floating pin snapshots. The subject regression excludes masked white background
while preserving white subject pixels and multiplying existing transparency by
soft mask coverage. Scope switching reuses the recognized subject, pins retain
their own scope, and failed recognition never labels a whole-image palette as a
subject palette. Logs are under `.local/palette-lab/`.

Saved-default checks use isolated preference domains: temporary settings do not
write defaults, all three settings survive a fresh model and preferences
instance, Restore Default reanalyzes the current image using the cached subject,
and invalid stored values fall back to supported settings. The focused run is
`.local/palette-lab/defaults-tests.log`.
Direct Computer Use checks saved Subject Only, six colors, and merge strength
0.16; temporarily switching to Whole Image and pressing Restore Default brought
back the subject palette. Quitting and reopening the packaged Lab retained all
three values and showed Using default. SnipShelf continued running separately.

Direct Computer Use plugin inspection confirmed an imported image, its color
strip, and a floating pin with the strip below the image. The SnipShelf app kept
running separately. Main-app integration is covered above; manual color
overrides remain outside this experiment.

Analysis uses [Core Image KMeans](https://developer.apple.com/documentation/coreimage/cikmeans)
for 16 candidate groups, then [Oklab](https://bottosson.github.io/posts/oklab/)
distance to merge similar colors and favor a distinct accent. Source previews
are limited to 4096 pixels on their longest edge; analysis samples at most 384.
Fractions describe groups of visible colors and account for alpha. Reducing the
color limit assigns omitted groups to their nearest retained color. The accent
heuristic considers candidates with at least 0.5% of visible coverage; tiny
details and semantic importance still need evaluation on varied real images.
Nothing is saved to the main library and no 60/30/10 proportions are imposed.

Subject Only uses a native [Vision foreground instance mask](https://developer.apple.com/documentation/vision/vninstancemaskobservation)
for all detected foreground instances, applying alpha to the original colors.
Whole Image includes opaque backgrounds. Recognition and no-subject results are
cached for the current image while tuning palette settings. On the reported
white-haired illustration, with six colors and merge distance 0.16, the pale
group falls from 70.37% of the whole image to 23.55% of the subject; cyan is
32.93%, blue-gray 30.82%, dark blue-gray 11.66%, and orange 1.04%. The white hair
remains visible. A thin pale fringe remains on some edges, so this is an
estimated subject palette, not a manually verified silhouette. Visual output
and measurements are in `.local/palette-lab/subject-result.png` and
`.local/palette-lab/subject-probe.log`.
Direct Computer Use inspection of the rebuilt Lab confirmed the subject preview,
scope picker, and these color proportions. Scope switching and pinned subject
snapshots passed the native window test; a live click was stopped by the plugin
because the user was interacting with the window.

## September 18 independent capture shortcuts

All 67 checks passed. The shortcut regression also passes with native Carbon hotkey events dispatched through the installed handler: each tool switches an empty canvas, explicit modes override the last-used preference, and unfinished strokes and previews retain their tool and exact pixels. Actual hotkey registrations check internal and external conflicts, preservation of the previous working binding, independent saved preferences, and recording an already assigned combination. Logs are `.local/tool-shortcuts-tests.log` and `.local/tool-shortcuts-targeted.log`.

Direct Computer Use plugin calls verified the settings layout, changing Lasso's binding, the duplicate-shortcut error, and restoring its original binding using isolated QA storage. This path works without `@oai/sky`. Plugin key delivery did not activate the system-wide hotkeys, so physical activation from another app remains a manual check; native event dispatch does not establish that end-to-end behavior.

The follow-up removes the required modifiers. A focused native recorder regression passed for single letters, function keys, Option-only and Shift-only combinations, readable key labels, and modified Escape versus plain Escape cancellation. Direct plugin checks also recorded `L`, `F18`, `⌥L`, and `⇧P` successfully in isolated QA preferences. The focused test log is `.local/flexible-shortcuts-targeted.log`.

## September 18 library and capture update

All 66 checks passed with the optional interface renders enabled. New checks cover cross-group name search, accent-insensitive matching, preview navigation within results, native text-editing shortcut routing, search selection restoration after rename/delete/undo, and imports that do not match the query. The native collection also verifies adaptive column counts.

Storage checks cover persistent Recently Deleted records, original group restoration, organization undo, failed index writes, and permanent deletion without resurrection through old undo history. Backup checks round-trip active and deleted clips, names, groups, and original PNG bytes; replace an existing backup; retain the previous library on restore; accept a version-2 backup; and reject missing images, asset symlinks, nested backup destinations, and future indexes without replacing current data.

Native window tests draw rectangles in both directions, compare exact PNG pixels and opaque corners, reject tiny rectangles, preserve independent background-removal choices, and save two selections from the same source into the chosen group. Reference tests verify actual-size/Fit, Space-drag panning without starting file export, and show/hide behavior.

Light/dark cached renders under `.local/features-ui/` cover compact capture previews with destination controls, the rectangle toolbar at 640 × 420, narrow and wide search results, Recently Deleted, settings, and pinned references. These inspect layout; compositor-backed glass is not faithfully captured. The full log is `.local/features-final-tests.log`.

Computer Use initialized but app inspection returned `Trusted RPC service is not configured: sky`. Physical pointer feel, trackpad pinch, the file-picker backup workflow, and global hotkeys from another app remain manual checks. Screen capture still uses the existing permission path; rectangle and continuous-capture checks use the same native canvas with a local image.

## Automated checks

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build_and_run.sh --build
codesign --verify --strict dist/SnipShelf.app
```

The suite contains **76 tests**, including optional interface-rendering and real-image subject-mask checks, covering:

| Area | Coverage |
| --- | --- |
| Interface polish | Native shortcut-button keyboard activation and cancellation; copy feedback follows the most recently copied image, survives an earlier timer, and expires. Optional renders check compact capture confirmation sizing, selected shelf controls and high-contrast appearances. |
| Shelf organization | Native scroll/selection restoration across empty groups, keyboard selection, and tucking/reopening; stale selections are filtered. Moves, dissolution, group creation, and image rename undo preserve newer imports, group order, and original PNG bytes. Failed undo/rename writes leave records and undo history intact. Native window titles follow renames and undo; cached-view pixels verify independent reference backgrounds after preference changes and reopening. |
| Freehand assistance | Stronger adaptive stabilization, bounded edge nudges at multiple scales, crossing edges, ambiguous/dense regions, sharp turns, Option bypass, and late Vision results. Each drag adds at most one point; review output matches the displayed path. |
| Subject mask | Instance selection follows the lasso in top-left image coordinates and excludes background labels. Alpha application preserves white subject interiors, source colors, existing transparency, soft alpha, holes and concave selection bounds; mismatched mask dimensions are rejected. Blank-image fallback and existing opt-out preferences are covered. |
| Review lifecycle | Default-on subject masking can be toggled back to exact original PNG pixels, including after refinement undo. The editable lasso and crop registration survive masking. Pending work cannot save an unseen result or resurrect a reset/confirmed selection. Lifecycle checks use a fixed mask independently of Vision's versioned recognition model. |
| Polygon assistance | Local contour selection, release distance, alternate candidates, and pixel fallback on thin borders. |
| Selection review | Continue from the middle of an existing segment, Redraw/Refine/Keep Clip transitions, one-step refinement undo restoring outline and PNG pixels, and exactly-once confirmation. |
| Snip Lab | Classic/Fluid comparison with settings retained across images, repeated strokes on the real canvas, in-window review matching exported crop pixels, Refine/Undo, Next Try and Escape resetting the same source, and unreadable files preserving the current trial. |
| Fluid drawing | Timestamp-based smoothing at 60, 120, 240 and 1000 Hz, scale equivalence, immediate start, bounded lag, deliberate fast sweeps, and stale-velocity reset after pauses. Native canvas events cover the closing cue, 9-screen-point closing reach at different zoom levels, Option bypass, exact release endpoints, and refinement/export consistency. Enabled by default in both apps; Classic remains available and preferences persist. |
| Manual mask touch-up | Restore/Erase connect sparse pointer events and preserve source colors, partial alpha, transparency and the lasso boundary. Whole-stroke undo/redo, toggle preservation, cancelled strokes, pending-recognition guards, empty-result rollback, refinement undo and exact saved pixels are covered. Native canvas events verify brush registration in Original/Cutout at different zooms, Space-drag panning without painting, Escape leaving the brush, and keyboard undo/redo. |
| Capture keyboard controls | Native window events with a slider holding focus exercise R/E/V, bracket brush sizing including a Chinese-input character, Command–Plus/Equal/Minus, Fit and actual pixels. Two distinct strokes verify that Command–Z undoes exactly one stroke and Command–Shift–Z restores its exact PNG bytes. Zoom, size, tool changes and undo stay blocked during a stroke. The regression failed on the previous implementation. |
| Removed-area guide | Native renders verify visible cyan hatching on a red background, correct crop/zoom registration, no markings on retained pixels or outside the lasso, and immediate brush updates. Alpha-loss checks distinguish removed pixels from original transparency and soft alpha. Cutout rendering and saved PNGs stay unchanged; the guide preference survives opening another image. |
| Image processing | Coordinate mapping, orientation, concave and self-intersecting selections, invalid input, transparency, anti-aliasing, and PNG round-trips. |
| Local storage | New-clip selection and failed-save selection preservation, persistence, deletion/undo, batch deletion with newer clips, missing assets, failed writes, corrupt index recovery, and 100 mixed-size clips. |
| Reference groups | Version-1 migration, atomic group/membership writes, rename validation, dissolution without image loss, pending-import destinations and deletion undo. Native grid checks cover 0/1/2/3/5/8 clips, uncropped separate previews, +N without a repeated caption count, minimum-width geometry, keyboard and click opening, selection boundaries, export index mapping, and PNG/JPEG drops into the intended group. Moving a newer reference keeps the main image and does not duplicate PNGs. |
| Drag import | Internal drags are rejected without writes; independent external PNG drops still import. |
| Multiple references | Group windows and individual image pins coexist, reuse an existing window for the same target, and keep selection separate from the Shelf. Native checks cover per-window frame restoration, hide/show, pin buttons, keyboard routing, live membership and rename updates, internal drops into populated/empty group windows without duplicate PNGs, and closing stale references after deletion/dissolution. Light/dark renders at compact sizes are available through `SNIPSHELF_RENDER_QA` in the reference-window test. |
| Menu icon | Template rendering at 1× and 2×, transparent padding, opaque sticker, and a transparent peeled-corner crease. |
| Compact capture review | Actual canvas events open a resizable floating preview with its own editable canvas and hide the source. The preview fits the selected bounds; zoom stays anchored under the pointer and never moves the source viewport. Restore/Erase, brush undo/redo, and View-mode panning stay in the preview. Refine preserves the source outline, zoom and pan, and returning reuses the same panel at its resized position. Toggling the mask retains edits, refinement undo restores edited pixels, and Return saves those exact PNG bytes once; Escape leaves a brush before cancelling, and window-close cancels. Placement stays on screen for corner selections. Screen capture and recropping share this path. |
| AppKit interaction | Canvas mouse event flows, actual-size scaling, shelf move/dock state, continuous inward pulls from both edges, one-third docking thresholds at 300/450/600-point shelf widths (including retreat to cancel), preview navigation/closing, native preview Fit/100%, background-picker insets after repeated zoom resets and resizing, and clear thumbnail backgrounds. |

At the default 55% steadiness, freehand tests bound filter lag to 1.8 screen points and edge correction to 1.1 screen points. The tested combined trace stays within 2.9 points of the pointer. On the alternating-jitter fixture, filtered vertical variation is below 8% of the input while deliberate fast motion follows immediately. These are synthetic behavior checks, not proof of subjective smoothness on arbitrary artwork or devices.

Fluid drawing uses elapsed time and filtered pointer velocity
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
python3 scripts/check_release.py dist/SnipShelf-0.2.0-arm64.zip
(cd dist && shasum -a 256 -c SnipShelf-0.2.0-arm64.zip.sha256)
```

The check verifies the exact bundled file list, version 0.2.0/build 3, arm64
architecture, and the ad-hoc signature after extraction. It rejects common
local-user/build paths and private-key markers in bundled files. Only the app
executable, plist, icon, MIT license, and signature resources are distributed;
debug symbols, extended attributes, and provisioning profiles are excluded.
This targeted scan does not establish complete anonymity. The downloaded-app
Gatekeeper flow still needs a manual check on another Mac.

## Interface rendering

The September 16 snip fix passed all 60 checks, including six supplied-image
selections using `SNIPSHELF_MASK_QA_CASES`. Each subject produced identical PNG
bytes when analyzed alone or placed at an offset on a 2560 × 1440 background.
The earlier full-screen analysis left visible background around small subjects;
Vision now analyzes the selection's rectangular bounds before applying its lasso.
The checks also cover failed-mask retry, retaining pending capture windows across
focus changes, bringing the existing review forward when Capture is invoked
again, and keeping the source pixel under the pointer fixed during zoom.

Direct Computer Use plugin calls reproduced the old hidden-preview dead end and
verified the rebuilt app's polygon selection, Capture Preview, Touch Up erase,
keyboard undo, Refine, Redraw, and cancellation. The original shelf retained its
24 clips. The `@oai/sky` entrypoint was unavailable, but the direct plugin worked
with the full app path. Actual screen capture encountered the macOS recording
permission guard. Physical freehand feel and trackpad pinch remain manual checks.
Logs, mask comparisons, and light/dark native renders are under ignored
`.local/snip-debug/`.

The September 16 follow-up combines Capture Preview and touch-up in one floating
window. All 60 checks passed again, including the extended native interaction
check above and light/dark rendering at 440 × 540 and 360 × 440 points. Direct
Computer Use plugin inspection confirmed the installed app's editable floating
preview and integrated brush controls. The active user edit was retained.
Build/test logs and renders are under ignored `.local/unified-review/`.

The keyboard follow-up passed all 61 checks. Small-window light/dark renders were
checked again after adding visible Undo/Redo buttons and complete shortcut hints.
Direct Computer Use plugin calls against an isolated QA shelf verified R/E/V,
both bracket keys after moving the brush slider, Command–Equal/Minus/0/1, real
Erase/Restore strokes, and Command–Z/Command–Shift–Z restoring and removing the
same visible stroke. The QA selection was cancelled and the verified build was
installed in `/Applications/SnipShelf.app`. Logs and renders are under ignored
`.local/shortcuts-qa/`.

To repeat the optional subject-mask check with a local manifest of image paths
and lasso points (the supplied images are not committed):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SNIPSHELF_MASK_QA_CASES="$PWD/.local/vision-comparison/real/cases.json" \
swift test --filter SelectionCorrectionTests
```

The September 16 polish adds labeled Capture/Import actions, compact group
navigation, a selection menu, native preview control groups, shared background
choices, and keyboard-accessible shortcut recording. Checks also cover copy
confirmation timing and the compact capture-review height. Current before/after
render evidence is under ignored `.local/ux-before/` and `.local/ux-after/`.
Computer Use returned `Trusted RPC service is not configured: sky`; live pointer
feel and compositor-backed glass appearance were not reverified in this pass.

The organization follow-up passed all 57 suite checks. It adds location memory,
undo for organization and renaming, independent saved reference backgrounds, and
image renaming with live window titles. Native checks cover remounting after an
empty group, waiting for the shelf expansion before restoring scroll, and
revealing keyboard selections at the top/bottom edge. One earlier full run hit a
timing failure in the existing reference-drag test; that test and the complete
suite both passed on rerun. Logs are under ignored `.local/organization-*.log`.

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

On September 14, reference groups were integrated into the same native grid as
loose clips, using one main image, two separate thumbnails, and +N for remaining
clips. All 52 checks passed, including the optional light/dark shelf renders at
340 × 440 and 300 × 280. Native event tests exercised opening groups, keyboard
selection, internal moves, external PNG/JPEG drops and their asynchronous save
destinations. Render evidence is under ignored `.local/group-qa/` and has the
cached-view limitations described above. Computer Use returned
`Trusted RPC service is not configured: sky`, so this change has no new physical
pointer verification.

The group hover follow-up passed the native enter/exit, layout, drop, and
transparency checks. Light/dark renders under `.local/group-hover-qa/` include
isolated cards at rest and on hover, confirming rounded outlines with clear
interiors. The motion uses the prototype's 220 ms easing and offsets and becomes
immediate with Reduce Motion. Live pointer verification remains unavailable.

On September 16, group reference windows and individual image pins passed all
53 suite checks. Native event sequences also cover dragging a group card or an
image's pin handle to place a reference, reusing existing windows, click/jitter
separation, and Escape restoring position and visibility. These gestures leave
the drag pasteboard, original clips, membership, and Shelf selection untouched.
The focused reference test also verified native hit-testing of the pin button;
compact light/dark renders are under `.local/reference-qa/`.
The rebuilt, signature-verified app launched successfully. Computer Use returned
`Trusted RPC service is not configured: sky`, so physical pointer interaction
remains unverified; the checks exercise native window, selection and drop APIs.

The reference-motion follow-up verifies the live tracking loop before release:
the lifted card preserves its grab offset, cannot steal focus, and creates no
full reference window while dragging. Native animation checks sample opacity
mid-transition, verify final geometry and preview cleanup, return-to-source
cancellation, interrupted movement continuing from its current position, and
close-during-opening without a stale completion reopening the window. All 53
suite checks passed; compact light/dark renders are under
`.local/reference-motion-qa/`. The transition uses [AppKit animation contexts](https://developer.apple.com/documentation/appkit/nsanimationcontext)
and short crossfades when Reduce Motion is enabled. Single-image windows retain
a thumbnail while the original loads. Computer Use still reports the unavailable
`sky` service, so physical pointer feel remains a manual check.

The card-to-window expansion also checks that the actual window begins at the
card's bounds and shares its intermediate outline while growing for 0.3 seconds.
Closing or retargeting during expansion preserves the intended full window size.
Grid metrics update before the viewport resizes, including the narrow starting
frame, without invalid flow-layout sizes. The follow-up renders are under
`.local/reference-morph-qa/`.

The removed-area guide was rendered on the supplied red-background artwork
using its local source file and a reconstructed coarse lasso. The guide compares
original and current alpha with [Core Image filters](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/subtractblendmode%28%29),
then draws cyan hatching in canvas coordinates; it never modifies export pixels.
On that roughly 356k-pixel selection, 30 brush updates plus native-view refreshes
took 62 ms in a debug build, compared with 793 ms for the initial scalar loop.
This measures that update path, not end-to-end frame timing or physical mouse
latency. Native renders and the probe are under ignored `.local/removed-overlay/`.

On September 14, Fluid drawing and the shared touch-up controls were integrated
into screen-capture and Crop a Copy review. All 46 checks passed, including the
optional native renders at 960 × 720 and 640 × 420 in both appearances. The main
bundle was rebuilt, signature-verified, and relaunched. Direct Computer Use
inspection of the full bundle path timed out, so this integration has native
event and cached-render evidence, not a new physical mouse or screen-recording
permission test. Outputs are under ignored `.local/main-integration/`.

## Previous manual checks

Earlier local QA sessions verified image import, selection review and confirmation, recropping, multi-selection deletion/undo, shelf docking, preview, and clipboard exchange with Preview. The clipboard round-trip preserved PNG bytes. Those sessions used isolated QA storage and synthetic artwork; they are not a new manual test of every build.

## Remaining manual checks and limits

- Physical mouse/trackpad feel on complex artwork, low-contrast edges, and dense textures.
- The complete screen-recording permission and real screen-capture flow, including scale and window exclusion.
- Physical drag/drop into Figma and Finder, and hover-open during an external drag. Clipboard checks do not establish drag/drop interoperability.
- Physical global shortcut activation from other apps. Registration conflicts and preservation of the previous shortcut are covered by native tests; recording and duplicate feedback were checked through the direct plugin.
- Mixed-density displays, display removal, Dock relocation, and fullscreen Spaces.
- Light appearance, Reduce Transparency, Reduce Motion, and spoken VoiceOver navigation.
- HEIC/WebP sample files, macOS 26 runtime, and Intel hardware. Current local runtime tests use macOS 27 on Apple Silicon.
- Developer ID signing, notarization, and the downloaded-app Gatekeeper flow.

Vision subject masking can include background people when they are recognized as part of the same foreground instance, or miss detail on ambiguous artwork and simple geometric shapes. It selects one instance with the most overlap and stays inside the lasso. Refine changes that lasso; Touch Up exposes manual Restore/Erase brushes in main-app review, sharing the Lab controls. These brushes cannot restore pixels outside the lasso. Brush undo retains at most 20 source-resolution snapshots, reduced toward a 64 MiB budget for large cutouts (at least one undo remains available); very large selections may still need tiled rendering for responsive painting. The review toggle restores the original selection and retains touch-ups for re-enabling. Very large images can briefly block during encoding or disk writes. Undo history lasts for the app session; see the [usage guide](usage.md) for storage and recovery behavior.
