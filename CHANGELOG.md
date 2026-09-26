# Changelog

## 2.0.1 — Unreleased

Fixes from an independent review of 2.0, for Tokenroom for Mac and the next iPhone and Apple Watch update.

### Mac
- Signing in again, or adding or replacing a key, checks that provider at once instead of after its usual spacing (5 minutes for Claude, 15 for Anthropic's cost report), and lifts a "too many requests" wait the old login earned.
- Refreshes asked for while a check is running share one more check instead of overlapping, a slow iCloud no longer holds up the next check, a check cut short by sleep isn't counted as a failure, and waking always checks again. A check made while the Mac was still offline after waking doesn't delay the next one, and setting the clock back no longer stops automatic checks.
- Claude: a "too many requests" answer no longer hides newer status-line readings. Opus, Sonnet, and the other windows only Claude's own call reports stop showing 30 minutes after it, and never past their reset.
- Claude's status line on its own shows the session again when Claude Code reports no weekly window, and the card says a reading came from the status line without dating it by the wrong source.
- The status-line bridge keeps no copies of `~/.claude/settings.json`, and deletes the ones 2.0.0 kept when Tokenroom starts. It keeps a UTF-8 BOM and CRLF line endings, and refuses a file it can't change in place (a second `statusLine`, UTF-16, a trailing comma, a file or folder it can't write) rather than rewriting it. A settings file that links elsewhere, such as dotfiles other Macs share, is left alone: Settings says what to change, and says so when 2.0.0 replaced such a link with a file.
- Cursor and Grok Bot use the token in Cursor's database when the Keychain's has expired or is refused, and after a refusal go to it first until Cursor signs in again. That database is copied only when it can't be read in place.
- Copilot's key sheet fits the window, and replacing a token keeps the plan chosen with it. Copilot keeps one history and one set of alerts whether it's read with the login or a token (the week recorded from a token in 2.0.0 carries on), and isn't labelled unofficial when read with a token.
- ⌘, no longer opens a second Settings window. The Headroom notice offers Launch at Login. One-line rows say why a reading is old, and the week's line is described for VoiceOver.
- An xAI team with only prepaid credits isn't shown as spending them.
- A key saved by a Tokenroom built from source is no longer lost when the signed app moves it into its own keychain.

### iPhone and Apple Watch
- Opening Tokenroom without iCloud (offline, or a CloudKit error) keeps your Mac's readings in the app, the widgets, and on the Watch; signing out of iCloud clears them.
- Opening the app reads your keys again even right after a background update, and a refresh asked for during another runs after it instead of being dropped. An iCloud call that never answers no longer stalls refreshing, and a silent push answers iOS within 25 seconds.
- The Live Activity ends at its reset and shows as reset once it passes, and following again doesn't start a second one, even while an ended one still shows. A reset time the provider moves keeps it going. Its 80% and 95% alerts follow your alert choices and quiet hours.
- A new budget or reference, or a newly saved key, shows at once, also on a reading saved before the app's next check, and the budget field names the balance's currency.
- A saved reading no longer shows faded when a widget read it again after the app's check failed.
- Widgets keep to hard time limits and to WidgetKit's daily budget, share one refresh when several are due, keep other devices' readings when iCloud is slow, and date "Updated … ago" from the readings themselves. Widgets and complications show a balance's amount instead of an empty gauge, sample data is labelled everywhere, and the Watch's rectangular and inline complications open the list. The Watch reloads complications only for changes that matter and doesn't go back to older readings.
- Readings your widgets take count toward the week's history, one an hour for each provider, and none is lost when the app records them.
- Follow on Next up follows the window it shows, a Follow that fails says why, and "Connect your Mac › Done" closes the welcome screen.

### Alerts
- Alerts no longer replace each other when several arrive before you look.
- A balance that runs low across midnight (UTC) alerts once. The low-balance switch works on its own, and a balance with a reference set only on the iPhone alerts from the iPhone.
- Alert choices changed on the Mac and the iPhone no longer undo each other, even two quick changes on the iPhone or different alert levels changed on each, and one changed on a Mac while iCloud was away goes out later. Quiet hours follow the iPhone's time zone when it changes. A Mac on 2.0.0 and an iPhone reading Copilot with a token no longer both alert.
- A held alert says how long is left when it goes out, doesn't follow the 95% one, and respects choices changed since. A provider moving its reset time doesn't repeat alerts, and "Fresh headroom" isn't sent for a reset days ago.
- Your Mac deletes old alert records from iCloud too, and "Delete Tokenroom Data from iCloud" says when it couldn't.

### Pace, history, and forecasts
- A change in a balance or spend reaches the iPhone and Watch without waiting for the half-hourly update, and the Mac's run-out includes its newest reading and goes out once it moves an hour.
- A banked reset used early is marked on the week's chart (and a plan change mid-week isn't), a month's projection stops at the month's end, a small refund isn't a top-up, and a limit reached without a reset time ranks first.

### News
- Posts from different products with the same title stay separate. A feed past its size limit stops downloading there and says it couldn't be read, and a failed check waits an hour. New feeds and labs start on, turning News on doesn't mark everything new, and links open web pages only.

### Privacy
- PRIVACY.md says which providers are read through documented APIs, how the Watch gets its readings, when a file is copied, and everything the iPhone keeps. The release's checksum file names the zip without a local path.

## 2.0.0 — 2026-09-25

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
