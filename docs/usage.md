# Using SnipShelf

**Keep the part you love.** A free, native macOS shelf for the visual pieces of your creative work.

Draw a lasso or polygon around an element, keep the transparent cutout nearby, and drag it into your work. Built with SwiftUI, AppKit, ScreenCaptureKit, and the native Liquid Glass material. No third-party dependencies, account, uploads, analytics, or subscription.

![SnipShelf with synthetic QA artwork](shelf.jpg)

## Requirements and first launch

- macOS 26 or newer. The 0.1.1 release ZIP supports Apple Silicon (arm64).
- Unzip the download and move `SnipShelf.app` to Applications.
- Open `SnipShelf.app`. It lives in the menu bar; there is no Dock icon.
- Start a capture from the menu bar or press **Command–Shift–2**. If macOS asks, allow screen recording in **System Settings → Privacy & Security → Screen & System Audio Recording**. If the system requests a relaunch, quit and reopen the app.
- Image import and recropping work without screen-recording permission.
- Settings lets you record another capture shortcut. Include Command or Control. A registration failure is reported; capture remains available in the menu bar.

This build uses an **ad-hoc signature**, with no developer certificate, and is
**not notarized**. If Gatekeeper blocks your first launch, and you trust this
download, open **System Settings → Privacy & Security → Open Anyway**, then
confirm the launch. See [Apple's instructions](https://support.apple.com/102445).
Managed Macs may restrict this exception. You can also build from source.

## Selection and review

![Review a selection before keeping it](review.jpg)

- Releasing a lasso (or finishing a polygon) hides the capture editor and opens a compact **Capture Preview** near the selection. The desktop becomes visible again. Nothing is stored until you press **Keep Clip** or Return; Escape or the preview's close button cancels.
- **Redraw** clears the current outline and lets you start again on the same image. It does not delete existing shelf clips. Command–Z restores the outline if you change your mind.
- **Refine** returns to the frozen source image with the path, zoom, pan, and toolbar position preserved. Drag from a point on the existing outline to cut back and retrace from there, including between sampled corners; start farther away to extend the endpoint. Command–Z restores the outline from before the most recent refinement and returns to the compact preview; one outline checkpoint is retained.
- **Keep Clip** adds exactly one transparent PNG to the shelf and selects it for copying or dragging. The app warns if you try to quit with an unconfirmed selection.
- The compact preview shows the actual transparent cutout against a subtle neutral background. Use **Refine** to inspect it in the original image.
- **Lasso stays freehand.** Gentle edge help can make a tiny correction toward a nearby edge aligned with your stroke. It fades around corners and competing edges, and yields entirely in dense regions. It never locks onto a contour or inserts contour vertices. **Option** bypasses edge help while keeping steadiness.
- [Apple Vision contours](https://developer.apple.com/documentation/vision/vndetectcontoursrequest) are prepared in the background. A lasso begun before they are ready stays freehand for that stroke; dragging never scans source pixels. Polygon mode retains explicit snapping with **Tab** to choose nearby edges and local pixel fallback when needed.
- Zoom, Fit, 100%, pinch and scroll-to-pan work in the capture editor before drawing. Use Redraw to clear an outline before changing the view; Command–Z can restore it.
- The shelf now uses native macOS collection selection. **Drag from empty space** across thumbnails to select a group; Command-click toggles items and Command–A selects all. Press **Delete**, use the trash button, or right-click for batch deletion. **Command–Z** restores the whole deleted group, including after new clips have been added.

Adaptive steadiness remains available in the wand menu (default 55%; zero disables it), with at most one screen point of filter lag. Freehand edge help searches within four screen points and contributes at most about 1.1 pt of correction. Polygon snap distance defaults to 10 pt and can be set from 4–24 pt. Choices persist. Vision uses a 1536-pixel working image; export retains the original pixels. Assistance is intentionally conservative on low-contrast or complex artwork and does not perform object segmentation.

## Capture and crop

- **Lasso:** hold the mouse button, draw around the element, and release to review.
- **Polygon:** click each corner, then click near the first point or press Return to review. Delete removes the last point while drawing.
- **Escape:** cancel without adding anything. Redraw clears the current selection.
- Drag the little handle at the left of the selection toolbar if it covers your subject.
- The tool uses a frozen screenshot from the display under the pointer. Capture excludes SnipShelf's windows and the pointer. A selection stays on one display; zoom and pan operate on this frozen image.
- The area outside the selection becomes transparent. This is manual clipping, **not automatic background removal**: background inside your selection remains.
- Self-intersecting outlines use even-odd fill. Very small, empty, and invalid selections are rejected.

Use **Crop a Copy** on an existing clip to crop it again without changing the original. Fit shows the whole image, 100% maps one source pixel to one display pixel, +/- or a pinch adjusts zoom, and scrolling pans. Zoom and pan are locked while drawing.

PNG, JPEG, WebP, and HEIC files can be imported with the + button, dragged into the shelf, or opened with SnipShelf from Finder. Pasted image data is also supported. Images above 100 megapixels are rejected to bound memory use. Output is anti-aliased, 8-bit sRGB PNG with transparency; HDR output and animated images are outside v0.1.1.

## The shelf

- New clips appear first and become selected. A brief “Clip saved” status, or a checkmark and “Saved” on the narrow edge tab, confirms success. Capturing does **not** overwrite the clipboard or force open a tucked shelf.
- Click a thumbnail to select it; with one clip selected, Space or a double-click opens a resizable preview window. Left/Right switch between clips; Space or Escape closes it. Pinch to zoom and scroll to pan; Fit and 100% reset the view. Arrow keys also navigate clips on the shelf.
- Drag a thumbnail to copy its PNG to another app. Right-click a single clip for Preview, Copy Image, Export PNG, Crop a Copy, and Delete. A multi-selection offers batch Delete; native dragging can export selected files together. Dragging clips back onto the same shelf is rejected and does not create duplicates or trigger hover-open.
- **Command–C** copies the selected image, **Command–V** pastes into the shelf, **Command–O** imports, and **Command–Z** undoes a deletion while the shelf has keyboard focus.
- Drag the top handle to move the shelf. Near the left or right usable screen edge, its contents fade into a glass panel with a large arrow pointing inward, away from that edge. Pull away to restore the contents; release to tuck it into the usual narrow edge tab. There is no visible docking text or blue docking outline.
- Click the edge tab or pull it inward to open. Keep dragging in the same gesture to place the expanded shelf; release to leave it there. A short inward pull does not immediately tuck it again. Drag along the edge to reposition the tab vertically. It stays open until you explicitly collapse it.
- Holding a dragged image over the edge tab for about 450 ms reveals the drop area. Moving an ordinary pointer over the tab does not open it.
- Resize the expanded shelf at its edges. Position, size, side, and collapsed state are restored next launch. If a display disappears, the shelf returns to a visible screen area.
- Shelf thumbnails show transparent pixels directly against the shelf, with no checkerboard or solid image well. Choose Checkerboard, Light, or Dark in the preview or Settings to inspect transparency in the preview. The app follows system appearance and respects Reduce Motion and Reduce Transparency.

## Local data and recovery

Clips live in `~/Library/Application Support/SnipShelf/`: one full PNG, one small preview PNG per clip, and a versioned `index.json`. Appearance and window preferences use UserDefaults.

Dragging/exporting does not remove clips. Delete and Clear Shelf can be undone until the app exits. Removed files are retained for that recovery window and collected on the next successful launch. Already-exported files are unaffected.

The app writes image files before atomically replacing the index. If saving fails, the new clip stays in memory with **Retry Save** and **Export Unsaved Clip** actions. It blocks additional imports/captures until that clip is saved or exported. Quit warns before discarding an unsaved clip. A damaged or unsupported index makes the shelf read-only instead of replacing it. Open the storage folder from Settings to back it up or recover it.

Full-resolution images are loaded for import, crop, preview, or export. The grid lazily loads small disk previews into a bounded cache. PNG/index writes are currently serial; extremely large imports can briefly stall the interface. Move encoding to a dedicated queue if that becomes a measured bottleneck.

For build commands and the repository layout, see the [README](../README.md). See [validation](validation.md) for verified behavior and remaining checks.
