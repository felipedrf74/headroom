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
| TokenroomMobileTests | `…ios.tests` | `TokenroomMobileTests/`, hosted in the app |

Folders are Xcode synchronized groups: a new file in a folder joins every target that uses the folder. `Shared/Widgets` is iPhone-only (app and widgets). The Watch never compiles `Shared/APIKeys`: no keys on the Watch. Widgets and both Watch targets build with `TOKENROOM_RELAY_READONLY`, which leaves `CloudRelay`'s write methods out. The app embeds the widgets (Embed Foundation Extensions) and the Watch app (Embed Watch Content, `$(CONTENTS_FOLDER_PATH)/Watch`). The Watch app embeds its complications.

Settings live in `Config/*.xcconfig` (`Mobile`, `Widgets`, `Watch`, `WatchWidgets`); never add build settings or `DEVELOPMENT_TEAM` to `project.pbxproj`. Info.plist values that must be filled in by the build (`TokenroomCloudContainer`, `TokenroomAppGroup`, `TokenroomKeychainGroup`) are read through `RelayAvailability` and `AppGroup`, which return nil when a build left them empty.

`./scripts/typecheck-shared.sh` checks Shared for macOS, iOS, and watchOS (`Shared/Widgets` for iOS only). Run it after touching Shared.

## Data

- **Relay** (`Shared/Relay/CloudRelay.swift`), zone `Tokenroom`: `Source` (one per collector, one writer each), `History` (`hist-<source>`), `Event` (alerts, with `alertKey`; an alert the iPhone shows itself is first claimed with `claimAlert`, created only if no device has, under `UsageAlert.shownKey` so no subscription sends it back), `Prefs` (`prefs-alerts`, the alert choices, written by the iPhone and Macs; newest `updatedAt` wins). Envelope windows may carry `pace` (the Mac's measured run-out, which `Pace.evaluate(measured:)` prefers) and providers a `category`. `RelayErrorPolicy` maps CloudKit errors for the Mac and the iPhone alike. Records hold readings only: never tokens, keys, emails, names, account or organization IDs, or paths. `MobileLogicTests.testNoKeyMaterialReachesAnyRecord` guards this. Payloads are plain fields, not `encryptedValues`, by choice: they hold nothing beyond usage numbers, provider and plan names, and reset times; encrypted fields are lost if the account's encryption keys are reset and can't be queried; and with Advanced Data Protection on, the private database is end-to-end encrypted anyway. Moving to encrypted fields later means a new field and a `minReader` bump.
- **Merging**: `RelayMerge` picks each provider's reading (live beats stale, then newest). `ReadingAssembler` adds each collector's history and ranks by urgency (`UsageRanking`: limit reached, running out, most used; balances last). The app, iPhone widgets, the Watch, and complications all go through it.
- **iPhone as a collector**: providers read with keys on the iPhone are relayed as its own `Source` (`kind` `iphone`), with `RelayPublishPolicy`'s send rules. Each of the iPhone's providers shows its newest reading: this launch's, or its own iCloud record's or the App Group cache's (widgets write there too), up to a week old, so a silent-push launch (which doesn't read keys) or a provider resting between calls never drops out, reads "loading", or goes back in time; a key that stopped working shows as that. The list of providers with keys is saved (`keyedProviders`), and the iPhone doesn't publish until the launch has read its keys; saving or removing a key publishes on that refresh. `MobileAppDelegate` owns `MobileStore` and `NewsStore`, so background launches have them. Keys stay in the Keychain group `TEAMID.app.tokenroom.shared`, `AfterFirstUnlockThisDeviceOnly`, never synchronized.
- **Cache**: `ReadingCache` (`readings.json`) in the App Group. The app rewrites it on each rebuild but reloads widgets and hands it to the Watch (WatchConnectivity) only when its `materialHash` changes.
- **Widgets and complications** read the cache; when it's over 15 minutes old they read iCloud (and the iPhone's keys, on iPhone) for at most 6 seconds. They never write to iCloud. `KeyFetchGate` (App Group) shares key-call spacing and 429 waits between the app and widgets. Timelines add an entry at each reset in the next 8 hours (`rolledOver(at:)`) and ask for the next one through `WidgetSchedule`: every 30 minutes while a live window is at 80% or more and resets within 12 hours, hourly otherwise. When iCloud doesn't answer within the widget's 6 seconds, the previous cache's readings from other devices stay; each key provider gets at most 5 of those seconds (`fetchWithinBudget`). Countdowns use `ResetCountdown` (a ticking timer within a day). `WidgetReloadLog` counts timeline builds; Settings › About shows the last 24 hours (aim: under 40).
- **History** (`UsageHistory`): 168 hourly used-% buckets, plus the hourly amount left for balances and the reset times, all optional in older records. `Forecast` turns them into "≈ N days left" and a projected month.

## Alerts

`AlertRules` and `AlertLedger` (`Shared/Core/Alerts.swift`). IDs are deterministic (`evt-<provider>-<window>-<level>-<instance>`: the reset rounded to the hour for windows a day or longer, 10 minutes otherwise, and the day for windows with no reset), so any number of devices seeing one crossing leave one `Event`; the iPhone's `CKQuerySubscription` fires only on creation and filters on `alertKey IN subscribedKeys` (falling back to every event if the field isn't queryable yet). First sight and stale readings never alert. Money windows (usd, cny) raise `.lowBalance` instead of `.threshold`. `process` queues alerts in `pending`; `due` releases urgent ones at once and the rest after quiet hours; `markSent` only after delivery, so an alert iCloud didn't take is retried. Quiet hours and choices are shared as `Prefs`; urgent alerts (95%, a banked reset expiring within 6 hours) ignore quiet hours. Macs send alerts; the iPhone notifies locally only for providers no Mac reports live, because iCloud doesn't notify the device that saved a record. Before notifying, the iPhone claims the alert (`CloudRelay.claimAlert`: creates the record only if no device has, keyed `UsageAlert.shownKey`, which no subscription lists). If a Mac's record is already there, its push already came and the iPhone stays quiet; a Mac saving the same crossing later only updates the record, which notifies nobody. Claims start once the alert subscription filters by kind. An alert shown while iCloud was away is claimed later (`unclaimedAlerts`, up to 18 hours). The ledger processes every provider the iPhone reads, so it stays current; only alerts for providers no Mac reports live (other iPhones don't count) are shown here, the rest stay pending. The subscription falls back to every event only when CloudKit rejects the `alertKey` predicate (`invalidArguments`, `serverRejectedRequest`); other failures are retried on the next refresh. Add fields to `AlertPreferences` with a default in its lenient `init(from:)`.

## Live Activity

`SessionActivityAttributes` follows one window: a session, or a window at 80%+, resetting within 8 hours (`RelayProvider.windowToFollow`). Started from the Next up card, a row's swipe or context menu, the detail screen (`FollowButton`), `FollowUsageIntent` (Shortcuts, Siri via `TokenroomShortcuts`, Action button), or the Control. The app updates it on each rebuild, alerting at 80% and 95%; `staleDate` is the reset; it ends once the reset has passed, even without a newer reading. `.supplementalActivityFamilies([.small])` puts it in the Watch Smart Stack.

## Checking UI without taps

Debug builds take launch arguments (they land in the standard defaults' argument domain):

- `-sampleMode YES -onboarded YES`: sample data, no onboarding.
- `-TokenroomOpen tokenroom://provider/claude` (or `news`, `settings`, `keys`): open a screen.
- `-TokenroomGallery home` or `lock`: every widget size and the Live Activity's Lock Screen view.
- `-TokenroomFollow claude`: start that provider's Live Activity.
- `-newsSection Models|Announcements`.
- Watch: `-sampleMode YES` and `-TokenroomOpen tokenroom://provider/claude`.

Build to a fixed DerivedData path so `simctl install` gets the fresh app, then `xcrun simctl launch <device> app.tokenroom.ios -sampleMode YES …` and `xcrun simctl io <device> screenshot`. Opening a URL with `simctl openurl` leaves an "Open in Tokenroom?" prompt; use `-TokenroomOpen` instead. Simulator screenshots don't show the Dynamic Island or Lock Screen, and `BGTaskScheduler` isn't available in the simulator.

## Copy and design

The Usage tab leads with Next up (the most pressing live metered window: `UsageRing`, pace, a live countdown, Follow) and highlight chips (banked resets, unseen models and updates from `NewsStore`, alerts off). Rows carry a 7-day `Sparkline` and a banked badge. The News tab badges unseen items and marks them "New" for the visit (`markSeen`). Monograms and tints, never provider logos, on iPhone and Watch. Say "Tokenroom isn't affiliated with…" where a provider is named at length. Errors start with "Couldn't…". Links inside `List` and widgets tint their labels: set `.foregroundStyle(.primary)` on the `Link`.

App icons (a "T" of two usage meters, white on orange) are generated: `scripts/make-icons.py` writes `TokenroomMobile/AppIcon.icon` and `TokenroomWatch/AppIcon.icon` (a smaller T, so it clears the round mask). Change the script and rerun it; don't edit the `.icon` files by hand. Check a change in every look with Icon Composer's renderer: `ictool <file>.icon --export-image --output-file out.png --platform iOS --rendition Dark --width 512 --height 512 --scale 1` (renditions Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark; platforms iOS, macOS, watchOS).
