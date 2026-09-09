#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Headroom}"
CONFIG="${1:-Release}"
ARCH="$(uname -m)"

mkdir -p "$HOME/Applications"

install_app() {
  local app="$1"
  local user_dest="$HOME/Applications/Headroom.app"
  local system_dest="/Applications/Headroom.app"

  rm -rf "$user_dest"
  cp -R "$app" "$user_dest"
  echo "Installed $user_dest"

  if rm -rf "$system_dest" 2>/dev/null && cp -R "$app" "$system_dest" 2>/dev/null; then
    echo "Installed $system_dest"
  else
    echo "Could not write $system_dest (need permission). Using $user_dest."
  fi
}

assemble_resources() {
  local app="$1"
  local assets="$ROOT/Headroom/Assets.xcassets"
  local res="$app/Contents/Resources"
  mkdir -p "$res"

  local iconset
  iconset="$(mktemp -d /tmp/HeadroomIcon.XXXXXX)"
  cp "$assets/AppIcon.appiconset/"*.png "$iconset/"
  mv "$iconset" "$iconset.iconset"
  iconutil -c icns "$iconset.iconset" -o "$res/AppIcon.icns"
  rm -rf "$iconset.iconset"

  local name
  for name in GlyphBuild GlyphBot GlyphGPT; do
    cp "$assets/${name}.imageset/${name}.png" "$res/${name}.png"
    cp "$assets/${name}.imageset/${name}@2x.png" "$res/${name}@2x.png"
    cp "$assets/${name}.imageset/${name}@3x.png" "$res/${name}@3x.png"
  done

  copy_provider() {
    local asset="$1" one="$2" two="$3"
    cp "$assets/${asset}.imageset/${one}" "$res/${asset}.png"
    cp "$assets/${asset}.imageset/${two}" "$res/${asset}@2x.png"
  }
  copy_provider ProviderBuild ProviderBuild-32.png ProviderBuild-64.png
  copy_provider ProviderBot ProviderBot-32.png ProviderBot-64.png
  copy_provider ProviderClaude ProviderClaude-32.png ProviderClaude-64.png
  copy_provider ProviderGPT ProviderGPT-32.png ProviderGPT-64.png
  copy_provider ProviderCursor ProviderCursor-32.png ProviderCursor-64.png
}

write_info_plist() {
  local plist="$1"
  cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Headroom</string>
	<key>CFBundleExecutable</key>
	<string>Headroom</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>app.headroom.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Headroom</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Headroom contributors</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
}

build_with_xcode() {
  local developer="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
  if [[ ! -d "$developer" ]]; then
    return 1
  fi
  export DEVELOPER_DIR="$developer"
  if ! command -v xcodebuild >/dev/null 2>&1; then
    return 1
  fi
  mkdir -p "$DERIVED"
  xcodebuild \
    -project "$ROOT/Headroom.xcodeproj" \
    -scheme Headroom \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination "platform=macOS,arch=$ARCH" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    build
  local app="$DERIVED/Build/Products/$CONFIG/Headroom.app"
  assemble_resources "$app"
  codesign --force --sign - --entitlements "$ROOT/Headroom/Headroom.entitlements" --options runtime "$app"
  install_app "$app"
}

build_with_swiftc() {
  local sdk
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  local build="/tmp/headroom-build"
  rm -rf "$build"
  mkdir -p "$build/Headroom.app/Contents/MacOS"

  echo "Xcode not available; building with swiftc and $sdk"
  # shellcheck disable=SC2046
  swiftc \
    -sdk "$sdk" \
    -target "${ARCH}-apple-macosx15.0" \
    -parse-as-library \
    -O \
    -swift-version 6 \
    -lsqlite3 \
    -o "$build/Headroom.app/Contents/MacOS/Headroom" \
    $(find "$ROOT/Headroom" -name '*.swift' | sort)

  chmod +x "$build/Headroom.app/Contents/MacOS/Headroom"
  echo -n 'APPL????' > "$build/Headroom.app/Contents/PkgInfo"
  write_info_plist "$build/Headroom.app/Contents/Info.plist"
  assemble_resources "$build/Headroom.app"
  codesign --force --sign - --entitlements "$ROOT/Headroom/Headroom.entitlements" --options runtime "$build/Headroom.app"
  install_app "$build/Headroom.app"
}

if ! build_with_xcode; then
  build_with_swiftc
fi
