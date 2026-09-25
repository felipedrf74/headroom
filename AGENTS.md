# Tokenroom

AI usage for 19 providers: a macOS menu-bar app that reads each tool's login, plus an iPhone app with widgets and a Live Activity, and an Apple Watch app with complications, fed through the user's private iCloud. Formerly Headroom (renamed in 2.0; `LegacyMigration` imports Headroom 1.x settings).

Read `.grok/skills/tokenroom-macos/SKILL.md` before changing the Mac app's UI, tokens, MenuBarExtra behavior, or provider adapters, and `.grok/skills/tokenroom-apple/SKILL.md` before changing the iPhone, widgets, Watch, alerts, or the iCloud relay. Those skills are the source of truth.

Do not put personal names, emails, user IDs, or tokens in source, fixtures, logs, or the snapshot cache. Bundle ID is `app.tokenroom.mac`.

## Build

Xcode 27 is preferred. `./scripts/build.sh` falls back to `swiftc` when Xcode is not installed.

```bash
./scripts/build.sh
```

DerivedData must stay local (`~/Library/Developer/Xcode/DerivedData/Tokenroom`). Do not let Xcode put build products in the source tree.

Build settings live in `Config/*.xcconfig`, not in `project.pbxproj`. Never add `DEVELOPMENT_TEAM` or `CODE_SIGN_*` to the project file: they would override `Config/Local.xcconfig` (git-ignored; team ID and `TOKENROOM_MAC_SIGNING`). `TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh` checks the Command Line Tools fallback.

Tokenroom only reads other tools' sessions. Never refresh, rewrite, or copy their tokens.

## Test

```bash
xcodebuild test -project Tokenroom.xcodeproj -scheme Tokenroom -destination 'platform=macOS'
./scripts/typecheck-shared.sh
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'generic/platform=iOS Simulator'
```

Shared logic (relay, alerts, ranking, parsers) is tested on the Mac. The last command also builds the widgets, the Watch app, and its complications. CI (`.github/workflows/ci.yml`) runs all three on the newest Xcode on the runner (26 or 27).
