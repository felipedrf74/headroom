<p align="center">
  <img src="docs/images/icon.png" width="96" height="96" alt="Tokenroom icon">
</p>

<h1 align="center">Tokenroom</h1>

<p align="center">
  <strong>Subscription quota in the macOS menu bar.</strong><br>
  Claude, Codex, Grok, Cursor, Copilot, and 14 more: used percent and reset time on your Mac, iPhone, and Apple Watch.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/privacy-local--first-5a9e6f?style=flat-square" alt="Local-first">
  <img src="https://img.shields.io/badge/license-MIT-4b6bfb?style=flat-square" alt="MIT">
</p>

<p align="center">
  <img src="docs/images/hero.png" width="920" alt="Tokenroom menu bar extra and popover">
</p>

Tokenroom is a menu-bar extra. It does not live in the Dock. It reuses logins you already have. For pay-as-you-go and organization billing you can add an API key, which stays in your Keychain. It does not keep names, emails, or tokens on disk.

Tokenroom was called Headroom until 2.0. On first launch it brings over Headroom’s settings and last readings; quit Headroom and move it to the Trash afterwards.

<p align="center">
  <img src="docs/images/menubar.png" width="920" alt="Tokenroom in the macOS menu bar">
</p>

## Glance first

The extra shows **used %** for every provider you turned on.

| Provider | What you see | Connect with |
| --- | --- | --- |
| Grok Build | Weekly pool | `grok login` |
| Grok Bot | Weekly pool | Grok Bot app |
| Claude | 7-day window | `claude login` |
| OpenAI (Codex) | Weekly window | `codex login` |
| Cursor | Billing cycle | Cursor app |
| GitHub Copilot | Monthly requests | `gh auth login` or a Copilot editor extension |
| Antigravity | Gemini weekly | Antigravity, and `agy` 1.1.11 or later |
| Devin | Weekly quota | Devin app |
| Z.ai, MiniMax | Weekly or 5-hour | The key in Claude Code’s settings, or add one |
| Kimi Code | Weekly | `kimi` login, or add a key |
| OpenCode Go | Weekly | OpenCode’s login, or add a key |
| OpenRouter | Key limit, or spend | API key |
| DeepSeek, Moonshot, Vercel AI Gateway | Balance | API key |
| OpenAI, Anthropic, and xAI organizations | This month’s spend | Admin key |

Click the extra for reset times, session windows, and sign-in. Claude’s 5-hour session is in the popover only. Cursor is labeled **This cycle**, never Weekly.

<p align="center">
  <img src="docs/images/popover.png" width="360" alt="Tokenroom popover with five provider cards">
</p>

## Why it exists

Each of those tools already knows how much quota you have left. None of them put it next to the clock. Tokenroom does, as tiny percents or iStat-style meters, then gets out of the way.

- **Local-first.** No Tokenroom account, no Tokenroom server, no telemetry.
- **Your logins.** Sessions stay where each tool keeps them. Tokenroom only reads them.
- **Independent meters.** One provider failing never blanks the others.
- **Three looks.** Percents, vertical used-bars, or only the highest. Refresh every 5, 10, 15, or 30 minutes. Launch at login if you want.

Numbers in the screenshots are sample data.

## iPhone and Apple Watch

Tokenroom for iPhone shows the same meters, pace, and a week of history. They come from your Mac through your own iCloud. The iPhone also reads coding-plan, pay-as-you-go, and organization providers itself, with keys you add there. It adds:

- Home Screen and Lock Screen widgets
- a Live Activity that follows a session, or a nearly spent week, to its reset
- alerts at 80% and 95%, when a busy window resets, and for banked resets. Each goes out once across your devices and respects quiet hours.
- News: new models from the labs you follow, and official changelogs

The Apple Watch app and its complications read the same iCloud records, so they keep working with the iPhone away. To send your Mac's readings, turn on **Settings → iPhone & Watch** in the signed download of Tokenroom for Mac. A copy you build and sign yourself can't use iCloud.

Tokenroom for iPhone and Apple Watch is on its way to the App Store. It has a sample mode for looking around first.

## Install

There is no notarized download yet. Build on the Mac that will run it:

```bash
git clone https://github.com/felipedrf74/headroom.git tokenroom
cd tokenroom
./scripts/build.sh
open /Applications/Tokenroom.app
```

Xcode 27 is preferred. Command Line Tools are enough for the `swiftc` fallback.

After opening, look at the **right side of the menu bar**. Opening the app again from Finder re-shows the popover.

The build is ad-hoc signed and **not sandboxed** — it has to read CLI credential files. If macOS blocks the first launch: **System Settings → Privacy & Security → Open Anyway**.

## Sign in

1. Click Tokenroom in the menu bar.
2. On a provider that isn’t connected, click **Sign In**, or **Add Key** for key-based providers.
3. Finish login in the browser, Terminal, or app that opens.
4. Tokenroom picks up the session and shows usage.

The same controls live in **Settings → Providers**. Turning a provider off hides it from Tokenroom; it does not log you out of that provider.

Tokenroom only reads sessions. It never refreshes or rewrites another tool’s tokens. Claude and Grok sessions expire after a few hours; until you use `claude` or `grok` again (which refreshes them), Tokenroom keeps showing the last reading, faded, for up to a day.

## Privacy

Tokenroom caches readings (percentages, reset times, window labels, and any balance or spend) and a week of hourly history in `~/Library/Application Support/Tokenroom/`. See [PRIVACY.md](PRIVACY.md). What changed between releases: [CHANGELOG.md](CHANGELOG.md).

## Settings

Providers and keys, menu bar (Percents, Meters, or Highest, and which providers show), refresh interval, iPhone & Watch sync, and launch at login. Bundle ID is `app.tokenroom.mac`.

## Develop

```bash
./scripts/build.sh
```

DerivedData is forced to `~/Library/Developer/Xcode/DerivedData/Tokenroom`. UI, tokens, and provider contracts: [`.grok/skills/tokenroom-macos/SKILL.md`](.grok/skills/tokenroom-macos/SKILL.md).

Build settings live in `Config/*.xcconfig`. Builds are ad-hoc signed by default. To sign with your own team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and set `TOKENROOM_TEAM_ID` and `TOKENROOM_MAC_SIGNING = team`. `TOKENROOM_FORCE_SWIFTC=1 ./scripts/build.sh` exercises the Command Line Tools fallback.

`main` is protected. Send a change as a pull request from a fork; the maintainer has to approve it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Tokenroom is not affiliated with xAI, Anthropic, OpenAI, or Anysphere.
