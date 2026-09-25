#!/bin/zsh
# Typechecks Shared/ against every platform that compiles it (macOS, iOS, watchOS),
# including watchOS before its targets exist. No Xcode project involved.
# Shared/Widgets is only compiled by the iPhone app and its widgets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
common=("${(@f)$(find Shared -name '*.swift' -not -path 'Shared/Widgets/*' | sort)}")
widget_sources=("${(@f)$(find Shared/Widgets -name '*.swift' | sort)}")

check() {
  local sdk="$1" target="$2"
  shift 2
  echo "Typechecking Shared/ for $target"
  swiftc -typecheck -parse-as-library -swift-version 6 \
    -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -target "$target" \
    "$@"
}

check macosx arm64-apple-macosx15.0 "${common[@]}"
check iphoneos arm64-apple-ios26.0 "${common[@]}" "${widget_sources[@]}"
check watchos arm64-apple-watchos26.0 "${common[@]}"
echo "Shared/ typechecks on macOS, iOS, and watchOS."
