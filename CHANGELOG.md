# Changelog

## 2.0.0 — Unreleased

Headroom is now **Tokenroom**, on the Mac and, new, on iPhone and Apple Watch. On first launch Tokenroom brings over Headroom’s settings and last readings, and offers to quit Headroom.

A new icon: a “T” made of two usage meters, white on orange. On iPhone, Apple Watch, and macOS 26 or later it's drawn in Liquid Glass, with dark, tinted, and clear looks.

### iPhone and Apple Watch
- **Tokenroom for iPhone** shows your Mac's readings through your own iCloud, and reads coding plans, pay-as-you-go balances, and organization spend itself with keys you add there. Keys stay in the iPhone's Keychain.
- **Next up**: the most pressing limit, with its pace, a live countdown to the reset, and Follow on Lock Screen. Chips below it count banked resets, new models, and updates.
- **Widgets** for the Home Screen and Lock Screen, with countdowns that tick without reloads, and a refresh button.
- **Live Activity** that follows a session, or a nearly spent week, on the Lock Screen and in the Dynamic Island until it resets. Start it from the app, Control Center, the Action button, or Siri.
- **Apple Watch** app, complications, and a Smart Stack widget for a limit near its reset or past 80%. The Watch reads iCloud directly, so it works with the iPhone away.
- **Sample data** to look around first.

### Pace, history, and forecasts
- A tick on every meter marks an even pace; "Ahead of pace · runs out Sat 11:37" shows when you'd hit a limit before it resets. The Mac measures pace from its frequent readings and sends it along, so the iPhone and Watch show the same forecast.
- A week of hourly history for every window, with the resets marked.
- Balances say how many days they last at this week's rate; organization spend says where the month is heading.

### Alerts
- At 80% and 95%, when a window that reached 80% resets, when a banked reset arrives or is about to expire, and when a balance or budget runs low. They go to your iPhone through iCloud once per event, however many Macs see it, and still once when your iPhone reads the same provider with its own key.
- Quiet hours hold the alerts that can wait until morning; 95% and a banked reset about to expire come through.
- Alert choices are shared: change them on the Mac (Settings › Alerts) or the iPhone, and both follow. The iPhone only gets notified for the kinds you turned on.
- An alert iCloud didn't take is tried again, instead of lost.

### News
- New models from the labs you follow, from OpenRouter's public list, and official changelogs and blogs from Claude Code, Codex and ChatGPT, Gemini and Antigravity, GitHub Copilot, Cursor, Devin, Z.ai, Kimi Code, MiniMax, and OpenRouter.
- On the Mac it's off until you turn it on, and opens in its own window.

### New providers
- **GitHub Copilot**, with the login Copilot’s editor extensions or the gh CLI already keep, or a fine-grained token for GitHub's billing API, which also works on iPhone. Copilot counts AI credits, GitHub's name for premium requests since June.
- **Antigravity**, through `agy` 1.1.11 or later.
- **Devin** (formerly Windsurf).
- **Coding plans:** Z.ai, Kimi Code, MiniMax, and OpenCode Go. Tokenroom uses the key Claude Code, the kimi CLI, or OpenCode already has, or one you add.
- **Pay as you go:** OpenRouter, DeepSeek, Moonshot, and Vercel AI Gateway, with an API key you add. A reference amount, in the balance's own currency, turns a balance into a meter.
- **Organization billing:** this month’s OpenAI, Anthropic, and xAI spend with an admin or management key, against a monthly budget. These never turn on by themselves, and an xAI key that can also change billing or keys gets a warning.

API keys stay in the Mac’s Keychain, in the data-protection keychain on signed builds; only the last four characters are shown.

### Richer readings
- Codex: plan, credits, spend limit, named limits, and banked resets.
- Claude: per-model caps and extra usage. An optional Claude Code status-line bridge keeps Claude’s meters current when the direct read can’t; a fresh status-line reading saves a call, and the other windows stay when the direct read fails. It edits only the status line in `~/.claude/settings.json`, keeping the rest of the file as you wrote it, and points out projects whose own status line replaces it.
- Cursor 3.9 and later: the login in the Keychain comes first. Grok: your plan’s name.

### Mac popover and settings
- Click a provider for every window, a week of history, pace, forecasts, and banked resets. With more than five providers connected, each takes one line.
- A footer strip counts banked resets, new models, and updates.
- Settings has General, Providers (connected, detected on this Mac, available, and organization billing), API Keys, Alerts, News, Menu Bar, and iPhone & Watch tabs.
- Any provider can be left out of the menu bar, and the **Highest** style shows only the most-used meter.
- Providers read from their apps' own endpoints are labeled unofficial.

### Changes
- Tokenroom only reads other tools’ sessions. It no longer refreshes Claude or Grok tokens or writes them back, so it can’t break a Claude Code or Grok CLI session. An expired session keeps its last reading, faded, for up to a day, even across a relaunch.
- Providers that answer “too many requests” are left alone until their Retry-After passes. Spacing between checks counts from the last attempt, so failures don't bring the next call closer.
- Balances read "$12.40 left" everywhere.
- Grok Bot off a Cursor plan says so instead of asking you to sign in.
- Requests identify themselves as Tokenroom, except where a provider only answers its own client (Claude, Devin).

### Fixes
- The app could freeze while waiting on the Keychain during Claude sign-in.
- Keychain, file, and database reads no longer run on the main thread, including the check for new providers at launch.
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
