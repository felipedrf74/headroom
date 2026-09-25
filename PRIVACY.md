# Privacy

Tokenroom runs on your Mac and iPhone. There is no Tokenroom account and no Tokenroom server. Syncing between your devices goes through your own iCloud account.

## What Tokenroom reads

Only for the providers you turn on.

### Logins other tools already keep on your Mac

| Provider | What Tokenroom reads | Where it reads usage |
|---|---|---|
| Grok Build | `~/.grok/auth.json` after `grok login` | `cli-chat-proxy.grok.com` |
| Grok Bot | Cursor’s access token (below), and whether Grok Bot is set up in `~/Library/Application Support/Grok Bot` | `api2.cursor.sh` |
| Claude | Keychain items `Claude Code-credentials…` after `claude login`, or the Claude Code status line if you turn on the bridge | `api.anthropic.com` |
| OpenAI (Codex) | `~/.codex/auth.json` after `codex login` | `chatgpt.com` |
| Cursor | Keychain item `cursor-access-token` first, then Cursor’s `state.vscdb` | `api2.cursor.sh` |
| GitHub Copilot | `~/.config/github-copilot/apps.json` or `hosts.json`, or the gh CLI’s login (`~/.config/gh/hosts.yml` and its Keychain item `gh:github.com`). When those are missing or refused, a fine-grained token you add (below). | `api.github.com` |
| Antigravity | Runs `agy -p /usage` (agy 1.1.11 or later), which reads its own login. Tokenroom only checks that the Keychain item `gemini` exists; it never reads the token. | through agy |
| Devin | `~/.local/share/devin/credentials.toml`, or the Devin or Windsurf app’s `state.vscdb` | `server.codeium.com` |
| Z.ai, MiniMax | The key in `~/.claude/settings.json` when Claude Code is pointed at them | `api.z.ai` or `open.bigmodel.cn`; `api.minimax.io` or `api.minimaxi.com` |
| Kimi Code | `~/.kimi-code/credentials/kimi-code.json` while its access token is valid, or the key in `~/.claude/settings.json` | `api.kimi.com` or `api.kimi.ai` |
| OpenCode Go | `~/.local/share/opencode/auth.json` | `opencode.ai` |

Those files and Keychain items stay where their tools put them. Tokenroom only reads them: it never refreshes, rewrites, or copies another tool’s login. When a login expires, run that tool once to renew it. These providers are read from the same endpoints their own apps use, which aren't public APIs and can change.

If you turn on the Claude Code status-line bridge, Tokenroom also reads `~/.claude.json` for the list of your Claude Code projects, and each project's `.claude/settings.json` and `.claude/settings.local.json`, only to tell you which projects set their own status line. It never changes project settings.

### Keys you add

For pay-as-you-go and organization providers (OpenRouter, DeepSeek, Moonshot, Vercel AI Gateway, OpenAI, Anthropic, and xAI organization billing), optionally for coding plans, and for GitHub Copilot through GitHub's billing API, you paste an API key or token in Settings. Tokenroom:

- keeps it in this device’s Keychain only, never synced to iCloud or sent to your other devices. Signed Mac builds use the data-protection keychain and move keys saved by an earlier build there.
- shows only its last four characters
- uses it only to read usage, balance, or cost (`openrouter.ai`, `api.deepseek.com`, `api.moonshot.ai` or `.cn`, `ai-gateway.vercel.sh`, `api.openai.com`, `api.anthropic.com`, `management-api.x.ai`, `api.github.com`, and the coding-plan hosts above)

For Copilot, the token needs only the "Plan" (read) permission. Tokenroom reads your GitHub username with it, to ask for that account's AI credit usage this month, and keeps neither. The plan you pick next to the token stays with it on the device.

Admin and management keys can change an organization. Create a dedicated key you can revoke. When an xAI key can also change keys or billing, Tokenroom says so before saving it.

## What Tokenroom stores

In `~/Library/Application Support/Tokenroom/`:

- `snapshots.json`: each provider’s used percent, reset times, window names, plan name, and amounts the provider reports (a balance, spend, credits left, or banked resets)
- `checked.json`: when each provider last answered
- `history.json`: a week of hourly used percents, and for balances the amount left each hour, plus when windows reset, for pace, forecasts, and sparklines
- `alerts.json`: the last reading of each provider and the alert IDs already sent or waiting for quiet hours to end, so each alert goes out once
- `news.json`, only if you turn on News: model names, prices, and the titles, dates, and links of announcements
- `bridge/`, only if you turn on the Claude Code status-line bridge: the bridge script, the last rate limits Claude Code reported, your previous status-line command so turning the bridge off restores it, a copy of `~/.claude/settings.json` as it was before the bridge first changed it, and up to five later backups. The bridge sets only the `statusLine` command in that file, after a backup, and leaves the rest of it as you wrote it.

In `UserDefaults` for this app: enabled providers, which providers this install has seen, menu bar choices, refresh interval, budgets, alert choices, and News choices.

On first launch after the rename from Headroom, Tokenroom copies Headroom’s settings and `snapshots.json` from `app.headroom.mac` and `~/Library/Application Support/Headroom/`.

## iPhone and Apple Watch

When iPhone sync is on, the signed Mac app writes the same readings as `snapshots.json`, plus the hourly history, to a private database in your iCloud account. Only your devices signed in to that account can read it. Turning iPhone sync off stops new writes.

On iPhone, Tokenroom keeps:

- the latest readings and a week of history in its App Group container, so its widgets can show them, plus when each key provider was last called and how many times the widgets refreshed in the last two days
- API keys you add there in the iPhone’s Keychain, readable only by Tokenroom and its widgets, never synced

When you add keys on the iPhone, it writes its own readings (never the keys) to the same iCloud database, so your other devices can show them. **Settings → Delete Tokenroom Data from iCloud** removes every Tokenroom record there, from all your devices.

The records carry readings only: used percents, reset times, window names, plan names, amounts, a provider's category, and the Mac's pace forecast for each window. They never contain tokens, API keys, email addresses, names, account or organization IDs, or file paths.

Alerts travel the same way. When a window crosses 80% or 95%, resets after heavy use, a banked reset arrives or is about to expire, or a balance or budget runs low, a Mac saves a short alert record (provider, kind, level, and the text you see) that your iPhone shows as a notification. Your alert choices and quiet hours are one more record, which the iPhone and your Macs both read and update, so a change on either applies to both. Alert records are deleted after two weeks.

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
