# Contributing

Thanks for helping with Headroom.

## What to change

Glance first. Keep the extra narrow, Apple-native, and free of identity data.

- UI, tokens, meters, and provider adapters: read `.grok/skills/headroom-macos/SKILL.md`.
- Copy starts with the fact. Errors start with “Couldn't…”.
- Do not put names, emails, user IDs, or tokens in source, fixtures, logs, or `snapshots.json`.

## Build

```bash
./scripts/build.sh
open /Applications/Headroom.app
```

Xcode 27 is preferred. Command Line Tools are enough for the `swiftc` fallback in `scripts/build.sh`. DerivedData stays at `~/Library/Developer/Xcode/DerivedData/Headroom`.

There is no Dock icon. After launch, look at the right side of the menu bar.

## Tests

Parser and sign-in tests live in `HeadroomTests`. Run them from Xcode when it is installed.

## Pull requests

- Keep the change scoped to one problem.
- Include a screenshot of the extra and the popover when UI changes.
- Confirm a missing credential on one provider does not blank the others.
