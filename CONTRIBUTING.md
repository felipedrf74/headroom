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

## Sending a change

Do not push to `main`. That branch is protected.

1. Fork the repository.
2. Work on a branch in your fork.
3. Open a pull request against `main`.
4. Wait. Only the maintainer can approve and merge.

A pull request is a request. It is not a commit on this repo until it is approved.

- Keep the change scoped to one problem.
- Include a screenshot of the extra and the popover when UI changes.
- Confirm a missing credential on one provider does not blank the others.
- Do not put names, emails, user IDs, or tokens in the PR.
