#!/bin/bash
# Builds BeatBar.app as a universal (Apple Silicon + Intel) app.
#
#   ./build.sh             build into build/BeatBar.app
#   ./build.sh --install   also copy it to /Applications and launch it
#   ./build.sh --dmg       also make dist/BeatBar.dmg for sharing
#   ./build.sh --demo      also render demo GIFs into docs/
#
# Set SIGN_IDENTITY to a certificate name (see `security find-identity -p codesigning`)
# to keep the audio permission across rebuilds. Without it the app is ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/BeatBar.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.2" \
    -import-objc-header Sources/PrivateTouchBar.h \
    Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework ServiceManagement -framework ImageIO -framework UniformTypeIdentifiers \
    -o "build/BeatBar-$ARCH"
done
lipo -create build/BeatBar-arm64 build/BeatBar-x86_64 -output "$APP/Contents/MacOS/BeatBar"
rm build/BeatBar-arm64 build/BeatBar-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"

for ARG in "$@"; do
  case "$ARG" in
    --install)
      pkill -x BeatBar 2>/dev/null && sleep 1 || true
      rm -rf /Applications/BeatBar.app
      cp -R "$APP" /Applications/
      open /Applications/BeatBar.app
      echo "Installed to /Applications/BeatBar.app"
      ;;
    --demo)
      "$APP/Contents/MacOS/BeatBar" --demo docs
      ;;
    --dmg)
      STAGE=build/dmg
      mkdir -p "$STAGE" dist
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      rm -f dist/BeatBar.dmg
      hdiutil create -volname "BeatBar $VERSION" -srcfolder "$STAGE" -ov -format UDZO dist/BeatBar.dmg >/dev/null
      rm -rf "$STAGE"
      echo "Made dist/BeatBar.dmg"
      ;;
  esac
done
