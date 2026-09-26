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
| Claude | 7-day window | Weekly | Keychain `Claude Code-credentials` via `/usr/bin/security`, and the opt-in status-line bridge | Read-only: the access token is used only while valid; never refreshed or written back. On a 401 the Keychain is read once more in case Claude Code replaced the token. User-Agent is built from the installed CLI version. Labeled unofficial. Bridge: a reading under 5 minutes old answers without the direct call while the last direct read is under 30 minutes old; older than 6 h it's ignored. The direct read's other windows (Opus, Sonnet, `limits[]`) and extra usage stay beside bridge readings for 30 minutes (`directReuse`), never past their reset; between direct calls (`fetchBetweenCalls`, also during a 429 wait) a newer bridge reading merges with the last direct read, not with what's shown; the status line alone gives no reading once its weekly window has reset, and headlines its session when it has no weekly value. The card says "via Claude Code's status line", with no time: "Checked …" says when. A direct 429 blocks direct calls until Retry-After while the bridge answers. The bridge edits only `statusLine` in `~/.claude/settings.json` through `JSONTextEdit`, byte for byte (BOM and CRLF kept); it refuses a duplicate `statusLine`, UTF-16, a trailing comma, a broken link, and a `settings.json` or `.claude` folder that links elsewhere (dotfiles other Macs may share, where the script isn't: the message says what to set), rather than rewriting; a read-only file or folder gets its own message, before anything is written (an atomic write would replace a read-only file), and a turn-on that fails partway removes what it wrote. It keeps only the previous status line, never a copy of the file: 2.0.0's copies are deleted at launch and on install and uninstall, except a copy that's a link (it holds only where a link 2.0.0 replaced pointed), which stays until uninstall or until Settings' note about it (`replacedLink`) is dismissed. It reports projects, the home folder's `settings.local.json` included, whose own settings set a status line. Sign in runs `claude auth login`. |
| OpenAI | Weekly window | Weekly | `~/.codex/auth.json` | If `secondary_window` is null, a `primary_window` with `limit_window_seconds >= 6 days` is the weekly meter. Sign in runs `codex login --device-auth`. |
| Cursor | `max(auto%, api%)` | This cycle | Keychain `cursor-access-token` first (Cursor 3.9+), then Cursor `state.vscdb` (an old token can linger there); a Keychain token whose JWT `exp` has passed gives way to a current one there, and one the server refuses is tried once more with the database's (`cursorTokenAfterRefusal`, Grok Bot too; an expired database token isn't tried). A refused Keychain token is remembered in memory as a fingerprint only: while the database has a current token, that goes first, until the Keychain holds another token or Tokenroom restarts; with nothing better the Keychain's is still tried, and it doesn't count as a usable session for Sign In | Monthly billing cycle, never “Weekly”. Sign in opens Cursor. |
| GitHub Copilot | AI credits (premium requests on legacy yearly plans), else Chat | Monthly | Copilot `apps.json`/`hosts.json`, then gh `hosts.yml`, then Keychain `gh:github.com` via `/usr/bin/security` (go-keyring values may be `go-keyring-base64:`/`-encoded:`); a pasted fine-grained token when those are missing or refused, or `copilot_internal` answers 400, 404, or 422 | `GET api.github.com/copilot_internal/user` with `Authorization: token`; `token_based_billing` names the bucket AI credits. github.com only. Plan from `access_type_sku`. Unlimited (`-1`) and zero placeholders are hidden. The response names the account: read only quota fields. Fallback (and the iPhone): `GET /user` for the login, then `/users/{login}/settings/billing/ai_credit/usage?year&month` (UTC month), used = Σ `grossQuantity`, allowance from the plan picked with the token (`CopilotBilling.plans`). The token's window keeps the login read's ID, `premium_interactions` (`CopilotBilling.windowID`), so history and alerts carry on across the two, and "Unofficial" isn't shown for it. 2.0.0 named the token's window `ai_credits`: `HistoryStore` moves that week over once, and the iPhone counts an `ai_credits` window from a 2.0.0 Mac as the same window. Sign in runs `gh auth login`. |
| Antigravity | Gemini weekly | Weekly | Runs `agy -p /usage --output-format json` | Only with agy ≥ 1.1.11: older versions send `/usage` to the model and spend quota. Checks the version first, runs in an empty temp folder, 30 s and 1 MiB caps. Only known bucket ids (`gemini-weekly`, `gemini-5h`, `3p-weekly`, `3p-5h`); a missing fraction is unknown, never 0% or 100%. Login check reads only the attributes of Keychain `gemini`/`antigravity`. |
| Devin | Weekly | Weekly | `~/.local/share/devin/credentials.toml`, then Devin/Windsurf `state.vscdb` `windsurfAuthStatus` | `POST server.codeium.com/…/GetUserStatus` with the key in the body. Percents are remaining; a missing percent beside a reset means 100% used (proto3 drops zeros). A custom `api_server_url` only over https. |
| Z.ai, MiniMax | Weekly | Weekly | Pasted key, else the key in `~/.claude/settings.json` when `ANTHROPIC_BASE_URL` points at them | A key only goes to its own region's host. Z.ai errors arrive as HTTP 200 `success:false`. MiniMax tries `token_plan/remains`, then `coding_plan/remains` (whose `usage_count` is what's left). |
| Kimi Code | Weekly | Weekly | Pasted key, else `~/.kimi-code/credentials/kimi-code.json` while `expires_at` is a minute ahead (never refreshed), else Claude Code settings | `GET /coding/v1/usages`: ratio pools, older int64-string counts, booster wallet (fixed point, 1e6 per cent). Only `Authorization` and `Accept`, like the CLI. |
| OpenCode Go | Weekly | Weekly | Pasted key, else `~/.local/share/opencode/auth.json` `opencode-go.key` | `percent` is used on 0–100 (0.5 is half a percent). 403 `EntitlementError` is “no Go subscription”, not an expired key. |
| OpenRouter, DeepSeek, Moonshot, Vercel | Key limit, or balance | – | Pasted key | Balances are amounts ("$12.40 left"), not meters, until the user sets a reference in the balance's own currency (`budgetUnit`: a USD reference never meters a CNY row). `Forecast` gives the runway from the hourly amounts in history. |
| OpenAI, Anthropic, xAI organizations | Month's spend | This month | Pasted admin/management key | Spend against a monthly budget, with a projected month total. Anthropic polls at most every 15 min. Never auto-enabled. "Test & Save" warns when an xAI key's ACLs allow writes (`APIKeyClient.check`). |

Timeout 12s per request, 20s per provider (35s for Antigravity's CLI). 401/403 → expired; an expired session keeps its last reading, faded, for 24 h (`checked.json` keeps the last answer across relaunches). 429 → rate limited until Retry-After (clamped to 1 min–6 h) and no call goes out until then, though a cheap local reading (`fetchBetweenCalls`: Claude's status line) still counts. `minimumInterval` spacing counts from the last attempt (`lastAttemptAt`), not the last success, except that a failure for want of a login (signed out: nothing was called) doesn't count, and neither does a check where every call (two or more) failed to connect, as when the Mac wakes before its Wi-Fi; an expired session the server refused keeps the spacing. A sign-in or a key saved or removed (`credentialsChanged`) waits for the check in flight, then clears the spacing and any Retry-After, the client's own included (`ProviderClient.credentialsChanged`: Claude's); times from before the clock was set back don't hold calls off. `notEntitled` (e.g. Grok Bot off-plan) shows the reason without Sign In. Credential reads (files, SQLite, `/usr/bin/security`) run through `BlockingIO`, never on the main thread or the cooperative pool. Every request passes its `Provider` explicitly and carries the `Tokenroom/<version>` User-Agent (Claude's direct read sends the installed CLI's instead). Build requests with `TokenroomHTTP.request` when a client needs the status first (fallbacks, error bodies); tests swap the session with `TokenroomHTTP.overrideSession`. Independent last-good cache in `~/Library/Application Support/Tokenroom/`. Coalesce overlapping refreshes. Persist the snapshot cache once per cycle. Reuse the Cursor token for Grok Bot within 20s. Reuse a non-expired Claude keychain read.

Signed-out cards show a **Sign In** button (**Add Key** for key providers). Settings tabs: General, Providers (Connected, Detected on this Mac, Available, Organization billing), API Keys (coding plans, official APIs such as Copilot's token, pay as you go, organization billing), Alerts (shared `AlertPreferences`, kept in step with iCloud by `AlertPreferencesSync`: a change made here goes out laid over the newest shared copy, field by field and threshold level by level, and is retried until iCloud has it; a change made in Settings while one syncs stays, on top; iCloud is read at most every 30 minutes while nothing changed here), News (opt-in, labs, feeds), Menu Bar, iPhone & Watch. `SettingsTabRequest` picks the tab when something else opens Settings. Settings is one AppKit window (`AppDelegate.openSettings`); the SwiftUI `Settings` scene is empty and ⌘, goes to the AppKit window. Key sheets start from the choice saved with the key (Copilot's plan), and more than two choices show as a menu. Signed builds keep pasted keys in the data-protection keychain (`APIKeyStore`) and move login-keychain keys there on first read; a delete with the login-keychain query can remove the data-protection copy too, so the store deletes before it adds, never after. Keychain and settings-file work in Settings runs through `BlockingIO`. Turning a provider off does not log the user out of that provider. If a session is already usable, Sign In finishes immediately instead of waiting. A Claude Keychain item with an expired refresh token is not usable — Sign In runs `claude auth logout` then `claude auth login`. The CLI is `claude` on PATH, otherwise the newest binary in `~/.local/share/claude/versions` or Claude Desktop’s bundled `claude`. Keychain services `Claude Code-credentials` and `Claude Code-credentials-*` are both read. Network timeouts stay unreachable (last good reading), not expired.

A forced refresh never cancels the check in flight (its calls are already out; calling a rate-limited provider again at once can earn a 429): forced refreshes asked for meanwhile share one follow-up check covering every provider they asked for, with the spacing rules keeping just-checked providers resting. Sending to iCloud (readings, history, alerts, and once a day deleting alert records older than two weeks) and News run after a check, outside it, one round at a time (a check that finishes meanwhile leaves one more round); the timer's checks don't wait for them, so a slow iCloud doesn't hold up the next check, while forced refreshes (the popover button, sign-in, waking) return once readings are shared. Going to sleep cancels the check in flight, the follow-up, and the sharing round; a cancelled pass doesn't count its cut-short checks as failures or attempts, and a cancelled iCloud call isn't reported as an iCloud problem (`RelayErrorPolicy.Outcome.cancelled`). Waking always checks again. A measured run-out goes to iCloud once it moves an hour from the one last sent (`RelayPublishPolicy`), not with every drift. `usageEqual` takes reset times within a minute as the same. The pace relayed with each window is measured as of the newest reading.

The app icon comes from `scripts/make-icons.py`: `Tokenroom/AppIcon.icon` for Xcode builds (Liquid Glass on macOS 26 and later; Xcode makes the older sizes from it) and the flattened `AppIcon.appiconset` PNGs the swiftc fallback turns into `AppIcon.icns`. Both come from the same drawing; rerun the script instead of editing either.

Popover icons load through `TokenroomImage` (`NSImage` from the asset catalog or loose `Resources` PNGs/SVGs; the swiftc fallback ships loose files). SwiftUI `Image("name")` alone misses files that are not in an `.car`. Menu-bar glyphs fall back to Canvas marks if the image is missing.

Settings v2: the saved enabled list is authoritative for every provider in `knownProviders` (an empty list stays empty). A provider the settings never saw starts enabled only if `enabledByDefault`, or when a local session is found after launch, off the main thread (`newlyKnown`, `enableDetected`). Organization billing never turns on by itself. `Provider` is a plain `String` enum, not a lenient struct: IDs a newer Tokenroom wrote are skipped when read (the snapshot cache and settings decode entry by entry), and settings save them back untouched (`ForeignChoices`), so going back to the newer version keeps its choices. Readers of the relay use string IDs, so an older iPhone still shows a provider a newer Mac added. Meter fill is clipped to the track capsule; 0% used draws no fill.

## Popover

Cards show the meter with a pace tick (`paceMark`), the pace line for every verdict (tight or critical color only when ahead or out), and a forecast line for balances and org spend. Clicking the header expands a card: reset date, the week's `Sparkline`, every other window as a `WindowRow`, banked resets with expiries, plan, last check, and the unofficial note. More than five connected providers switch to one line each (`isCompact`), expanding on click. The footer strip (`HighlightPill`s) counts banked resets, unseen models, and unseen updates, shortening its labels when all three show; News opens in its own window (`NewsWindowView`, off until turned on). Providers without an icon asset show their monogram ("GH").

A debug build renders the popover, Settings tabs, the News window, and the menu bar from sample data: `Tokenroom.app/Contents/MacOS/Tokenroom -TokenroomSnapshots <folder>` (add `-AppleLocale en_US` for README images).

## Copy

No apologies. Errors start with “Couldn't…”. Sign-in lines name the real command (`grok login`, `claude login`, `codex login`, “Sign in to Grok Bot”, “Sign in to Cursor”).

## Verify

Running `Tokenroom.app`: five live percentages when signed in (Build + Bot distinct), Sign In on a signed-out card, popover icons and meters, disable a provider, dark and light. A missing credential does not blank the others. Source, fixtures, logs, and `snapshots.json` contain no emails, names, or tokens.
