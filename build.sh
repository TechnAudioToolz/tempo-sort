#!/bin/zsh
# Builds "Tempo Sort.app" next to this script. UNIVERSAL=1 builds for Apple Silicon and Intel.
set -e
cd "${0:A:h}"
APP="Tempo Sort.app"
VERSION="1.0"
SRC=(Sources/Core/*.swift Sources/UI/*.swift)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "${UNIVERSAL:-}" = 1 ]; then
  TMP="$(mktemp -d)"
  for arch in arm64 x86_64; do
    swiftc -O -parse-as-library $SRC -o "$TMP/$arch" -target "$arch-apple-macosx14.0"
  done
  lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/TempoSort"
  rm -rf "$TMP"
else
  swiftc -O -parse-as-library $SRC -o "$APP/Contents/MacOS/TempoSort" -target "$(uname -m)-apple-macosx14.0"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tempo Sort</string>
  <key>CFBundleDisplayName</key><string>Tempo Sort</string>
  <key>CFBundleIdentifier</key><string>local.temposort</string>
  <key>CFBundleExecutable</key><string>TempoSort</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $PWD/$APP"
