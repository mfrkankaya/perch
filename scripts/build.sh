#!/bin/zsh
# Builds Perch.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift

swift build -c release
APP=build/Perch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Perch" "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/Perch" 2>/dev/null || true

# A stable signing identity keeps the Screen Recording permission across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Perch 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Perch.app
  cp -R "$APP" /Applications/
  open /Applications/Perch.app
  echo "Installed to /Applications/Perch.app"
fi
