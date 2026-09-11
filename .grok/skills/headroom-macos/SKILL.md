---
name: headroom-macos
description: >-
  Native SwiftUI rules for Headroom, a macOS menu-bar app that shows Grok,
  Claude, OpenAI/Codex, and Cursor subscription quotas. Use when editing
  Headroom, MenuBarExtra, provider adapters, popover meters, tokens, Keychain
  or CLI credential reads, or when the user runs /headroom-macos.
---

# Headroom macOS

Community menu-bar extra. Glance first. Apple-native, not a web page. Bundle ID `app.headroom.mac`.

## Tokens (single source)

| Token | Value | Role |
|---|---|---|
| Material | `.menu` / `.popover` | Popover chrome |
| Ink | `Color.primary` | Names, healthy numbers |
| Mute | `Color.secondary` | Captions, timestamps |
| Track | `Color.primary.opacity(0.12)` | Empty meter |
| Fill | `Color.primary.opacity(0.85)` | Healthy used-bar |
| Tight | `#C47A2C` | Remaining ≤ 25% |
| Critical | `#C23B22` | Remaining ≤ 10% |
| Stale | secondary at 0.55 opacity | Last-good after a failed refresh |
| Menu type | 12pt semibold tabular % | Menu-bar extra |
| Popover name | system 13 semibold | `Grok` |
| Popover % | system 22 medium, tabular | `42%` |
| Caption | system 11 regular, secondary | `Weekly · resets in 3d 4h` |
| Meter | height 8, corner radius 6 | Used fill only |
| Rhythm | 8 pt | Card padding 12, gap 10 |

Memorable element: compact extra — brand glyph + tabular %, or iStat-style vertical used-bars. Names live in the popover. No status dot. Keep it narrow so macOS 27 does not park it behind the overflow chevron.

`HeadroomTokens.ink(remaining:isStale:)` owns popover percent color. Menu-bar type uses `Color.primary` only. Do not duplicate thresholds.

## Menu bar

Enabled + connected providers only:

```
  Percents:  [glyph] 2%   [glyph] 9%   [glyph] 32%
  Meters:    [glyph]|     [glyph]|     [glyph]|
```

`AppSettings.menuStyle` is Percents or Meters. Meters follow iStat-style vertical capsules: 5×18pt, 1pt primary outline, fill from the bottom. Fill height is `innerHeight × usedPercent / 100` of the inset track, clipped to the capsule so 50% used is half the inner bar. Glyphs are 16.4pt. Grok and GPT marks are vector templates (full even-odd Grok slash, not a cropped PNG). Fill color uses `HeadroomTokens.meterFill`. No leading health dot. Photographed app icons stay in the popover via `ProviderIcon`. Short names: Build, Bot, Claude, GPT, Cursor. Loading uses `–%`. Percents round to a whole number when within 0.05, otherwise one decimal. Signed-out / expired providers are omitted. Never hide an enabled connected provider. Opening the popover refreshes if the last attempt is older than 45s. Unchanged usage does not rewrite status or the menu extra.

The extra is an **AppKit `NSStatusItem`** hosting `MenuBarLabel` in a passthrough `NSHostingView`. Click opens an `NSPopover`. Settings is `AppDelegate.openSettings`. `LSUIElement`. Install to `/Applications/Headroom.app`.

## Providers

Protocol `ProviderClient.fetch() async -> Result<QuotaSnapshot, ProviderError>`. Parallel refresh. One failure never blocks the others. Credentials are read in place and never copied into Headroom storage or logs. Cache is percentages, reset times, and provider names only.

| Extra | Primary meter | Label | Auth | Notes |
|---|---|---|---|---|
| Grok Build | Weekly pool | Weekly | `~/.grok/auth.json` | Missing `creditUsagePercent` on a weekly unified period means 0. Refresh OIDC via `https://auth.x.ai/oauth2/token`. Sign in runs `grok login --device-auth`. |
| Grok Bot | Weekly pool | Weekly | Cursor `state.vscdb` token | `POST …/GetSandUsageStatus`. Separate from Grok Build. Sign in opens Grok Bot (`com.anysphere.sand`), then Cursor. Wait on a readable access token, not `state.vscdb` mtime (WAL writes do not bump the main file). |
| Claude | 7-day window | Weekly | Keychain `Claude Code-credentials` via `/usr/bin/security` | Refresh expired OAuth at `platform.claude.com/v1/oauth/token`. 5-hour window is popover-only. Sign in runs `claude auth login`. |
| OpenAI | Weekly window | Weekly | `~/.codex/auth.json` | If `secondary_window` is null, a `primary_window` with `limit_window_seconds >= 6 days` is the weekly meter. Sign in runs `codex login --device-auth`. |
| Cursor | `max(auto%, api%)` | This cycle | Cursor `state.vscdb` | Monthly billing cycle, never “Weekly”. Sign in opens Cursor. |

Timeout 8s. 401/403 → expired. Independent last-good cache in `~/Library/Application Support/Headroom/`. Coalesce overlapping refreshes. Persist the snapshot cache once per cycle. Reuse the Cursor token for Grok Bot within 20s. Reuse a non-expired Claude keychain read.

Signed-out cards show a **Sign In** button. Settings → Accounts shows connection status. Turning a provider off does not log the user out of that provider. If a session is already usable, Sign In finishes immediately instead of waiting.

Popover icons load through `HeadroomImage` (`NSImage` from the asset catalog or loose `Resources` PNGs). SwiftUI `Image("name")` alone misses files that are not in an `.car`. Menu-bar glyphs fall back to Canvas marks if the PNG is missing. Meter fill is clipped to the track capsule; 0% used draws no fill.

## Copy

No apologies. Errors start with “Couldn't…”. Sign-in lines name the real command (`grok login`, `claude login`, `codex login`, “Sign in to Grok Bot”, “Sign in to Cursor”).

## Verify

Running `Headroom.app`: five live percentages when signed in (Build + Bot distinct), Sign In on a signed-out card, popover icons and meters, disable a provider, dark and light. A missing credential does not blank the others. Source, fixtures, logs, and `snapshots.json` contain no emails, names, or tokens.
