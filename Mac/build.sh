#!/usr/bin/env bash
# Builds the Meterkat Mac app from the Xcode project (needs Xcode and XcodeGen).
#
#   Mac/build.sh              Release build, signed for this Mac (Apple Development)
#   Mac/build.sh --install    ...and copy it to /Applications and open it
#   Mac/build.sh --notarize   Developer ID build, notarized and stapled, packed in a DMG for download
#
# --notarize needs a "Developer ID Application" certificate for team 627Y9R25T5
# in the keychain, and notarytool credentials saved under the profile in
# $NOTARY_PROFILE (default "meterkat-notary"). Store credentials with
# `xcrun notarytool store-credentials meterkat-notary` before releasing.
#
# Output goes to build/mac/ in the repo.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/build/mac"
APP_NAME="Meterkat.app"
TEAM_ID="627Y9R25T5"
NOTARY_PROFILE="${NOTARY_PROFILE:-meterkat-notary}"

install=false
notarize=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        --notarize) notarize=true ;;
        *) echo "usage: $0 [--install] [--notarize]" >&2; exit 2 ;;
    esac
done

command -v xcodegen >/dev/null || { echo "XcodeGen not found: brew install xcodegen" >&2; exit 1; }
derived="$REPO/build/DerivedData"
trap '[ ! -d "$derived" ] || rm -r "$derived"' EXIT
available_kb=$(df -Pk "$REPO" | awk 'NR == 2 {print $4}')
[ "$available_kb" -ge 10485760 ] || { echo "At least 10 GiB free disk is required." >&2; exit 1; }
cd "$REPO"
xcodegen generate --quiet
[ ! -e "$OUT" ] || rm -r "$OUT"
mkdir -p "$OUT"

if $notarize; then
    archive="$OUT/MeterkatMac.xcarchive"
    xcodebuild -project Meterkat.xcodeproj -scheme MeterkatMac -configuration Release -destination "generic/platform=macOS" \
        -derivedDataPath "$derived" -archivePath "$archive" archive -quiet
    options="$OUT/ExportOptions.plist"
    cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
        -exportPath "$OUT" -quiet
    # Notarize the app first (from a throwaway zip) so its ticket can be stapled inside the DMG.
    zip="$OUT/Meterkat-notarize.zip"
    ditto -c -k --keepParent "$OUT/$APP_NAME" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm "$zip"
    xcrun stapler staple "$OUT/$APP_NAME"

    # The download is a DMG: Meterkat.app next to an Applications shortcut to drag it onto.
    identity=$(security find-identity -v -p codesigning | awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) {print $2; exit}')
    [ -n "$identity" ] || { echo "No Developer ID Application identity for team $TEAM_ID in the keychain." >&2; exit 1; }
    dmg="$OUT/Meterkat.dmg"
    stage="$OUT/dmg"
    mkdir -p "$stage"
    ditto "$OUT/$APP_NAME" "$stage/$APP_NAME"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "Meterkat" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
    rm -r "$stage"
    codesign --force --sign "$identity" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    echo "$dmg"
else
    xcodebuild -project Meterkat.xcodeproj -scheme MeterkatMac -configuration Release -destination "generic/platform=macOS" \
        -derivedDataPath "$derived" build -quiet
    ditto "$derived/Build/Products/Release/$APP_NAME" "$OUT/$APP_NAME"
fi
echo "$OUT/$APP_NAME"

if $install; then
    dest="/Applications"
    [ -w "$dest" ] || dest="$HOME/Applications"
    mkdir -p "$dest"
    pkill -f "$dest/$APP_NAME/Contents/MacOS/" 2>/dev/null || true
    [ ! -e "${dest:?}/$APP_NAME" ] || rm -r "${dest:?}/$APP_NAME"
    ditto "$OUT/$APP_NAME" "$dest/$APP_NAME"
    open -a "$dest/$APP_NAME"
    echo "Installed $dest/$APP_NAME"
    if command -v meterkat >/dev/null; then
        echo "Run \`meterkat install\` once to open it at login (it also removes the old menu bar app)."
    fi
fi
