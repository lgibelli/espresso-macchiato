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

The Developer ID build is pre-wired for [Sparkle](https://sparkle-project.org)
auto-updates, but the updater is **not active**: Sparkle is not a dependency of
this project, so `canImport(Sparkle)` is false and every `#if !MAS &&
canImport(Sparkle)` block compiles out. The shipped binary links no Sparkle
libraries at all. The Mac App Store build is excluded via the `MAS` compilation
condition and gets its updates from the App Store.

An empty `SUPublicEDKey` does **not** keep the updater inert. Without an EdDSA
key Sparkle still fetches and acts on the appcast, falling back to validating the
update's code signature. What keeps the updater inert today is the absence of the
Sparkle package, nothing else. Adding the package is therefore the step that
arms everything, so do it last.

To switch updates on, in this order:

1. Generate an EdDSA key pair with Sparkle's `generate_keys` tool. The private
   key goes into your login keychain; paste the public key into `SUPublicEDKey`
   in `Espresso/Info.plist`. Without this, anyone able to serve the appcast can
   choose which build users install.
2. Point `SUFeedURL` at a host **you control** and can serve over HTTPS, and
   publish the appcast there. It currently reads
   `https://www.salamacchine.it/apps/espresso/appcast.xml`, which is a
   placeholder path on a domain we own; the feed does not exist yet.
3. Set `SUEnableAutomaticChecks` back to `true`.
4. Only then add the Sparkle package in Xcode:
   File → Add Package Dependencies… → `https://github.com/sparkle-project/Sparkle`.

4. For each release: build with `./notarize.sh`, sign the resulting zip with
   Sparkle's `sign_update`, and add an appcast entry carrying the version,
   download URL, and `sparkle:edSignature`.

## Uninstall

1. Quit Espresso from the menu bar
2. Delete `Espresso.app` from Applications
3. If you enabled Launch at Login on older macOS, remove: `~/Library/LaunchAgents/it.salamacchine.espressomacchiato.plist`

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See the `LICENSE`
file for the full text.
