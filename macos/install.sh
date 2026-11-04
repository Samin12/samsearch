#!/bin/sh
# Builds SamSearch with Quick Ask inside it (Contents/Helpers/Quick Ask.app), signs both
# with your Apple Development certificate (so macOS permissions stick across rebuilds),
# installs it to /Applications and starts it.
#
#     sh macos/install.sh
set -eu
cd "$(dirname "$0")/.."
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"

zig build app -Doptimize=ReleaseSafe
APP="$PWD/zig-out/SamSearch.app"
mkdir -p "$APP/Contents/Helpers"
QUICKASK_APP="$APP/Contents/Helpers/Quick Ask.app" QUICKASK_NO_START=1 CODESIGN_IDENTITY="${IDENTITY:--}" sh quickask/build.sh
# The outer signature last: it seals the helper inside.
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

osascript -e 'quit app "SamSearch"' >/dev/null 2>&1 || true
pkill -x QuickAsk 2>/dev/null || true
sleep 1
rm -rf /Applications/SamSearch.app
ditto "$APP" /Applications/SamSearch.app
"$LSREGISTER" -f /Applications/SamSearch.app "/Applications/SamSearch.app/Contents/Helpers/Quick Ask.app"
open /Applications/SamSearch.app
echo "Installed and started /Applications/SamSearch.app"
