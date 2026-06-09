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

RestNot runs as a lightweight menu bar app and keeps the Mac awake from two signals:

1. **Claude Code hooks (primary).** A tiny hook script fires on every Claude Code event and writes a short-lived *lease* file. RestNot holds a sleep assertion while any lease is unexpired. This tracks when an agent is *actually working* — not just whether the `claude` process is running (it runs all the time, even idle, which would otherwise keep your Mac awake all night).
2. **Process watchlist (fallback).** Every 5 seconds it also scans for long-running work where no hook fires — builds, SSH, file transfers.

When either signal is active it creates a macOS power assertion (`IOPMAssertion`). When everything goes idle, it waits a 30-second grace period, then releases the hold and the Mac follows its normal sleep settings.

RestNot uses `PreventSystemSleep`, so it keeps the Mac awake **even with the lid closed** — on AC power, or on battery with an external display attached (clamshell mode). On battery with no external display, macOS overrides all apps and sleeps on lid-close; that's a hardware-level policy RestNot can't bypass.

```
Agent works (hook) ─┐
                    ├─→ Sleep prevented → Idle → Grace period → Sleep re-enabled
Build runs (process)┘
```

### Claude Code integration

Claude detection is driven by hooks so the Mac stays awake **only while an agent is actively working** and sleeps once a turn finishes. The hooks ship as a Claude Code plugin — install it with two commands, no config editing:

```
/plugin marketplace add nejc-katlab/restnot
/plugin install restnot@restnot
```

That's it — the hooks register automatically (and merge with any hooks you already have). The plugin bundles the lease script, so there's nothing else to copy.

> **Manual alternative (no plugin):** copy `hooks/restnot-hook.sh` somewhere executable and merge [`hooks/settings.example.json`](hooks/settings.example.json) into your `~/.claude/settings.json` `hooks` block.

**How the lease works:** "busy" events (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`) push the lease expiry to `now + 15 min`; `Stop` and `SessionEnd` remove it. The 15-minute TTL (override with `RESTNOT_BUSY_TTL`) is a safety net — if Claude Code crashes mid-turn and never fires `Stop`, the lease still expires, so the Mac can never get stuck awake. Each session gets its own lease, so concurrent sessions are tracked independently.

### Other agents (Codex, Gemini, Cursor — agent-agnostic)

RestNot's macOS side only watches the lease directory, so **any** agentic CLI can drive it. A generic adapter bridges each tool's hook system to the lease CLI:

```
adapters/restnot-agent-hook.sh <tool> busy   # on turn-start / tool-use
adapters/restnot-agent-hook.sh <tool> stop   # on turn-end / session-end
```

Ready-made configs ship under `adapters/`:

| Tool | Config to merge | Events used |
|------|-----------------|-------------|
| Codex CLI | [`adapters/codex/hooks.json`](adapters/codex/hooks.json) | UserPromptSubmit, PreToolUse, PostToolUse, Stop |
| Gemini CLI | [`adapters/gemini/settings.json`](adapters/gemini/settings.json) | BeforeAgent, BeforeTool, AfterAgent, SessionEnd |
| Cursor | [`adapters/cursor/hooks.json`](adapters/cursor/hooks.json) | beforeSubmitPrompt, beforeShellExecution, stop, sessionEnd |

Copy `bin/restnot` and `adapters/` to `~/.restnot/` and merge the relevant config into the tool's hook settings. Each session gets its own lease keyed by `<tool>-<session_id>`, so concurrent sessions across different tools are tracked independently.

### Lease CLI

`bin/restnot` is a standalone lease manager — use it from anything (a script, a cron job, your own tooling):

```bash
restnot lease <id> [--ttl 900]   # hold a lease (default TTL 900s)
restnot release <id>             # drop it
restnot list                     # show active leases
```

## Process Watchlist

For long-running work that doesn't emit hooks, RestNot ships with built-in rules:

| Process | Match | Description |
|---------|-------|-------------|
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
git clone https://github.com/nejc-katlab/restnot.git
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
| Active | 🌙 (green) | Preventing sleep — agents/processes listed in menu |

When sleep is being prevented the icon turns **green** so you can tell at a glance that an agent or process is registered. Click the icon to see which agents/processes are active and how long they've been running. You can pause and resume RestNot from the menu, and toggle **Open at Login** — enabled automatically on first launch so it's a one-time install.

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

- [x] Launch at login
- [x] CLI companion (`restnot lease/release/list`)
- [x] Agent-agnostic adapters (Codex, Gemini, Cursor)
- [ ] Configurable watchlist via settings UI
- [ ] Native notifications on sleep prevent/release
- [ ] Battery safety (release on low battery)
- [ ] Session history (opt-in)
- [ ] Homebrew formula

## Contributing

Contributions are welcome. The codebase is intentionally small — the entire app is 6 Swift files.

## License

[MIT](LICENSE) — Mythic Studio, 2026
