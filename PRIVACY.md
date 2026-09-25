# Privacy

Tokenroom runs on your Mac. There is no Tokenroom account and no Tokenroom server.

## What Tokenroom reads

Only to fetch the usage meters you turned on:

| Provider | Session it reuses |
|---|---|
| Grok Build | `~/.grok/auth.json` after `grok login` |
| Grok Bot | Cursor’s local `state.vscdb` access token |
| Claude | Keychain item `Claude Code-credentials` after `claude login` |
| OpenAI | `~/.codex/auth.json` after `codex login` |
| Cursor | Cursor’s local `state.vscdb` access token |

Those files stay where the official tools put them. Tokenroom only reads them: it never refreshes, rewrites, or copies tokens, and it keeps no emails, names, or user IDs in its own storage or logs.

## What Tokenroom stores

In `~/Library/Application Support/Tokenroom/snapshots.json`:

- provider name
- used percent
- reset time
- window labels (`Weekly`, `Session`, `This cycle`)
- plan name when the provider reports one (for example `SuperGrok Heavy`)

In standard `UserDefaults` for this app: which providers are enabled, which providers this install has already seen, menu style, and refresh interval.

On first launch after the rename from Headroom, Tokenroom copies Headroom’s settings and `snapshots.json` (the same fields as above) from `app.headroom.mac` and `~/Library/Application Support/Headroom/`.

Launch-at-login is the system login item for Tokenroom.

## What Tokenroom does not store

- access tokens, refresh tokens, API keys
- email addresses, display names, profile photos
- prompts, chats, or file contents
- billing amounts or payment details

Network calls go only to the usage endpoint of the provider you signed in with (`cli-chat-proxy.grok.com`, `api.anthropic.com`, `chatgpt.com`, `api2.cursor.sh`). Tokenroom never calls sign-in or token hosts and does not send traffic through a third party.

## Sign out

Turning a provider off, or quitting Tokenroom, stops Tokenroom from reading that session. It does not log you out of Grok, Claude, Codex, or Cursor.
