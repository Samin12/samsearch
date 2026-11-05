#!/bin/sh
# Builds Quick Ask, SamSearch's helper (local server on 127.0.0.1:47213 + quickask:// links).
# macos/install.sh puts it inside SamSearch.app; on its own it goes to ~/Applications/Quick Ask.app.
set -eu
cd "$(dirname "$0")"
APP="${QUICKASK_APP:-$HOME/Applications/Quick Ask.app}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT
clang -fobjc-arc -c codes_archive.m -o "$OBJ/codes_archive.o"
swiftc -O -swift-version 5 -import-objc-header codes_archive.h main.swift codes.swift "$OBJ/codes_archive.o" -lsqlite3 -o "$APP/Contents/MacOS/QuickAsk" -framework Cocoa -framework WebKit -framework Vision -framework QuickLookThumbnailing
cp ask.html digup.html codes.html marked.min.js "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# A stable identity keeps macOS's Screen Recording permission across rebuilds (ad-hoc signatures change every build).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
if [ -z "${QUICKASK_NO_REGISTER:-}" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
# Inside SamSearch.app (macos/install.sh) SamSearch starts it; on its own, start it now.
if [ -z "${QUICKASK_NO_START:-}" ]; then
  pkill -x QuickAsk 2>/dev/null || true
  sleep 0.5
  open -g "$APP"
fi
echo "Built $APP"
