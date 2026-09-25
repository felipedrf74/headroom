---
name: tokenroom-apple
description: >-
  Rules for Tokenroom's iPhone app, widgets, Live Activity, Apple Watch app and
  complications, and the iCloud relay between them and the Mac. Use when editing
  TokenroomMobile, TokenroomWidgets, TokenroomWatch, TokenroomWatchWidgets,
  Shared/Relay, Shared/Widgets, alerts, the News tab, or the project's targets.
---

# Tokenroom for iPhone and Apple Watch

The Mac collects; everything else reads. Macs relay readings through the user's private CloudKit database. The iPhone adds providers it reads with its own API keys. The Watch reads iCloud directly. There is no Tokenroom server. Mac rules (providers, tokens, the menu bar) are in `.grok/skills/tokenroom-macos/SKILL.md`.

## Targets and folders

| Target | Bundle ID | Compiles |
|---|---|---|
| TokenroomMobile (iOS 26) | `app.tokenroom.ios` | `TokenroomMobile/`, Shared Core, Relay, UI, APIKeys, Widgets |
| TokenroomWidgets | `…ios.widgets` | `TokenroomWidgets/`, Shared Core, Relay, UI, APIKeys, Widgets |
| TokenroomWatch (watchOS 26) | `…ios.watchkitapp` | `TokenroomWatch/`, Shared Core, Relay, UI |
| TokenroomWatchWidgets | `…ios.watchkitapp.widgets` | `TokenroomWatchWidgets/`, Shared Core, Relay, UI |

Folders are Xcode synchronized groups: a new file in a folder joins every target that uses the folder. `Shared/Widgets` is iPhone-only (app and widgets). The Watch never compiles `Shared/APIKeys`: no keys on the Watch. The app embeds the widgets (Embed Foundation Extensions) and the Watch app (Embed Watch Content, `$(CONTENTS_FOLDER_PATH)/Watch`). The Watch app embeds its complications.

Settings live in `Config/*.xcconfig` (`Mobile`, `Widgets`, `Watch`, `WatchWidgets`); never add build settings or `DEVELOPMENT_TEAM` to `project.pbxproj`. Info.plist values that must be filled in by the build (`TokenroomCloudContainer`, `TokenroomAppGroup`, `TokenroomKeychainGroup`) are read through `RelayAvailability` and `AppGroup`, which return nil when a build left them empty.

`./scripts/typecheck-shared.sh` checks Shared for macOS, iOS, and watchOS (`Shared/Widgets` for iOS only). Run it after touching Shared.

## Data

- **Relay** (`Shared/Relay/CloudRelay.swift`), zone `Tokenroom`: `Source` (one per collector, one writer each), `History` (`hist-<source>`), `Event` (alerts), `Prefs` (`prefs-alerts`, the iPhone's alert choices). Records hold readings only: never tokens, keys, emails, names, account or organization IDs, or paths. `MobileLogicTests.testNoKeyMaterialReachesAnyRecord` guards this.
- **Merging**: `RelayMerge` picks each provider's reading (live beats stale, then newest). `ReadingAssembler` adds each collector's history and ranks by urgency (`UsageRanking`: limit reached, running out, most used; balances last). The app, iPhone widgets, the Watch, and complications all go through it.
- **iPhone as a collector**: providers read with keys on the iPhone are relayed as its own `Source` (`kind` `iphone`), with `RelayPublishPolicy`'s send rules. Keys stay in the Keychain group `TEAMID.app.tokenroom.shared`, `AfterFirstUnlockThisDeviceOnly`, never synchronized.
- **Cache**: `ReadingCache` (`readings.json`) in the App Group. The app rewrites it on each rebuild but reloads widgets and hands it to the Watch (WatchConnectivity) only when its `materialHash` changes.
- **Widgets and complications** read the cache; when it's over 15 minutes old they read iCloud (and the iPhone's keys, on iPhone) for at most 6 seconds. They never write to iCloud. Timelines add an entry at each reset in the next 8 hours (`rolledOver(at:)`), and reload every 30 minutes.

## Alerts

`AlertRules` and `AlertLedger` (`Shared/Core/Alerts.swift`). IDs are deterministic (`evt-<provider>-<window>-<level>-<reset/10 min>`), so any number of devices seeing one crossing leave one `Event`; the iPhone's `CKQuerySubscription` fires only on creation. First sight and stale readings never alert. Quiet hours are the iPhone's, shared as `Prefs`; urgent alerts (95%, a banked reset expiring within 6 hours) ignore them. Macs send alerts; the iPhone notifies locally only for providers no Mac reports live, because iCloud doesn't notify the device that saved a record. Add fields to `AlertPreferences` with a default in its lenient `init(from:)`.

## Live Activity

`SessionActivityAttributes` follows one window: a session, or a window at 80%+, resetting within 8 hours (`RelayProvider.windowToFollow`). Started from the detail screen, `FollowUsageIntent` (Shortcuts, Action button), or the Control. The app updates it on each rebuild, alerting at 80% and 95%; `staleDate` is the reset; it ends when a new window starts. `.supplementalActivityFamilies([.small])` puts it in the Watch Smart Stack.

## Checking UI without taps

Debug builds take launch arguments (they land in the standard defaults' argument domain):

- `-sampleMode YES -onboarded YES`: sample data, no onboarding.
- `-TokenroomOpen tokenroom://provider/claude` (or `news`, `settings`, `keys`): open a screen.
- `-TokenroomGallery home` or `lock`: every widget size and the Live Activity's Lock Screen view.
- `-TokenroomFollow claude`: start that provider's Live Activity.
- `-newsSection Models|Announcements`.

Build to a fixed DerivedData path so `simctl install` gets the fresh app, then `xcrun simctl launch <device> app.tokenroom.ios -sampleMode YES …` and `xcrun simctl io <device> screenshot`. Opening a URL with `simctl openurl` leaves an "Open in Tokenroom?" prompt; use `-TokenroomOpen` instead. Simulator screenshots don't show the Dynamic Island or Lock Screen, and `BGTaskScheduler` isn't available in the simulator.

## Copy and design

Monograms and tints, never provider logos, on iPhone and Watch. Say "Tokenroom isn't affiliated with…" where a provider is named at length. Errors start with "Couldn't…". Links inside `List` and widgets tint their labels: set `.foregroundStyle(.primary)` on the `Link`.
