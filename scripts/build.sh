#!/bin/zsh
# Build Tokenroom for Mac and install it to ~/Applications (and /Applications when writable).
#
#   ./scripts/build.sh [Debug|Release]
#
# Uses Xcode when it is installed, otherwise a swiftc fallback that only needs the
# Command Line Tools. TOKENROOM_FORCE_SWIFTC=1 forces the fallback (CI uses this).
# Signing follows Config/Local.xcconfig (adhoc by default; see Config/MacSigning.xcconfig).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Tokenroom}"
CONFIG="${1:-Release}"
ARCH="$(uname -m)"
APP_NAME="Tokenroom"
ASSETS="$ROOT/Tokenroom/Assets.xcassets"

# Value of KEY from an xcconfig file ("KEY = value"), empty if missing.
xcconfig_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^/]*).*/\1/p" "$file" | tail -1 | sed -E 's/[[:space:]]+$//'
}

install_app() {
  local app="$1"
  local user_dest="$HOME/Applications/$APP_NAME.app"
  local system_dest="/Applications/$APP_NAME.app"

  mkdir -p "$HOME/Applications"
  rm -rf "$user_dest"
  cp -R "$app" "$user_dest"
  echo "Installed $user_dest"

  if rm -rf "$system_dest" 2>/dev/null && cp -R "$app" "$system_dest" 2>/dev/null; then
    echo "Installed $system_dest"
  else
    echo "Couldn't write $system_dest (needs permission). Using $user_dest."
  fi
}

xcode_developer_dir() {
  local developer="${DEVELOPER_DIR:-}"
  if [[ -n "$developer" && -d "$developer" ]]; then
    echo "$developer"
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    echo /Applications/Xcode.app/Contents/Developer
  elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    echo /Applications/Xcode-beta.app/Contents/Developer
  fi
}

build_with_xcode() {
  export DEVELOPER_DIR="$1"
  local project="$ROOT/$APP_NAME.xcodeproj"
  local signing
  signing="$(xcodebuild -project "$project" -scheme "$APP_NAME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | awk '$1 == "TOKENROOM_MAC_SIGNING" { print $3; exit }')"
  signing="${signing:-adhoc}"
  echo "Building with Xcode ($CONFIG, $signing signing)"

  local provisioning=()
  [[ "$signing" == "adhoc" ]] || provisioning=(-allowProvisioningUpdates)

  mkdir -p "$DERIVED"
  xcodebuild \
    -project "$project" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination "platform=macOS,arch=$ARCH" \
    "${provisioning[@]}" \
    build

  # Xcode already signed the bundle with the right identity and entitlements.
  # Never modify it afterwards: that would break a team signature.
  local app="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
  codesign --verify --strict "$app"
  local authority
  authority="$(codesign -dvv "$app" 2>&1 | awk -F= '/^Authority/ && !found { print $2; found = 1 }')"
  echo "Signature OK (${authority:-ad-hoc})"
  install_app "$app"
}

# Copies every image set as loose files so NSImage can find them without Assets.car:
# Name.svg, Name(@2x|@3x).png, and Name-32/-64.png as Name.png/Name@2x.png.
copy_loose_images() {
  local res="$1" set name suffix
  for set in "$ASSETS"/*.imageset(N); do
    name="${set:t:r}"
    [[ -f "$set/$name.svg" ]] && cp "$set/$name.svg" "$res/$name.svg"
    for suffix in "" "@2x" "@3x"; do
      [[ -f "$set/$name$suffix.png" ]] && cp "$set/$name$suffix.png" "$res/$name$suffix.png"
    done
    [[ -f "$set/$name-32.png" ]] && cp "$set/$name-32.png" "$res/$name.png"
    [[ -f "$set/$name-64.png" ]] && cp "$set/$name-64.png" "$res/$name@2x.png"
  done
  return 0
}

write_info_plist() {
  local plist="$1" bundle_id="$2" version="$3" build="$4"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$bundle_id</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$build</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>$APP_NAME contributors</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
}

build_with_swiftc() {
  local sdk build app res
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  build="${TMPDIR:-/tmp}/tokenroom-build"
  app="$build/$APP_NAME.app"
  res="$app/Contents/Resources"
  rm -rf "$build"
  mkdir -p "$app/Contents/MacOS" "$res"

  local version build_number prefix
  version="$(xcconfig_value "$ROOT/Config/Version.xcconfig" TOKENROOM_MAC_VERSION)"
  build_number="$(xcconfig_value "$ROOT/Config/Version.xcconfig" TOKENROOM_MAC_BUILD)"
  prefix="$(xcconfig_value "$ROOT/Config/Base.xcconfig" TOKENROOM_BUNDLE_PREFIX)"

  # Mac sources plus the shared folders the Mac target compiles.
  local dirs=() dir
  for dir in Tokenroom Shared/Core Shared/Relay Shared/UI Shared/APIKeys; do
    [[ -d "$ROOT/$dir" ]] && dirs+=("$ROOT/$dir")
  done
  local sources=("${(@f)$(find "${dirs[@]}" -name '*.swift' | sort)}")

  echo "Building with swiftc and $sdk (no Xcode needed)"
  swiftc \
    -sdk "$sdk" \
    -target "${ARCH}-apple-macosx15.0" \
    -parse-as-library \
    -O \
    -swift-version 6 \
    -lsqlite3 \
    -o "$app/Contents/MacOS/$APP_NAME" \
    "${sources[@]}"

  echo -n 'APPL????' > "$app/Contents/PkgInfo"
  write_info_plist "$app/Contents/Info.plist" "${prefix:-app.tokenroom}.mac" "${version:-0.0.0}" "${build_number:-1}"

  local iconset
  iconset="$(mktemp -d "${TMPDIR:-/tmp}/TokenroomIcon.XXXXXX").iconset"
  mkdir -p "$iconset"
  cp "$ASSETS/AppIcon.appiconset/"*.png "$iconset/"
  iconutil -c icns "$iconset" -o "$res/AppIcon.icns"
  rm -rf "$iconset"
  copy_loose_images "$res"

  codesign --force --sign - --entitlements "$ROOT/Tokenroom/Tokenroom.entitlements" --options runtime "$app"
  install_app "$app"
}

developer="$(xcode_developer_dir)"
if [[ "${TOKENROOM_FORCE_SWIFTC:-0}" != "1" && -n "$developer" ]] && DEVELOPER_DIR="$developer" command -v xcodebuild >/dev/null 2>&1; then
  build_with_xcode "$developer"
else
  build_with_swiftc
fi
