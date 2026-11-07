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

# The updater only compares plain dotted numbers: the last tag, plus how many
# commits since as a fourth part (0.2.6.18), sorts after that release and
# before the next one. "0.2.6-18-g…" would never update again.
if [ -z "${VERSION:-}" ]; then
  tag="$(git describe --tags --abbrev=0 2>/dev/null || git tag --sort=-version:refname | head -n 1)"
  since="$(git rev-list --count "$tag"..HEAD 2>/dev/null || echo 0)"
  VERSION="${tag#v}"
  [ "$since" -gt 0 ] && VERSION="$VERSION.$since"
fi
version="${VERSION#v}"
case "$version" in
  *[!0-9.]*) echo "Version '$version' isn't plain dotted numbers; the updater would ignore it." >&2; exit 1 ;;
esac
if [ -z "$version" ]; then
  echo "No version tag found; set VERSION explicitly before installing." >&2
  exit 1
fi
zig build app -Doptimize=ReleaseSafe -Dversion="$version"
APP="$PWD/zig-out/SamSearch.app"
mkdir -p "$APP/Contents/Helpers"
QUICKASK_APP="$APP/Contents/Helpers/Quick Ask.app" QUICKASK_NO_START=1 QUICKASK_NO_REGISTER=1 QUICKASK_VERSION="$version" CODESIGN_IDENTITY="${IDENTITY:--}" sh quickask/build.sh
# The outer signature last: it seals the helper inside.
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

osascript -e 'if application id "dev.samin.samsearch" is running then tell application id "dev.samin.samsearch" to quit' >/dev/null 2>&1 || true
osascript -e 'if application id "com.samin.quickask" is running then tell application id "com.samin.quickask" to quit' >/dev/null 2>&1 || true
# Never replace executable files until both old processes have really exited.
remaining=100
while pgrep -x nanolight >/dev/null || pgrep -x SamSearch >/dev/null || pgrep -x QuickAsk >/dev/null; do
  if [ "$remaining" -eq 0 ]; then
    echo "SamSearch or Quick Ask did not exit within 20 seconds; leaving the installed bundle intact." >&2
    exit 1
  fi
  remaining=$((remaining - 1))
  sleep 0.2
done
rm -rf /Applications/SamSearch.app
ditto "$APP" /Applications/SamSearch.app
"$LSREGISTER" -f /Applications/SamSearch.app "/Applications/SamSearch.app/Contents/Helpers/Quick Ask.app"
open /Applications/SamSearch.app
echo "Installed and started /Applications/SamSearch.app"
