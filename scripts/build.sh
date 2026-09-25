#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/Tokenroom}"
CONFIG="${1:-Release}"
ARCH="$(uname -m)"

mkdir -p "$HOME/Applications"

install_app() {
  local app="$1"
  local user_dest="$HOME/Applications/Tokenroom.app"
  local system_dest="/Applications/Tokenroom.app"

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
  local assets="$ROOT/Tokenroom/Assets.xcassets"
  local res="$app/Contents/Resources"
  mkdir -p "$res"

  local iconset
  iconset="$(mktemp -d /tmp/TokenroomIcon.XXXXXX)"
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
	<string>Tokenroom</string>
	<key>CFBundleExecutable</key>
	<string>Tokenroom</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>app.tokenroom.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Tokenroom</string>
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
	<string>Tokenroom contributors</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
}

build_with_xcode() {
  local developer="${DEVELOPER_DIR:-}"
  if [[ -z "$developer" || ! -d "$developer" ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
      developer="/Applications/Xcode.app/Contents/Developer"
    elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
      developer="/Applications/Xcode-beta.app/Contents/Developer"
    else
      return 1
    fi
  fi
  export DEVELOPER_DIR="$developer"
  if ! command -v xcodebuild >/dev/null 2>&1; then
    return 1
  fi
  mkdir -p "$DERIVED"
  xcodebuild \
    -project "$ROOT/Tokenroom.xcodeproj" \
    -scheme Tokenroom \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination "platform=macOS,arch=$ARCH" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    build
  local app="$DERIVED/Build/Products/$CONFIG/Tokenroom.app"
  assemble_resources "$app"
  codesign --force --sign - --entitlements "$ROOT/Tokenroom/Tokenroom.entitlements" --options runtime "$app"
  install_app "$app"
}

build_with_swiftc() {
  local sdk
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  local build="/tmp/tokenroom-build"
  rm -rf "$build"
  mkdir -p "$build/Tokenroom.app/Contents/MacOS"

  echo "Xcode not available; building with swiftc and $sdk"
  # shellcheck disable=SC2046
  swiftc \
    -sdk "$sdk" \
    -target "${ARCH}-apple-macosx15.0" \
    -parse-as-library \
    -O \
    -swift-version 6 \
    -lsqlite3 \
    -o "$build/Tokenroom.app/Contents/MacOS/Tokenroom" \
    $(find "$ROOT/Tokenroom" -name '*.swift' | sort)

  chmod +x "$build/Tokenroom.app/Contents/MacOS/Tokenroom"
  echo -n 'APPL????' > "$build/Tokenroom.app/Contents/PkgInfo"
  write_info_plist "$build/Tokenroom.app/Contents/Info.plist"
  assemble_resources "$build/Tokenroom.app"
  codesign --force --sign - --entitlements "$ROOT/Tokenroom/Tokenroom.entitlements" --options runtime "$build/Tokenroom.app"
  install_app "$build/Tokenroom.app"
}

if ! build_with_xcode; then
  build_with_swiftc
fi
