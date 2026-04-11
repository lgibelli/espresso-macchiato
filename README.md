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
- **Configurable default duration** for left-click toggle

## Requirements

- macOS 12.0 or later
- Xcode Command Line Tools (`xcode-select --install`)

## Build & Install

```bash
cd Espresso
chmod +x build.sh
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

## Uninstall

1. Quit Espresso from the menu bar
2. Delete `Espresso.app` from Applications
3. If you enabled Launch at Login on older macOS, remove: `~/Library/LaunchAgents/com.nervoussystems.espressomacchiato.plist`
