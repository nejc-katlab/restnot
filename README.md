# RestNot

**Process-aware sleep prevention for macOS** — automatically keeps your Mac awake while AI agents, builds, SSH sessions, and long-running tasks are active.

Unlike `caffeinate`, Amphetamine, or Lungo, RestNot requires **zero manual interaction**. It watches for running processes and prevents sleep only while they need it — then releases automatically when they finish.

## The Problem

macOS aggressively sleeps when the lid closes or after idle timeout. If you're running:

- **AI coding agents** (Claude Code, Copilot, Codex) executing multi-step tasks
- **Remote control sessions** controlled from your phone or browser
- **SSH connections**, file transfers (`rsync`, `scp`)
- **Long builds** (`cargo build`, `xcodebuild`, `make`, Docker)

...and you close your lid or walk away, macOS kills your work. Existing tools require you to **remember to toggle them on**. If you forget, hours of progress are lost.

## How It Works

RestNot runs as a lightweight menu bar app. Every 5 seconds, it scans running processes against a watchlist. When a match is found, it creates a macOS power assertion (`IOPMAssertion`) to prevent system sleep. When all watched processes end, it waits a 30-second grace period, then releases the hold.

```
Process detected → Sleep prevented → Process ends → Grace period → Sleep re-enabled
```

No configuration needed. No manual toggling. No lost work.

## Default Watchlist

RestNot ships with built-in rules for common developer tools:

| Process | Match | Description |
|---------|-------|-------------|
| `claude` | Any instance | Claude Code (AI coding agent) |
| `ssh` | Any instance | SSH connections |
| `rsync` | Any instance | File synchronization |
| `scp` | Any instance | Secure file copy |
| `cargo` | `build`, `test`, `run` | Rust builds |
| `xcodebuild` | Any instance | Xcode builds |
| `make` | Any instance | Make builds |
| `docker` | `run`, `compose`, `build` | Docker containers |

## Installation

### Build from source

Requires Xcode 15+ and macOS 13+.

```bash
git clone https://github.com/Mythic-Studio/restnot.git
cd restnot
```

**Option A — Xcode:**

Open `RestNot.xcodeproj` in Xcode, select your signing team, and build.

**Option B — Command line:**

```bash
xcodebuild -project RestNot.xcodeproj -scheme RestNot -configuration Release build
```

The built app will be in `DerivedData/RestNot-*/Build/Products/Release/RestNot.app`.

### Code signing

The project uses ad-hoc signing by default. To sign with your Apple Developer account:

1. Copy `Configs/Local.xcconfig.example` to `Configs/Local.xcconfig`
2. Set your team ID:
   ```
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   ```

`Local.xcconfig` is gitignored and will not be committed.

## Menu Bar

RestNot lives in your menu bar with two states:

| State | Icon | Meaning |
|-------|------|---------|
| Idle | 🌙 | No watched processes running |
| Active | 🌙 (filled) | Preventing sleep — processes listed in menu |

Click the icon to see which processes are active and how long they've been running. You can pause and resume RestNot from the menu.

## Privacy

RestNot reads **only** process names, PIDs, and command-line flags. It **never** reads:

- Terminal output or screen contents
- File contents or keystrokes
- Clipboard data
- Network traffic

The app has **no network access** — it physically cannot send data anywhere. Sensitive arguments like prompt content (`claude -p "..."`) are redacted in the UI to `claude -p "…"`.

The core scanning logic is ~200 lines of Swift, fully auditable in [`RestNot/ProcessWatcher.swift`](RestNot/ProcessWatcher.swift).

## How It Compares

| Feature | RestNot | `caffeinate` | Amphetamine | Lungo |
|---------|---------|-------------|-------------|-------|
| Process-aware | Yes | No | No | No |
| Automatic start/stop | Yes | No | No | No |
| No manual toggling | Yes | No | No | No |
| Grace period | Yes | No | No | No |
| Zero config | Yes | No | No | No |
| Open source | Yes | Yes (system) | No | No |
| Menu bar status | Yes | No | Yes | Yes |
| Binary size | ~56KB | system | ~15MB | ~5MB |

## Tech Stack

- **Language:** Swift
- **UI:** AppKit (native macOS, no Electron/web frameworks)
- **Sleep API:** IOKit `IOPMAssertionCreateWithName`
- **Process scanning:** `sysctl` KERN_PROC / KERN_PROCARGS2 (no special permissions needed)
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Roadmap

- [ ] Configurable watchlist via settings UI
- [ ] Native notifications on sleep prevent/release
- [ ] Launch at login
- [ ] CLI companion (`restnot status`, `restnot wrap -- <command>`)
- [ ] Battery safety (release on low battery)
- [ ] Session history (opt-in)
- [ ] Homebrew formula

## Contributing

Contributions are welcome. The codebase is intentionally small — the entire app is 6 Swift files.

## License

[MIT](LICENSE) — Mythic Studio, 2026
