#!/bin/zsh
# Build a notarized Developer ID release of Tokenroom for Mac.
#
#   ./scripts/release.sh
#
# Needs:
#   - Config/Local.xcconfig with TOKENROOM_TEAM_ID (the team that owns the iCloud container).
#   - Xcode signed in to that team. Export uses Xcode's cloud-managed Developer ID
#     certificate when none is installed (Account Holder or Admin role).
#   - Notarization credentials saved once in the Keychain:
#       xcrun notarytool store-credentials tokenroom-notary --apple-id <you> --team-id <TEAM>
#     (override the profile name with TOKENROOM_NOTARY_PROFILE).
#
# Output: build/release/Tokenroom-<version>.zip (+ .sha256), stapled and ready to upload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Tokenroom"
PROFILE="${TOKENROOM_NOTARY_PROFILE:-tokenroom-notary}"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
DERIVED="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Tokenroom}"

xcconfig_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^/]*).*/\1/p" "$file" | tail -1 | sed -E 's/[[:space:]]+$//'
}

TEAM="$(xcconfig_value "$ROOT/Config/Local.xcconfig" TOKENROOM_TEAM_ID)"
VERSION="$(xcconfig_value "$ROOT/Config/Version.xcconfig" TOKENROOM_MAC_VERSION)"
if [[ -z "$TEAM" ]]; then
  echo "Couldn't find TOKENROOM_TEAM_ID in Config/Local.xcconfig." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "Archiving $APP_NAME $VERSION for team $TEAM"
xcodebuild archive \
  -project "$ROOT/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  TOKENROOM_MAC_SIGNING=team

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

echo "Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates

APP="$EXPORT/$APP_NAME.app"
codesign --verify --strict --deep "$APP"
authority="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority/ && !found { print $2; found = 1 }')"
if [[ "$authority" != Developer\ ID\ Application* ]]; then
  echo "Couldn't confirm a Developer ID signature (got: ${authority:-none})." >&2
  exit 1
fi
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)"
if [[ "$entitlements" != *"iCloud."* ]]; then
  echo "Couldn't find the iCloud container entitlement; iPhone sync would be off in this build." >&2
  exit 1
fi
if [[ "$entitlements" != *'"com.apple.developer.icloud-container-environment":"Production"'* ]]; then
  echo "Couldn't confirm the Production iCloud environment in the exported app." >&2
  exit 1
fi
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || { echo "Couldn't find the embedded provisioning profile." >&2; exit 1; }
echo "Signed: $authority · iCloud Production"

ZIP="$OUT/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
echo "Notarizing (keychain profile: $PROFILE)"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$OUT/notarize.zip"

ditto -c -k --keepParent "$APP" "$ZIP"
# Named without the folder, so `shasum -c` works next to the download and no local path leaks.
(cd "$OUT" && shasum -a 256 "${ZIP:t}") | tee "$ZIP.sha256"
echo "Ready: $ZIP"
echo "Draft a GitHub release with: gh release create v$VERSION \"$ZIP\" --draft --title \"Tokenroom $VERSION\""
