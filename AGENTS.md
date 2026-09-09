# Headroom

macOS menu-bar app that shows weekly (or billing-cycle) subscription usage for Grok, Claude, OpenAI/Codex, and Cursor.

Read `.grok/skills/headroom-macos/SKILL.md` before changing UI, tokens, MenuBarExtra behavior, or provider adapters. That skill is the source of truth for tokens, collapse rules, and provider contracts.

Do not put personal names, emails, user IDs, or tokens in source, fixtures, logs, or the snapshot cache. Bundle ID is `app.headroom.mac`.

## Build

Xcode 27 is preferred. `./scripts/build.sh` falls back to `swiftc` when Xcode is not installed.

```bash
./scripts/build.sh
```

DerivedData must stay local (`~/Library/Developer/Xcode/DerivedData/Headroom`). Do not let Xcode put build products in the source tree.
