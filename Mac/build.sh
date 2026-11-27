#!/usr/bin/env bash
# Builds the Meterkat Mac app from the Xcode project (needs Xcode and XcodeGen).
#
#   Mac/build.sh              Release build, signed for this Mac (Apple Development)
#   Mac/build.sh --install    ...and copy it to /Applications and open it
#   Mac/build.sh --notarize   Developer ID build, notarized and stapled, zipped for download
#
# --notarize needs a "Developer ID Application" certificate for team 627Y9R25T5
# in the keychain, and notarytool credentials saved under the profile in
# $NOTARY_PROFILE (default "aiusage", saved before the rename to Meterkat):
#   xcrun notarytool store-credentials aiusage --apple-id <email> --team-id 627Y9R25T5
#
# Output goes to build/mac/ in the repo.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/build/mac"
APP_NAME="Meterkat.app"
TEAM_ID="627Y9R25T5"
NOTARY_PROFILE="${NOTARY_PROFILE:-aiusage}"

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
cd "$REPO"
xcodegen generate --quiet
rm -rf "$OUT"
mkdir -p "$OUT"

if $notarize; then
    archive="$OUT/MeterkatMac.xcarchive"
    xcodebuild -project Meterkat.xcodeproj -scheme MeterkatMac -configuration Release -destination "generic/platform=macOS" \
        -archivePath "$archive" archive -quiet
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
    zip="$OUT/Meterkat-mac.zip"
    ditto -c -k --keepParent "$OUT/$APP_NAME" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT/$APP_NAME"
    # Zip again so the download carries the stapled ticket.
    rm "$zip"
    ditto -c -k --keepParent "$OUT/$APP_NAME" "$zip"
    echo "$zip"
else
    derived="$REPO/build/DerivedData"
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
    rm -rf "${dest:?}/$APP_NAME"
    ditto "$OUT/$APP_NAME" "$dest/$APP_NAME"
    open -a "$dest/$APP_NAME"
    echo "Installed $dest/$APP_NAME"
    if command -v meterkat >/dev/null; then
        echo "Run \`meterkat install\` once to open it at login (it also removes the old menu bar app)."
    fi
fi
