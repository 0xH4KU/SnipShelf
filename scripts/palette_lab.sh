#!/bin/bash
set -euo pipefail
MODE="${1:-run}"
case "$MODE" in run|--build) ;; *) echo "Usage: $0 [run|--build]" >&2; exit 2 ;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT_DIR"
swift build --product PaletteLab
BUILD_DIR="$(swift build --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/PaletteLab.app"
pkill -TERM -x PaletteLab >/dev/null 2>&1 || true
for attempt in 1 2 3; do
  if ! pgrep -x PaletteLab >/dev/null; then break; fi
  sleep 1
done
if pgrep -x PaletteLab >/dev/null; then echo "Palette Lab is still running." >&2; exit 1; fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/PaletteLab" "$APP_BUNDLE/Contents/MacOS/PaletteLab"
cp Assets/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP_BUNDLE/Contents/Resources/LICENSE"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PaletteLab</string>
<key>CFBundleIdentifier</key><string>org.snipshelf.palette-lab</string>
<key>CFBundleName</key><string>Palette Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Image</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.image</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
if [[ "$MODE" == run ]]; then open -n "$APP_BUNDLE"; else echo "$APP_BUNDLE"; fi
