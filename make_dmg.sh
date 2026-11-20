#!/bin/zsh
# Packages the app for download: Apple Silicon + Intel build, an Applications shortcut,
# the license and a short "How to open" note.   ./make_dmg.sh -> dist/Tempo-Sort-<version>.dmg
set -euo pipefail
cd "${0:A:h}"
UNIVERSAL=1 ./build.sh
APP="Tempo Sort.app"
VERSION="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)"
mkdir -p dist
DMG="dist/Tempo-Sort-$VERSION.dmg"
STAGE="$(mktemp -d)/Tempo Sort"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/License.txt"
cat > "$STAGE/How to open.txt" <<TXT
Tempo Sort $VERSION

1. Drag "Tempo Sort" onto the Applications folder.
2. Open it from Applications.

The first time, macOS may say it can't check the app for malicious software. That's because
this free app isn't registered with Apple. To open it anyway:

   System Settings > Privacy and Security > scroll down > "Open Anyway"

You only need to do this once.

What it does: pick a music folder, Tempo Sort finds the BPM of every track in it and its
subfolders, then copies or moves each one into a folder for its BPM range (like 80bpm-100bpm).

Works fully offline. Needs macOS 14 Sonoma or newer. Runs on Apple Silicon and Intel Macs.

USE AT YOUR OWN RISK. Tempo Sort copies or moves your files. Keep a backup of your music,
especially before using Move. Detected BPMs can be wrong. The software is provided "as is",
without warranty of any kind; the authors are not liable for any lost or moved files or other
damage from its use. See License.txt and Help > Disclaimer in the app.

github.com/TechnAudioToolz/tempo-sort  |  kevin-burns.com  |  kevburns.gumroad.com
TXT
rm -f "$DMG"
hdiutil create -volname "Tempo Sort" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$(dirname "$STAGE")"
hdiutil verify "$DMG" > /dev/null && echo "verified"
ls -l "$DMG"
