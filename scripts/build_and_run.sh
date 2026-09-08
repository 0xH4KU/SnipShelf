#!/bin/bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT_DIR"
case "$MODE" in run|--verify|--logs|--debug|--build) ;; *) echo "Usage: $0 [run|--build|--verify|--logs|--debug]" >&2; exit 2 ;; esac
if [[ "$MODE" != --build ]]; then
  pkill -TERM -x SnipShelf >/dev/null 2>&1 || true
  for attempt in 1 2 3; do
    if ! pgrep -x SnipShelf >/dev/null; then break; fi
    sleep 1
  done
  if pgrep -x SnipShelf >/dev/null; then
    echo "SnipShelf is still open. Finish or cancel its unsaved-clip prompt before rebuilding." >&2
    exit 1
  fi
fi
swift build
BUILD_DIR="$(swift build --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/dist/SnipShelf.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/SnipShelf" "$APP_BUNDLE/Contents/MacOS/SnipShelf"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SnipShelf</string>
<key>CFBundleIdentifier</key><string>org.snipshelf.app</string>
<key>CFBundleName</key><string>SnipShelf</string>
<key>CFBundleDisplayName</key><string>SnipShelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 SnipShelf contributors. MIT License.</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Image</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.png</string><string>public.jpeg</string><string>org.webmproject.webp</string><string>public.heic</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP_BUNDLE"
case "$MODE" in
  --build) echo "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/SnipShelf" ;;
  --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "SnipShelf"' ;;
  --verify) open -n "$APP_BUNDLE"; sleep 1; pgrep -x SnipShelf ;;
  run) open -n "$APP_BUNDLE" ;;
esac
