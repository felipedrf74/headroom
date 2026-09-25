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
| Cursor | Keychain item `cursor-access-token`, or Cursor’s `state.vscdb` | `api2.cursor.sh` |
| GitHub Copilot | `~/.config/github-copilot/apps.json` or `hosts.json`, or the gh CLI’s login (`~/.config/gh/hosts.yml` and its Keychain item `gh:github.com`) | `api.github.com` |
| Antigravity | Runs `agy -p /usage` (agy 1.1.11 or later), which reads its own login. Tokenroom only checks that the Keychain item `gemini` exists; it never reads the token. | through agy |
| Devin | `~/.local/share/devin/credentials.toml`, or the Devin or Windsurf app’s `state.vscdb` | `server.codeium.com` |
| Z.ai, MiniMax | The key in `~/.claude/settings.json` when Claude Code is pointed at them | `api.z.ai` or `open.bigmodel.cn`; `api.minimax.io` or `api.minimaxi.com` |
| Kimi Code | `~/.kimi-code/credentials/kimi-code.json` while its access token is valid, or the key in `~/.claude/settings.json` | `api.kimi.com` or `api.kimi.ai` |
| OpenCode Go | `~/.local/share/opencode/auth.json` | `opencode.ai` |

Those files and Keychain items stay where their tools put them. Tokenroom only reads them: it never refreshes, rewrites, or copies another tool’s login. When a login expires, run that tool once to renew it.

### Keys you add

For pay-as-you-go and organization providers (OpenRouter, DeepSeek, Moonshot, Vercel AI Gateway, OpenAI, Anthropic, and xAI organization billing), and optionally for coding plans, you paste an API key in Settings. Tokenroom:

- keeps it in this device’s Keychain only, never synced to iCloud or sent to your other devices
- shows only its last four characters
- uses it only to read usage, balance, or cost (`openrouter.ai`, `api.deepseek.com`, `api.moonshot.ai` or `.cn`, `ai-gateway.vercel.sh`, `api.openai.com`, `api.anthropic.com`, `management-api.x.ai`, and the coding-plan hosts above)

Admin and management keys can change an organization. Create a dedicated key you can revoke.

## What Tokenroom stores

In `~/Library/Application Support/Tokenroom/`:

- `snapshots.json`: each provider’s used percent, reset times, window names, plan name, and amounts the provider reports (a balance, spend, credits left, or banked resets)
- `history.json`: a week of hourly used percents, for pace and sparklines
- `bridge/`, only if you turn on the Claude Code status-line bridge: the bridge script, the last rate limits Claude Code reported, and your previous status-line command so turning the bridge off restores it. The bridge also sets the `statusLine` command in `~/.claude/settings.json`, after saving a backup.

In `UserDefaults` for this app: enabled providers, which providers this install has seen, menu bar choices, refresh interval, and budgets.

On first launch after the rename from Headroom, Tokenroom copies Headroom’s settings and `snapshots.json` from `app.headroom.mac` and `~/Library/Application Support/Headroom/`.

## iPhone and Apple Watch

When iPhone sync is on, the signed Mac app writes the same readings as `snapshots.json`, plus the hourly history, to a private database in your iCloud account. Only your devices signed in to that account can read it. Turning iPhone sync off stops new writes.

On iPhone, Tokenroom keeps:

- the latest readings and a week of history in its App Group container, so its widgets can show them
- API keys you add there in the iPhone’s Keychain, readable only by Tokenroom and its widgets, never synced

When you add keys on the iPhone, it writes its own readings (never the keys) to the same iCloud database, so your other devices can show them. **Settings → Delete Tokenroom Data from iCloud** removes every Tokenroom record there, from all your devices.

The records never contain tokens, API keys, email addresses, names, account or organization IDs, or file paths.

## What Tokenroom does not store or send

- access tokens, refresh tokens, or another tool’s login
- email addresses, display names, account IDs, or organization names
- prompts, chats, or file contents
- payment details

Tokenroom never calls sign-in or token hosts and does not send traffic through a third party. Its requests identify themselves as Tokenroom, except two that must look like the tool whose login they use: Claude’s usage call sends Claude Code’s client name, and Devin’s sends the Devin app’s client details with its key.

## Sign out

Turning a provider off, or quitting Tokenroom, stops Tokenroom from reading that login. It does not sign you out of the provider. Removing a key in Settings deletes it from the Keychain.
