# Espresso ☕

A lightweight macOS menu bar app that keeps your Mac awake — a full-featured replacement for Coca.

## Features

- **Left-click** the menu bar icon to toggle caffeinate on/off
- **Right-click** for the full menu with all options
- **Timer presets**: 5 min, 15 min, 30 min, 1 hour, 2 hours, 5 hours, or indefinite
- **Countdown display** in the menu bar showing time remaining
- **Prevent display sleep** option (keeps screen on, not just system awake)
- **Auto-activate for specific apps** — automatically keeps Mac awake when certain apps are running
- **Launch at Login** support (macOS 13+ uses SMAppService, older uses LaunchAgent)
- **Configurable timer presets** for the right-click "Brew for…" menu (via `defaults write it.salamacchine.espressomacchiato BrewDurations`)
- **Localized** in English, French, German, Italian, Spanish, Portuguese, Japanese, and Simplified Chinese

## Requirements

- macOS 12.0 or later (the Mac App Store build requires macOS 13.0)
- Xcode Command Line Tools (`xcode-select --install`)

## Build & Install

From the repository root:

```bash
./build.sh
```

Then either:
```bash
# Copy to Applications
cp -r build/Espresso.app /Applications/

# Or run directly
open build/Espresso.app
```

On first launch, macOS may block the app. Go to **System Settings → Privacy & Security → Open Anyway**.

## Building for Intel Mac

Edit `build.sh` and uncomment the Universal Binary section to build for both Apple Silicon and Intel.

## How It Works

Espresso talks directly to macOS power management via IOKit's
`IOPMAssertionCreateWithName`, taking out the same assertions that
`/usr/bin/caffeinate` uses internally:

- `kIOPMAssertionTypePreventUserIdleSystemSleep` — keeps the Mac awake while the user is idle
- `kIOPMAssertionTypePreventSystemSleep` — prevents deep system sleep (on AC power)
- `kIOPMAssertionTypePreventUserIdleDisplaySleep` — optional, keeps the display on

Because it uses the public IOKit API instead of spawning a subprocess,
the app works cleanly inside the App Sandbox and never leaves orphan
child processes behind if it crashes or is force-quit.

## Publishing updates (Developer ID build)

The Developer ID build checks for updates and **notifies**; it never downloads or
installs anything by itself. An updater that fetches and runs code makes its feed
a way to run arbitrary software on every user's machine, so it is deliberately
kept out. Instead the app reads a small JSON feed, compares the version, and, if
a newer one exists, adds a *Download Version X…* item to the menu that opens the
download page. Gatekeeper stays in the loop: the user installs a notarised build
the same way they did the first time. The Mac App Store build excludes the
checker via the `MAS` compilation condition and updates through the App Store.

The feed lives at
`https://www.salamacchine.it/apps/espresso/latest.json` (source:
`salamacchine/www/public/apps/espresso/latest.json`) and looks like:

```json
{
  "version": "1.0.2",
  "url": "https://github.com/lgibelli/espresso-macchiato/releases/latest",
  "notes": "See the release notes on GitHub."
}
```

`UpdateChecker` (`Espresso/main.swift:1062`) fetches it at most once a day, and
only ever opens an `https` URL on a host in its allowlist
(`salamacchine.it` or `github.com` and their subdomains). The comparison is
numeric per component, so `1.10.0` sorts above `1.9.0`. Update the feed's
`version` field as part of each release so users are offered the new build.

## Release checklist

1. Bump `CFBundleShortVersionString` in `Espresso/Info.plist` (and
   `CFBundleVersion`, which only the Developer ID build uses), commit and push.
2. Push a `release/<version>` branch (e.g. `release/1.0.3`).
   `.github/workflows/release-signed.yml` runs two jobs from that commit, both
   in the `release` environment:
   - **release** runs `release-dmg.sh` (sign, notarise and staple the app and
     the DMG), attests the DMGs' provenance, and puts
     `Espresso-<version>.dmg` and the versionless `Espresso-latest.dmg` on a
     *draft* GitHub release.
   - **app-store** runs `./submit_mas.sh --upload`: the sandboxed build, signed
     for the store, validated and uploaded to App Store Connect. Its build
     number comes from the version and the run (1.0.3 → `10003.<run>`), so a
     branch can run again. It shows in TestFlight once processed.
3. Read the draft on GitHub and publish it; that is what moves
   `releases/latest/download/Espresso-latest.dmg` to it. Then point
   `latest.json` on the website at the new version.
4. In App Store Connect, pick the build for the version and Submit for Review.

Anyone can check that a DMG came from this repository and commit with
`gh attestation verify Espresso-<version>.dmg --repo lgibelli/espresso-macchiato`.
The secrets and variables the workflow needs are listed at the top of it.
`./submit_mas.sh` also runs locally (validate only; `--upload` to send), with
the settings in `release.env` (see `release.env.example`).

## Uninstall

1. Quit Espresso from the menu bar
2. Delete `Espresso.app` from Applications
3. If you enabled Launch at Login on older macOS, remove: `~/Library/LaunchAgents/it.salamacchine.espressomacchiato.plist`

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See the `LICENSE`
file for the full text.
