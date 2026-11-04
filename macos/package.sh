#!/bin/sh
# Builds SamSearch.app and nanolight-macos-arm64.dmg in zig-out/package, and
# the update the app's updater reads from the release:
# nanolight-macos-arm64.zip and manifest.json (its version and the zip's
# sha256).
#
#   VERSION=0.1.0 sh macos/package.sh
#
# Signs with $CODESIGN_IDENTITY (a "Developer ID Application" identity in
# the keychain) when it is set, else ad hoc. Notarizes and staples the app
# and the disk image when it is set and either NOTARY_PROFILE (a profile
# saved with `xcrun notarytool store-credentials`) or NOTARY_KEY_PATH,
# NOTARY_KEY_ID and NOTARY_ISSUER_ID (an App Store Connect API key) are set.
# Only a build signed by a team updates itself (nanoui's updater checks the
# new bundle is signed by the running one's team).
set -eu
cd "$(dirname "$0")/.."

version="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
out=zig-out/package
bundle="$out/SamSearch.app"
dmg="$out/nanolight-macos-arm64.dmg"
zip="$out/nanolight-macos-arm64.zip"

# For macOS 14 and Apple silicon from the M1 on: a native build would need
# the macOS and the CPU it was built on.
min_macos=14.0
zig build app -Doptimize=ReleaseSafe -Dtarget=aarch64-macos.$min_macos -Dcpu=apple_m1 -Dversion="$version" ${ZIG_FLAGS:-}
if ! vtool -show-build zig-out/SamSearch.app/Contents/MacOS/nanolight | grep -q "minos $min_macos\$"; then
  echo "SamSearch is not built for macOS $min_macos:" >&2
  vtool -show-build zig-out/SamSearch.app/Contents/MacOS/nanolight >&2
  exit 1
fi
rm -rf "$out"
mkdir -p "$out"
# zig-out's copy is read-only (the build cache's files): a writable one.
ditto zig-out/SamSearch.app "$bundle"
chmod -R u+w "$bundle"

sign() {
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$1"
  else
    codesign --force --sign - "$1"
  fi
}

notarizing() {
  [ -n "${CODESIGN_IDENTITY:-}" ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_KEY_PATH:-}" ]; }
}

notarize() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" --wait
  fi
}

# Stapling fetches the ticket from Apple's CloudKit, which sometimes drops
# the connection (error 68) though notarization succeeded: a few tries.
staple() {
  for try in 1 2 3 4 5; do
    xcrun stapler staple "$1" && return 0
    echo "stapling $1 failed (try $try); retrying" >&2
    sleep $((try * 10))
  done
  return 1
}

sign "$bundle"
if notarizing; then
  ditto -c -k --keepParent "$bundle" "$out/SamSearch.zip"
  notarize "$out/SamSearch.zip"
  staple "$bundle"
  rm "$out/SamSearch.zip"
fi

# The disk image: the app, and Applications to drag it to.
stage="$out/dmg"
mkdir -p "$stage"
cp -R "$bundle" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname SamSearch -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$stage"
sign "$dmg"
if notarizing; then
  notarize "$dmg"
  staple "$dmg"
fi
(cd "$out" && shasum -a 256 "$(basename "$dmg")" | tee "$(basename "$dmg").sha256")

# The update: the (stapled) app zipped, and the manifest naming it.
ditto -c -k --keepParent "$bundle" "$zip"
sum=$(shasum -a 256 "$zip" | cut -d' ' -f1)
printf '{"version":"%s","files":{"%s":{"sha256":"%s"}}}\n' "$version" "$(basename "$zip")" "$sum" > "$out/manifest.json"
cat "$out/manifest.json"
