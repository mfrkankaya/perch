#!/bin/zsh
# Builds Perch.app into ./build.
#   --install   copy it to /Applications and launch it
#   --release   universal (arm64 + x86_64) build, zipped as build/Perch-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift

if [[ "$MODE" == "--release" ]]; then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=()
fi

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Perch"

APP=build/Perch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
strip -x "$APP/Contents/MacOS/Perch" 2>/dev/null || true

# A stable signing identity keeps the Screen Recording permission across rebuilds.
# Prefer Developer ID Application for distribution; fall back to Apple Development or ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
fi

SIGN_ARGS=(--force --timestamp)
if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
  SIGN_ARGS+=(--options runtime)
fi
codesign "${SIGN_ARGS[@]}" --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc}; $(lipo -archs "$APP/Contents/MacOS/Perch"))"

if [[ "$MODE" == "--install" ]]; then
  pkill -x Perch 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Perch.app
  cp -R "$APP" /Applications/
  open /Applications/Perch.app
  echo "Installed to /Applications/Perch.app"
fi

if [[ "$MODE" == "--release" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  ZIP="build/Perch-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

  # Notarize if signed with Developer ID and notarytool profile is configured
  NOTARY_PROFILE="perch-notary"
  if [[ "$IDENTITY" == *"Developer ID Application"* ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    echo "Submitting $ZIP to Apple notary service..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "Stapling notarization ticket to $APP..."
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP" || true
  fi

  shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
  echo "Release archive: $ZIP"
fi
