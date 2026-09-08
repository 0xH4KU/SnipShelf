# Validation

Last checked: 2026-09-08. Host: Apple Silicon, macOS 27.0 (26A5425a), Xcode 26.6 (17F113), macOS SDK 26.5. Deployment target: macOS 26. Local app bundles are ad-hoc signed, not notarized.

## Automated checks

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build_and_run.sh --build
codesign --verify --strict dist/SnipShelf.app
```

The suite contains **23 passing tests** covering:

| Area | Coverage |
| --- | --- |
| Freehand assistance | Light stabilization, bounded edge nudges at multiple scales, crossing edges, ambiguous/dense regions, sharp turns, Option bypass, and late Vision results. Each drag adds at most one point; review output matches the displayed path. |
| Polygon assistance | Local contour selection, release distance, alternate candidates, and pixel fallback on thin borders. |
| Selection review | Continue from the middle of an existing segment, Delete/Continue/Confirm transitions, and exactly-once confirmation. |
| Image processing | Coordinate mapping, orientation, concave and self-intersecting selections, invalid input, transparency, anti-aliasing, and PNG round-trips. |
| Local storage | Persistence, deletion/undo, batch deletion with newer clips, missing assets, failed writes, corrupt index recovery, and 100 mixed-size clips. |
| AppKit interaction | Canvas mouse event flows, actual-size scaling, and shelf move/dock state. |

Freehand tests bound filter lag to one screen point and edge correction to 1.1 screen points. The tested combined trace stays within 2.1 points of the pointer. These are synthetic behavior checks, not proof of subjective smoothness on arbitrary artwork or devices.

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
