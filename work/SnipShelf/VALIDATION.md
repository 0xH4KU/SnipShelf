# SnipShelf v0.3 validation

Validation date: 2026-09-08. Host: Apple Silicon, macOS 27.0 (26A5425a). Toolchain: Xcode 26.6 (17F113), macOS SDK 26.5. Deployment target: macOS 26.0. This is a local ad-hoc signed debug build, not a notarized public release.

## v0.3 checks

**19 automated tests pass.** Six new regression checks cover closer-border switching, thin browser-like pixel edges without Vision, resuming in the middle of an existing segment, Delete/Continue/Confirm state transitions and exactly-once confirmation, batch deletion/undo preserving newer clips, and screen-lasso pixel assistance before Vision has finished.

Real-app checks with isolated QA artwork:

- Dragged a marquee from the blank gutter across four thumbnails; all four were selected.
- Deleted the group with the trash button and, after fixing collection keyboard handling, with Backspace. The stored count changed from 107 to 103. One Command–Z restored all four and their selection.
- Checked native single selection and Space preview after replacing the hosted card event bridge with native image/label cells.
- Drew a polygon and entered review. The red Delete, yellow Continue, and green Confirm buttons appeared. The QA shelf count remained 109.
- Changed to Lasso, chose Continue, and dragged from the middle of an old segment to retrace the remainder. The revised outline returned to review without adding a clip.
- Clicked red Delete: the outline cleared and the shelf count remained 109.
- Drew another selection and clicked green Confirm: exactly one new PNG appeared, bringing the count to 110.

The Chrome-specific report has been addressed at two identified code paths (no assistance before Vision returns, and excessively sticky previous contours), with native pixel-edge regression tests. **The exact Chrome page/image reported by the user was not available or reproduced in this run.** Real-page Chrome behavior and arbitrary complex-photo accuracy remain manual checks; synthetic edge tests are not claimed as a full browser reproduction.

## v0.2 lasso update

The v0.2 suite had **13 tests, 0 failures**, including four new checks:

- A synthetic hand-jitter trace has less than 40% of the input's vertical noise energy after stabilization. Fast deliberate moves follow immediately; zero strength bypasses filtering. Results match at 1× and 2× coordinates.
- Edge projection respects the capture radius and release hysteresis. Short contour corner routes are retained; a distant detour across an opening is rejected.
- The real Apple Vision request detects both black and white rectangles on transparent backgrounds. Converted contour coordinates match the expected top-left image coordinates within 2 pixels.
- AppKit lasso events produce the snapped 30-pixel output, a 32-pixel manual output with Option held, and a 32-pixel manual output when edge detection arrives after the stroke has begun.

The native crop window was opened with QA artwork: Vision reached “Edges ready”, and the assistance popover displayed its enabled toggle, 10 pt distance, and 55% steadiness controls. This does not establish subjective hand feel on every mouse/trackpad or contour accuracy on arbitrary photographs. The earlier unverified cross-app and permission checks below remain unverified.

## Original automated checks — passed

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

The original nine XCTest cases remain passing. Their initial run completed in approximately 0.93 seconds after compilation.

| Check | Evidence |
| --- | --- |
| 1×/2× coordinate mapping, crop bounds and image orientation | Known blue/red source regions remain in the correct position after crop and PNG round-trip. |
| Concave paths | Pixels in the cut-away notch have zero alpha; included pixels remain opaque. |
| Self-intersecting paths | Bow-tie lobes render; a twice-traced rectangle cancels under even-odd fill. |
| Invalid selections and anti-aliasing | Empty, non-finite, tiny, and off-image selections are rejected; diagonal edges include intermediate alpha values. |
| Existing transparency | A second crop preserves transparent pixels. |
| EXIF orientation and invalid input | A rotated JPEG decodes to the expected swapped dimensions; invalid bytes are rejected. |
| Actual lasso view event flow | AppKit mouse-down/drag/up events delivered to the canvas produce the expected clipped image. 100% view size respects backing scale. |
| Persistence, deletion, and undo | A new store reloads the same clip records. Undo retains clips added after deletion. A missing image does not prevent other clips from opening. |
| Failed save and corrupt index | Replacing the index destination with a directory forces a real write error. The clip is retained for retry, prior data survives, and retry succeeds. A corrupt index is left untouched in read-only mode. |
| 100 mixed-size clips | 100 images with varying dimensions save/reload correctly; all persisted thumbnails fit within 320 pixels. |
| Shelf movement and docking | Moving away from the edge preserves expanded state, crossing the right docking threshold collapses to 24 pt, and expanding restores the original width. |

Some test cases cover several related checks in the table above.

## Original real app checks — passed

The app was launched as a `.app` bundle with independent QA storage and preferences.

- Empty shelf, populated two-column grid, menu-bar entry, and native glass rendering inspected through screenshots and accessibility state.
- Imported four transparent PNGs and a JPEG composition through macOS Open With delivery.
- Opened a clip preview with Space; opened Crop a Copy from both a contextual menu and the preview.
- Created a four-point polygon in the actual crop window and completed it with Return. A 287 × 427 PNG was added, with the original retained.
- Moved the crop toolbar to the bottom of the canvas and cancelled with Escape.
- Copied the cutout and created a document from the clipboard in Apple's Preview app.
- Pasted the image back into SnipShelf. The source cutout and pasted PNG were byte-for-byte identical (SHA-256 comparison).
- Deleted a selected clip with Backspace and restored it with Command–Z.
- Collapsed and reopened the 24 × 88 pt edge tab. Dragged the expanded shelf away from the edge, then back to trigger docking.
- Imported a further 100 synthetic images. All 100 arrived, for 107 QA clips in total. Scrolled through the populated grid, quit/relaunched, and confirmed 107 clips returned.
- A spot process sample after loading showed about 177 MiB RSS and 0.0% idle CPU. After scrolling, RSS was about 182 MiB. These are observations on this host, not performance guarantees or a sustained FPS benchmark.
- Default shortcut registration succeeded without reporting a conflict. This does not prove activation from every other app.

## Not yet verified — do not treat as passed

- **Screen-recording permission and a complete real screen capture:** the code compiles against ScreenCaptureKit, but the app's OS permission flow was not granted/exercised during this run. On first use, allow screen recording, relaunch if macOS requests it, then verify that SnipShelf and the pointer are excluded and the result has the correct scale.
- **Physical drag into Figma and Finder:** outgoing native dragging and incoming item-provider handling are implemented, but a successful cross-app drop was not demonstrated. The available browser connection failed to initialize because a bundled runtime module was missing. A tool-driven in-app drag did not produce a confirmed destination receipt. Clipboard interoperability with Preview is verified separately and is not proof of drag interoperability.
- **Hover-open during an external drag:** implemented with a 450 ms dwell; needs physical-pointer testing along with external drops.
- **True global shortcut activation and conflict recovery:** registration is verified; test triggering from a design tool and deliberately occupying the shortcut with another application.
- **Mixed-density external monitors, unplug/replug, Dock relocation, and fullscreen Spaces:** positioning/recovery logic is implemented; this hardware/configuration matrix was not exercised.
- **Light system appearance, Reduce Transparency, Reduce Motion, and spoken VoiceOver navigation:** system-aware code and labels are present, but those system settings were not changed during this run.
- **HEIC and WebP samples:** supported through ImageIO and accepted by the importer, but manual visual checks used PNG/JPEG only.
- **macOS 26 runtime and Intel:** the source targets macOS 26+, but runtime testing took place on macOS 27. The supplied binary is arm64 only.
- **Notarization/Gatekeeper download flow:** not submitted or tested. Distribution guidance is in the README.

## Known boundaries

One shelf, left/right manual docking, one screen per capture, manual lasso/polygon selection with optional contour assistance and steadiness, sRGB PNG output, and session-scoped deletion undo. No AI background removal, cloud sync, accounts, auto-updates, or live donation link. Very large images can briefly block interaction during serial encoding/writing. A true end-user drag-and-screen-capture smoke test is the next release gate before public distribution. Selection review and multi-selection deletion are now part of v0.3.
