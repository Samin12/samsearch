#!/bin/zsh
# Builds ~/Applications/Quick Ask.app: SamSearch's helper (local server on 127.0.0.1:47213 + quickask:// links).
set -euo pipefail
cd "${0:A:h}"
APP="${QUICKASK_APP:-$HOME/Applications/Quick Ask.app}"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/QuickAsk" -framework Cocoa -framework WebKit -framework Vision -framework QuickLookThumbnailing
cp ask.html digup.html marked.min.js "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# A stable identity keeps macOS's Screen Recording permission across rebuilds (ad-hoc signatures change every build).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pkill -x QuickAsk 2>/dev/null || true
sleep 0.5
open -g "$APP"
echo "Built and started $APP"
