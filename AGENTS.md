# Tokenroom

macOS menu-bar app that shows weekly (or billing-cycle) subscription usage for Grok, Claude, OpenAI/Codex, and Cursor. Formerly Headroom (renamed in 2.0; `LegacyMigration` imports Headroom 1.x settings).

Read `.grok/skills/tokenroom-macos/SKILL.md` before changing UI, tokens, MenuBarExtra behavior, or provider adapters. That skill is the source of truth for tokens, collapse rules, and provider contracts.

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
```
