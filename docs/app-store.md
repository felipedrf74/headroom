# App Store listing: Tokenroom for iPhone and Apple Watch

A draft for App Store Connect. Provider names appear only in the description, as facts, never in the name, subtitle, or keywords. Tokenroom isn't affiliated with any provider.

## App information

| Field | Value |
|---|---|
| Name (30) | Tokenroom: AI Usage & Limits |
| Subtitle (30) | Plan limits, resets & alerts |
| Bundle ID | `app.tokenroom.ios` (Watch: `app.tokenroom.ios.watchkitapp`) |
| SKU | `tokenroom-ios` |
| Primary category | Utilities |
| Secondary category | Developer Tools |
| Price | Free |
| Age rating | 4+ (no restricted content; links open in Safari) |
| Support URL | https://github.com/felipedrf74/headroom/issues |
| Marketing URL | https://github.com/felipedrf74/headroom |
| Privacy policy URL | https://github.com/felipedrf74/headroom/blob/main/PRIVACY.md |
| Copyright | 2026 Felipe Dominguez |

## App privacy

**Data Not Collected.** Tokenroom has no server and no analytics. Readings sync through the user's own iCloud private database, which the developer can't read. API keys stay in the device's Keychain. News requests go to public pages without identifiers.

Export compliance: `ITSAppUsesNonExemptEncryption = NO` (only Apple's HTTPS and CloudKit).

## Promotional text (170)

See how much of your AI plans you've used and when each limit resets, from your Mac, your API keys, or both. Widgets, Live Activity, alerts, and Apple Watch.

## Description

Tokenroom shows how much of your AI coding and chat plans you've used, and when each limit resets, on your iPhone, your Lock Screen, and your wrist.

YOUR PLANS AT A GLANCE
• Used percent, reset times, and pace for every plan, most urgent first
• A week of history for each window, and when you'd run out at the current pace
• Banked resets, credits, balances, and this month's spend

FROM YOUR MAC, OR RIGHT FROM YOUR IPHONE
• Tokenroom for Mac reads the tools you already use (Claude, Codex, Cursor, GitHub Copilot, Grok, Antigravity, Devin, and more) and sends only the readings to your iPhone and Apple Watch through your own iCloud.
• Add API keys on your iPhone for coding plans (Z.ai, Kimi Code, MiniMax, OpenCode Go), pay-as-you-go balances (OpenRouter, DeepSeek, Moonshot, Vercel AI Gateway), and organization spend (OpenAI, Anthropic, xAI). Keys stay in this iPhone's Keychain.

WIDGETS AND LIVE ACTIVITY
• Home Screen and Lock Screen widgets, with a refresh button
• Follow a session, or a nearly spent week, on the Lock Screen and in the Dynamic Island until it resets

ALERTS THAT DON'T NAG
• At 80% and 95%, when a busy window resets, and for banked resets
• Once per event, however many devices notice it
• Quiet hours, with only urgent alerts coming through

NEWS
• New models from the labs you follow
• Official changelogs and announcements, in one list

APPLE WATCH
• Rings for every plan, complications, and a Smart Stack widget when a limit nears its reset
• Works with your iPhone away: it reads your iCloud directly

PRIVATE BY DESIGN
• No account, no Tokenroom server, no analytics
• Logins never leave your Mac, and keys never leave your iPhone. Only usage, reset times, and plan names sync, through your iCloud.
• Try it first with sample data.

Tokenroom isn't affiliated with any of the providers it shows. Their names are used only to identify the services you connect.

## Keywords (100)

`ai,usage,quota,limit,tokens,coding,assistant,meter,reset,pace,widget,api,credits,balance,llm,spend`

## Review notes

Tokenroom works without an account. To look around quickly: Settings › Sample Data turns on realistic sample readings for every screen, widget, and the Live Activity.

Real readings come from two places:

1. **Tokenroom for Mac** (free, open source; https://github.com/felipedrf74/headroom). It reads usage from the AI tools on the Mac and syncs the readings through the user's own iCloud private database. A short video of the Mac-to-iPhone flow: _link to add_.
2. **API keys** the user pastes on the iPhone (for example an OpenRouter key). The app only reads usage and balances with them.

The Watch app reads the same iCloud records. Notifications are optional and come from the user's own devices through iCloud. There are no in-app purchases.

## Screenshots

6.9" iPhone (1320 × 2868), from sample data on the iPhone 18 Pro Max simulator, with the status bar set to 9:41:

1. Usage
2. Detail with pace and a week of history (OpenAI)
3. Home Screen widgets
4. Lock Screen widgets and the Live Activity
5. News
6. API keys

Regenerate them from a debug build:

```bash
xcodebuild build -project Tokenroom.xcodeproj -scheme TokenroomMobile -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/TokenroomSim
```

```bash
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
```

Then for each screen, launch with sample data and a destination, and take the screenshot:

```bash
xcrun simctl launch booted app.tokenroom.ios -sampleMode YES -onboarded YES -TokenroomOpen tokenroom://provider/openai
```

```bash
xcrun simctl io booted screenshot 2-detail.png
```

Other destinations: `-TokenroomGallery home`, `-TokenroomGallery lock`, `-TokenroomOpen tokenroom://news`, and `-TokenroomOpen tokenroom://keys`. Apple Watch screenshots need the watchOS simulator runtime.
