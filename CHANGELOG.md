# Changelog

## 2.0.0 — Unreleased

Headroom is now **Tokenroom**. On first launch Tokenroom brings over Headroom’s settings and last readings, and offers to quit Headroom.

### New providers
- **GitHub Copilot**, with the login Copilot’s editor extensions or the gh CLI already keep.
- **Antigravity**, through `agy` 1.1.11 or later.
- **Devin** (formerly Windsurf).
- **Coding plans:** Z.ai, Kimi Code, MiniMax, and OpenCode Go. Tokenroom uses the key Claude Code, the kimi CLI, or OpenCode already has, or one you add.
- **Pay as you go:** OpenRouter, DeepSeek, Moonshot, and Vercel AI Gateway, with an API key you add. A budget turns a balance into a meter.
- **Organization billing:** this month’s OpenAI, Anthropic, and xAI spend with an admin or management key, against a monthly budget.

API keys stay in the Mac’s Keychain; only the last four characters are shown.

### Richer readings
- Codex: plan, credits, spend limit, named limits, and banked resets.
- Claude: per-model caps and extra usage. An optional Claude Code status-line bridge keeps Claude’s meters current when the direct read can’t.
- Cursor 3.9 and later: the login in the Keychain. Grok: your plan’s name.

### Alerts
- Alerts at 80% and 95%, when a window that reached 80% resets, and when a banked reset arrives or is about to expire. They go to your iPhone through iCloud once per event, however many Macs see it, and follow the iPhone's quiet hours. Settings › iPhone & Watch can show them on the Mac too.

### Menu bar and settings
- Settings has Providers, Menu Bar, iPhone & Watch, and General tabs.
- Any provider can be left out of the menu bar, and the **Highest** style shows only the most-used meter.
- The popover lists connected providers first and folds the rest under “Not connected”.

### Changes
- Tokenroom only reads other tools’ sessions. It no longer refreshes Claude or Grok tokens or writes them back, so it can’t break a Claude Code or Grok CLI session. An expired session keeps its last reading, faded, for up to a day.
- Providers that answer “too many requests” are left alone until their Retry-After passes.
- Grok Bot off a Cursor plan says so instead of asking you to sign in.
- Requests identify themselves as Tokenroom, except where a provider only answers its own client (Claude, Devin).

### Fixes
- The app could freeze while waiting on the Keychain during Claude sign-in.
- Keychain, file, and database reads no longer run on the main thread.
- Turning Grok Bot off now survives a relaunch, and turning every provider off stays off.
- A damaged cache entry no longer wipes the other readings.
- “Last good reading” shows when the reading was last confirmed, not when it first appeared.
- A failed Xcode build no longer installs anything. The Command Line Tools build works again and reports the right version.

## 1.2.2 — 2026-09-23

### Fixes
- Claude Sign In no longer asks you to install Claude when the `claude` shim is missing. Headroom uses the newest installed CLI under `~/.local/share/claude/versions` or Claude Desktop’s bundled `claude`.
- Claude login is also read from Keychain items named `Claude Code-credentials-…`, not only the unsuffixed item.

## 1.2.1 — 2026-09-12

### Fixes
- Claude Sign In no longer treats a dead Keychain session as logged in. If the refresh token is expired, Headroom runs `claude auth logout` then `claude auth login` and waits for new tokens.
- OAuth/network timeouts stay as unreachable (last good reading) instead of locking the extra in Session expired.
- A forced refresh after sign-in is not swallowed by an in-flight timed-out fetch.

## 1.2 — 2026-09-12

### Menu bar
- Meters are 8.05×18 pt rounded rectangles (soft corners, not pills). Used fill sits 1.2 pt inside the outline.
- Percents are whole numbers (`55%`, not `55.2%`).
- Menu-bar fill is one color by used %: light blue under 50%, yellow under 75%, orange under 90%, red at 90%+.
- The popover still uses the light-blue → yellow → orange → red gradient.

## 1.1 — 2026-09-11

### Menu bar
- Meters are iStat-style vertical capsules (5×18 pt, 1 pt outline). Fill is used % of the inner track, from the bottom.
- Icons are 16.4 pt. Grok and GPT marks are vectors; the Grok slash is the full even-odd logo, not a cropped PNG.
- Percents stay whole numbers when that is accurate, otherwise one decimal (for example `13.6%`).
- Glyphs, percents, and bars share a 20 pt row so marks are not clipped.

### Performance
- Unchanged usage no longer rewrites the extra or the snapshot cache.
- Opening the popover refreshes only if the last attempt is older than 45 seconds.
- Menu-bar drawing skips implicit animations.

### Fixes
- Grok Build glyph was missing half of the mark.
- Popover stays open on the first click and closes on a click outside.
- Settings opens a real window.

## 1.0 — 2026-09-09

First public source drop: menu-bar extra for Grok Build, Grok Bot, Claude, OpenAI, and Cursor. Sign in through the official CLIs or Cursor. MIT license. No Headroom server; credentials stay where those tools put them.
