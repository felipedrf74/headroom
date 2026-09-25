#!/bin/zsh
# Typechecks Shared/ against every platform that compiles it (macOS, iOS, watchOS),
# including watchOS before its targets exist. No Xcode project involved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
sources=("${(@f)$(find Shared -name '*.swift' | sort)}")

check() {
  local sdk="$1" target="$2"
  echo "Typechecking Shared/ for $target"
  swiftc -typecheck -parse-as-library -swift-version 6 \
    -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -target "$target" \
    "${sources[@]}"
}

check macosx arm64-apple-macosx15.0
check iphoneos arm64-apple-ios26.0
check watchos arm64-apple-watchos26.0
echo "Shared/ typechecks on macOS, iOS, and watchOS."
