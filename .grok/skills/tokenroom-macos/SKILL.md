---
name: tokenroom-macos
description: >-
  Native SwiftUI rules for Tokenroom, a macOS menu-bar app that shows AI
  subscription quotas, API balances, and organization spend for 19 providers
  (Claude, Codex, Grok, Cursor, Copilot, coding plans, and more). Use when editing
  Tokenroom, MenuBarExtra, provider adapters, popover meters, tokens, Keychain
  or CLI credential reads, or when the user runs /tokenroom-macos.
---

# Tokenroom macOS

Community menu-bar extra. Glance first. Apple-native, not a web page. Bundle ID `app.tokenroom.mac`.

## Tokens (single source)

| Token | Value | Role |
|---|---|---|
| Material | `.menu` / `.popover` | Popover chrome |
| Ink | `Color.primary` | Names, healthy numbers |
| Mute | `Color.secondary` | Captions, timestamps |
| Track | `Color.primary.opacity(0.12)` | Empty meter |
| Fill | usage gradient | Weekly used-bar |
| Healthy | `#6EC4F5` | 0% used (light blue) |
| Watch | `#F2C416` | ~50% used |
| Tight | `#E87A10` | ~75% used |
| Critical | `#D62D26` | 100% used |
| Stale | secondary at 0.55 opacity | Last-good after a failed refresh |
| Menu type | 12pt semibold tabular % | Menu-bar extra |
| Popover name | system 13 semibold | `Grok` |
| Popover % | system 22 medium, tabular | `42%` |
| Caption | system 11 regular, secondary | `Weekly · resets in 3d 4h` |
| Meter | height 8, corner radius 6 | Used fill only |
| Rhythm | 8 pt | Card padding 12, gap 10 |

Memorable element: compact extra — brand glyph + tabular %, or iStat-style vertical used-bars. Names live in the popover. No status dot. Keep it narrow so macOS 27 does not park it behind the overflow chevron.

`TokenroomTokens.ink(remaining:isStale:)` owns popover percent color. Menu-bar type uses `Color.primary` only. Menu-bar meters use one solid color from `usageColor(usedPercent:)` (light blue < 50%, yellow < 75%, orange < 90%, red at 90%+). The popover track keeps `usageGradient`. Do not duplicate thresholds.

## Menu bar

Enabled + connected providers only:

```
  Percents:  [glyph] 2%   [glyph] 9%   [glyph] 32%
  Meters:    [glyph]|     [glyph]|     [glyph]|
```

`AppSettings.menuStyle` is Percents or Meters. Meters are vertical rounded rectangles: 8.05×18pt, 1.6pt corners (soft, not a pill), 1pt primary outline. Used fill sits in an inner well 1.2pt off the stroke so it does not touch the outline. Fill height is `wellHeight × usedPercent / 100` from the bottom of that well. Glyphs are 17.22pt. Grok and GPT marks are vector templates (full even-odd Grok slash, not a cropped PNG). Menu-bar fill is one color by used % (light blue / yellow / orange / red). Popover meters keep the light-blue → red gradient. No leading health dot. Photographed app icons stay in the popover via `ProviderIcon`. Short names: Build, Bot, Claude, GPT, Cursor. Loading uses `–%`. Percents are whole numbers (`55%`, not `55.2%`). Signed-out / expired providers are omitted. Never hide an enabled connected provider. Opening the popover refreshes if the last attempt is older than 45s. Unchanged usage does not rewrite status or the menu extra.

The extra is an **AppKit `NSStatusItem`** hosting `MenuBarLabel` in a passthrough `NSHostingView`. Click opens an `NSPopover`. Settings is `AppDelegate.openSettings`. `LSUIElement`. Install to `/Applications/Tokenroom.app`.

## Providers

Protocol `ProviderClient.fetch() async -> Result<QuotaSnapshot, ProviderError>`, with an optional `fetchBudget` (20 s default). Parallel refresh. One failure never blocks the others. Credentials are read in place and never copied into Tokenroom storage or logs. The cache holds percentages, reset times, window and plan names, and amounts (balance, spend, credits); never identities. `Provider.descriptor` is the one catalog entry per provider; `access` says whether it connects with a local login, a coding-plan key (pasted, or found in another tool's config on the Mac), or a pasted key. Windows are ordered primary first.

| Extra | Primary meter | Label | Auth | Notes |
|---|---|---|---|---|
| Grok Build | Weekly pool | Weekly | `~/.grok/auth.json` | Missing `creditUsagePercent` on a weekly unified period means 0. Read-only: the token is used only while `expires_at` is ahead; never refreshed or written back (the CLI may rotate its refresh token). Sign in runs `grok login --device-auth`. |
| Grok Bot | Weekly pool | Weekly | Cursor `state.vscdb` token | `POST …/GetSandUsageStatus`. Separate from Grok Build. Sign in opens Grok Bot (`com.anysphere.sand`), then Cursor. Wait on a readable access token, not `state.vscdb` mtime (WAL writes do not bump the main file). |
| Claude | 7-day window | Weekly | Keychain `Claude Code-credentials` via `/usr/bin/security` | Read-only: the access token is used only while valid; never refreshed or written back. On a 401 the Keychain is read once more in case Claude Code replaced the token. User-Agent is built from the installed CLI version. 5-hour window is popover-only. Sign in runs `claude auth login`. |
| OpenAI | Weekly window | Weekly | `~/.codex/auth.json` | If `secondary_window` is null, a `primary_window` with `limit_window_seconds >= 6 days` is the weekly meter. Sign in runs `codex login --device-auth`. |
| Cursor | `max(auto%, api%)` | This cycle | Cursor `state.vscdb` | Monthly billing cycle, never “Weekly”. Sign in opens Cursor. |
| GitHub Copilot | Premium requests, else Chat | Monthly | Copilot `apps.json`/`hosts.json`, then gh `hosts.yml`, then Keychain `gh:github.com` via `/usr/bin/security` (go-keyring values may be `go-keyring-base64:`/`-encoded:`) | `GET api.github.com/copilot_internal/user` with `Authorization: token`. github.com only. Plan from `access_type_sku` (`copilot_plan` says “individual” even on Free). Unlimited (`-1`) and zero placeholders are hidden. The response names the account: read only quota fields. Sign in runs `gh auth login`. |
| Antigravity | Gemini weekly | Weekly | Runs `agy -p /usage --output-format json` | Only with agy ≥ 1.1.11: older versions send `/usage` to the model and spend quota. Checks the version first, runs in an empty temp folder, 30 s and 1 MiB caps. Only known bucket ids (`gemini-weekly`, `gemini-5h`, `3p-weekly`, `3p-5h`); a missing fraction is unknown, never 0% or 100%. Login check reads only the attributes of Keychain `gemini`/`antigravity`. |
| Devin | Weekly | Weekly | `~/.local/share/devin/credentials.toml`, then Devin/Windsurf `state.vscdb` `windsurfAuthStatus` | `POST server.codeium.com/…/GetUserStatus` with the key in the body. Percents are remaining; a missing percent beside a reset means 100% used (proto3 drops zeros). A custom `api_server_url` only over https. |
| Z.ai, MiniMax | Weekly | Weekly | Pasted key, else the key in `~/.claude/settings.json` when `ANTHROPIC_BASE_URL` points at them | A key only goes to its own region's host. Z.ai errors arrive as HTTP 200 `success:false`. MiniMax tries `token_plan/remains`, then `coding_plan/remains` (whose `usage_count` is what's left). |
| Kimi Code | Weekly | Weekly | Pasted key, else `~/.kimi-code/credentials/kimi-code.json` while `expires_at` is a minute ahead (never refreshed), else Claude Code settings | `GET /coding/v1/usages`: ratio pools, older int64-string counts, booster wallet (fixed point, 1e6 per cent). Only `Authorization` and `Accept`, like the CLI. |
| OpenCode Go | Weekly | Weekly | Pasted key, else `~/.local/share/opencode/auth.json` `opencode-go.key` | `percent` is used on 0–100 (0.5 is half a percent). 403 `EntitlementError` is “no Go subscription”, not an expired key. |
| OpenRouter, DeepSeek, Moonshot, Vercel | Key limit, or balance | – | Pasted key | Balances are amounts, not meters, until the user sets a budget. |
| OpenAI, Anthropic, xAI organizations | Month's spend | This month | Pasted admin/management key | Spend against a monthly budget. Anthropic polls at most every 15 min. xAI warns if the key can write. |

Timeout 12s per request, 20s per provider (35s for Antigravity's CLI). 401/403 → expired; an expired session keeps its last reading, faded, for 24 h. 429 → rate limited until Retry-After (clamped to 1 min–6 h) and the provider is skipped until then. `notEntitled` (e.g. Grok Bot off-plan) shows the reason without Sign In. Credential reads (files, SQLite, `/usr/bin/security`) run through `BlockingIO`, never on the main thread or the cooperative pool. Every request passes its `Provider` explicitly and carries the `Tokenroom/<version>` User-Agent (Claude's direct read sends the installed CLI's instead). Build requests with `TokenroomHTTP.request` when a client needs the status first (fallbacks, error bodies); tests swap the session with `TokenroomHTTP.overrideSession`. Independent last-good cache in `~/Library/Application Support/Tokenroom/`. Coalesce overlapping refreshes. Persist the snapshot cache once per cycle. Reuse the Cursor token for Grok Bot within 20s. Reuse a non-expired Claude keychain read.

Signed-out cards show a **Sign In** button (**Add Key** for key providers). Settings → Providers shows connection status: Subscriptions, Coding plans, Pay as you go, Organization billing. Turning a provider off does not log the user out of that provider. If a session is already usable, Sign In finishes immediately instead of waiting. A Claude Keychain item with an expired refresh token is not usable — Sign In runs `claude auth logout` then `claude auth login`. The CLI is `claude` on PATH, otherwise the newest binary in `~/.local/share/claude/versions` or Claude Desktop’s bundled `claude`. Keychain services `Claude Code-credentials` and `Claude Code-credentials-*` are both read. Network timeouts stay unreachable (last good reading), not expired.

Popover icons load through `TokenroomImage` (`NSImage` from the asset catalog or loose `Resources` PNGs/SVGs; the swiftc fallback ships loose files). SwiftUI `Image("name")` alone misses files that are not in an `.car`. Menu-bar glyphs fall back to Canvas marks if the image is missing.

Settings v2: the saved enabled list is authoritative for every provider in `knownProviders` (an empty list stays empty). A provider the settings never saw starts enabled only if `enabledByDefault` or a local session is detected. Meter fill is clipped to the track capsule; 0% used draws no fill.

## Copy

No apologies. Errors start with “Couldn't…”. Sign-in lines name the real command (`grok login`, `claude login`, `codex login`, “Sign in to Grok Bot”, “Sign in to Cursor”).

## Verify

Running `Tokenroom.app`: five live percentages when signed in (Build + Bot distinct), Sign In on a signed-out card, popover icons and meters, disable a provider, dark and light. A missing credential does not blank the others. Source, fixtures, logs, and `snapshots.json` contain no emails, names, or tokens.
