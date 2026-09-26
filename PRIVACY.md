# Privacy

Last updated: September 26, 2026. Questions: [open an issue](https://github.com/felipedrf74/tokenroom/issues).

Tokenroom runs on your Mac, iPhone, and Apple Watch. There is no Tokenroom account and no Tokenroom server. Syncing between your devices goes through your own iCloud account.

## What Tokenroom reads

Only for the providers you turn on.

### Logins other tools already keep on your Mac

| Provider | What Tokenroom reads | Where it reads usage |
|---|---|---|
| Grok Build | `~/.grok/auth.json` after `grok login` | `cli-chat-proxy.grok.com` |
| Grok Bot | Cursor’s access token (below), and whether Grok Bot is set up in `~/Library/Application Support/Grok Bot` | `api2.cursor.sh` |
| Claude | Keychain items `Claude Code-credentials…` after `claude login`, or the Claude Code status line if you turn on the bridge | `api.anthropic.com` |
| OpenAI (Codex) | `~/.codex/auth.json` after `codex login` | `chatgpt.com` |
| Cursor | Keychain item `cursor-access-token` first, then Cursor’s `state.vscdb` (also when the Keychain’s token has expired or is refused) | `api2.cursor.sh` |
| GitHub Copilot | `~/.config/github-copilot/apps.json` or `hosts.json`, or the gh CLI’s login (`~/.config/gh/hosts.yml` and its Keychain item `gh:github.com`). When those are missing or refused, a fine-grained token you add (below). | `api.github.com` |
| Antigravity | Runs `agy -p /usage` (agy 1.1.11 or later), which reads its own login. Tokenroom only checks that the Keychain item `gemini` exists; it never reads the token. | through agy |
| Devin | `~/.local/share/devin/credentials.toml`, or the Devin or Windsurf app’s `state.vscdb` | `server.codeium.com` |
| Z.ai, MiniMax | The key in `~/.claude/settings.json` when Claude Code is pointed at them | `api.z.ai` or `open.bigmodel.cn`; `api.minimax.io` or `api.minimaxi.com` |
| Kimi Code | `~/.kimi-code/credentials/kimi-code.json` while its access token is valid, or the key in `~/.claude/settings.json` | `api.kimi.com` or `api.kimi.ai` |
| OpenCode Go | `~/.local/share/opencode/auth.json` | `opencode.ai` |

Those files and Keychain items stay where their tools put them. Tokenroom only reads them: it never refreshes or rewrites another tool’s login, and keeps no copy of it. It also checks when those files last changed, to notice a new sign-in. When Cursor’s or Devin’s database is locked, Tokenroom reads a temporary copy and deletes it right away. When a login expires, run that tool once to renew it. Most of these providers are read from the same endpoints their own apps use, which aren't public APIs and can change; Z.ai, MiniMax, Kimi Code, and OpenCode Go are read as described under Keys you add.

If you turn on the Claude Code status-line bridge, Tokenroom also reads `~/.claude.json` for the list of your Claude Code projects, and each project's `.claude/settings.json` and `.claude/settings.local.json`, only to tell you which projects set their own status line. It never changes project settings.

### Keys you add

For pay-as-you-go and organization providers (OpenRouter, DeepSeek, Moonshot, Vercel AI Gateway, OpenAI, Anthropic, and xAI organization billing), optionally for coding plans, and for GitHub Copilot through GitHub's billing API, you paste an API key or token in Settings. Tokenroom:

- keeps it in this device’s Keychain only, never synced to iCloud or sent to your other devices. Signed Mac builds use the data-protection keychain and move keys saved by an earlier build there.
- shows only its last four characters
- uses it only to read usage, balance, or cost (`openrouter.ai`, `api.deepseek.com`, `api.moonshot.ai` or `.cn`, `ai-gateway.vercel.sh`, `api.openai.com`, `api.anthropic.com`, `management-api.x.ai`, `api.github.com`, and the coding-plan hosts above)

OpenRouter, DeepSeek, Moonshot, Vercel AI Gateway, OpenAI, Anthropic, xAI, GitHub, and MiniMax's Token Plan are read through APIs the provider documents. Z.ai, Kimi Code, OpenCode Go, and MiniMax's older Coding Plan are read from usage endpoints the provider hasn't documented (Z.ai's usage plugin and the Kimi Code CLI call the same ones), so they can change without notice.

For Copilot, the token needs only the "Plan" (read) permission. Tokenroom reads your GitHub username with it, to ask for that account's AI credit usage this month, and keeps neither. The plan you pick next to the token stays with it on the device.

Admin and management keys can change an organization. Create a dedicated key you can revoke. When an xAI key can also change keys or billing, Tokenroom says so before saving it.

## What Tokenroom stores

In `~/Library/Application Support/Tokenroom/`:

- `snapshots.json`: each provider’s used percent, reset times, window names, plan name, and amounts the provider reports (a balance, spend, credits left, or banked resets)
- `checked.json`: when each provider last answered
- `history.json`: a week of hourly used percents, and for balances the amount left each hour, plus when windows reset, for pace, forecasts, and sparklines
- `alerts.json`: the last reading of each provider, the IDs of alerts already sent and the highest level each window's alerts reached, and the full text of alerts waiting for quiet hours to end, so each alert goes out once
- `news.json`, only if you turn on News: model names, prices, the titles, dates, and links of announcements, and which feeds couldn't be read at the last check
- `bridge/`, created when you turn on the Claude Code status-line bridge: the bridge script, the last rate limits Claude Code reported, and your previous status line, so turning the bridge off restores it. The bridge changes only `statusLine` in `~/.claude/settings.json`, leaves the rest of the file as you wrote it, and keeps no copy of it. It doesn't edit a `settings.json` that links elsewhere (dotfiles other Macs may share), or one it can't write; Settings tells you what to change instead. Turning the bridge off removes these files. (Tokenroom 2.0.0 kept copies of the file here; 2.0.1 deletes them when it starts. If yours was a link that 2.0.0 replaced with a file, the copy of the link, which holds only where it pointed, stays until you dismiss Settings' note about it or turn the bridge off.)

In `UserDefaults` for this app: enabled providers, which providers this install has seen, menu bar choices, refresh interval, budgets, alert choices (and the copy of them last shared through iCloud), when old alert records were last deleted, and News choices.

On first launch after the rename from Headroom, Tokenroom copies Headroom’s settings and `snapshots.json` from `app.headroom.mac` and `~/Library/Application Support/Headroom/`.

## iPhone and Apple Watch

When iPhone sync is on, the signed Mac app writes the same readings as `snapshots.json`, plus the hourly history, to a private database in your iCloud account. Only your devices signed in to that account can read it. Turning iPhone sync off stops new writes.

On iPhone, Tokenroom keeps:

- the latest readings and a week of history in its App Group container, so its widgets can show them, plus readings the widgets took for that history (one per provider an hour, for up to a week), when each key provider was last called and any wait it asked for, and when each widget refreshed in the last two days (by size and the provider it leads with)
- its alert ledger, like the Mac's `alerts.json` (the last reading of each provider it reads with a key, alert IDs sent, and the text of alerts waiting for quiet hours), alerts it showed before it could tell iCloud, the alert choices as last shared, and the time zone it last gave them
- API keys you add there in the iPhone’s Keychain, readable only by Tokenroom and its widgets, never synced

When you add keys on the iPhone, it writes its own readings (never the keys) to the same iCloud database, so your other devices can show them. **Settings → Delete Tokenroom Data from iCloud** removes every Tokenroom record there, from all your devices. A Mac with iPhone sync on writes its readings and history again within the hour, and alert choices you changed within half an hour; turn sync off on that Mac first to keep them out.

The records carry readings only: used percents, reset times, window names, plan names, amounts (and whether a limit is a budget you set), a provider's category, and the Mac's pace forecast for each window. They never contain tokens, API keys, email addresses, names, account or organization IDs, or file paths.

Alerts travel the same way. When a window crosses 80% or 95%, resets after heavy use, a banked reset arrives or is about to expire, or a balance or budget runs low, a Mac saves a short alert record (provider, kind, level, and the text you see) that your iPhone shows as a notification. Your alert choices and quiet hours, with the time zone of the device that last changed them (your iPhone updates it when its own time zone changes, so a Mac holds alerts for the same night), are one more record, which the iPhone and your Macs both read and update, so a change on either applies to both. Your iPhone, and Macs while iPhone sync is on, delete alert records older than two weeks.

On Apple Watch, Tokenroom reads the same iCloud records and keeps the latest readings on the Watch, for its app and complications, and when its complications last refreshed. When the iPhone is near, it also hands the Watch its latest readings directly (WatchConnectivity), sooner than iCloud would. The Watch never has your API keys.

## News

News reads public pages only, with no account and nothing about you in the request: OpenRouter's public model list (`openrouter.ai`), and official changelogs and blogs (`code.claude.com`, `openai.com`, `learn.chatgpt.com`, `github.com`, `blog.google`, `antigravity.google`, `github.blog`, `cursor.com`, `docs.devin.ai`, `docs.z.ai`, `openrouter.ai`). It keeps titles, dates, and links on the device and opens articles in your browser. On the iPhone it's the News tab. On the Mac it's off until you turn it on in Settings › News.

## What Tokenroom does not store or send

- access tokens, refresh tokens, or another tool’s login
- email addresses, display names, account IDs, or organization names
- prompts, chats, or file contents
- payment details

Tokenroom never calls sign-in or token hosts and does not send traffic through a third party. Its requests identify themselves as Tokenroom, except two that must look like the tool whose login they use: Claude’s usage call sends Claude Code’s client name, and Devin’s sends the Devin app’s client details with its key.

## Sign out

Turning a provider off, or quitting Tokenroom, stops Tokenroom from reading that login. It does not sign you out of the provider. Removing a key in Settings deletes it from the Keychain.
