# RestNot — Implementation Plan

> **A process-aware sleep prevention app for macOS (with future Windows/Linux support)**
>
> RestNot automatically keeps your Mac awake when AI agents, remote sessions, builds, or long-running tasks are active — and releases the hold the moment they finish.

---

## 1. Problem Statement

Modern developer workflows involve long-running background processes that must not be interrupted by system sleep:

- **AI coding agents** (Claude Code, GitHub Copilot CLI, Codex, Gemini CLI) running multi-step tasks
- **Claude Code Remote Control** sessions controlled from a phone or browser
- **Headless AI sessions** (`claude -p "..."`) executing overnight
- **SSH sessions**, file transfers (`rsync`, `scp`), builds, Docker containers

macOS aggressively sleeps when the lid closes or after idle timeout. Existing tools (Amphetamine, Lungo, `caffeinate`) require **manual activation** — users must remember to toggle them before closing the lid. If they forget, hours of agent work are lost.

**RestNot solves this by being process-aware.** It watches for configurable processes and automatically prevents sleep while they run. No manual toggling. No lost work.

---

## 2. Architecture Overview

### 2.1 Tech Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| Core logic | Rust | Cross-platform process scanning, sleep assertion management, zero-cost abstractions |
| UI shell | Tauri v2 | Native system tray, lightweight webview for settings (~5MB binary vs ~150MB Electron) |
| Settings UI | HTML/CSS/JS (vanilla or Svelte) | Simple, fast, no framework overhead for a settings panel |
| Platform sleep API | Rust FFI to IOKit (macOS) | Platform trait allows future Windows/Linux implementations |

### 2.2 Module Architecture

```
restнot/
├── src-tauri/
│   ├── src/
│   │   ├── main.rs                  # Tauri app entry point
│   │   ├── lib.rs                   # Module declarations
│   │   ├── process_watcher.rs       # Process scanning and matching
│   │   ├── sleep_manager.rs         # Platform sleep assertion trait
│   │   ├── sleep_manager_macos.rs   # macOS IOPMAssertion implementation
│   │   ├── sleep_manager_stub.rs    # No-op stub for unsupported platforms
│   │   ├── config.rs                # Watchlist, settings persistence
│   │   ├── tray.rs                  # System tray icon and menu
│   │   ├── notifications.rs         # Native notification dispatch
│   │   └── privacy.rs               # Process argument sanitization
│   ├── Cargo.toml
│   └── tauri.conf.json
├── src/                             # Frontend (settings UI)
│   ├── index.html
│   ├── settings.js
│   └── styles.css
├── assets/
│   ├── icon-idle.png                # Tray icon: no processes watched
│   ├── icon-active.png              # Tray icon: preventing sleep
│   └── app-icon.png                 # App icon
├── README.md
├── LICENSE                          # MIT
└── PRIVACY.md                       # Dedicated privacy documentation
```

### 2.3 Data Flow

```
[Poll Timer: every 5s]
        │
        ▼
[Process Watcher] ──scan──▶ [OS Process List]
        │                        │
        │                  match against
        │                  watchlist + args
        │
        ▼
[Match Found?]
   │         │
  YES        NO
   │         │
   ▼         ▼
[Sleep Manager]   [Release Assertion]
 create/hold       (after grace period)
 IOPMAssertion
        │
        ▼
[Tray Icon + Menu Update]
        │
        ▼
[Notification] (if state changed)
```

---

## 3. Core Components — Detailed Design

### 3.1 Process Watcher (`process_watcher.rs`)

**Responsibility:** Periodically scan the system process list, match against the user's watchlist, and report active matches.

**Approach:**
- Use the `sysinfo` crate for cross-platform process enumeration
- Poll every 5 seconds (configurable) — negligible CPU impact
- Match by process name AND optionally by command-line arguments
- Support parent process filtering (e.g., only `python` spawned from Terminal)

**Process matching rules:**

```rust
struct WatchRule {
    process_name: String,          // e.g., "claude"
    arg_patterns: Vec<String>,     // e.g., ["remote-control", "--rc", "-p"]
    match_mode: MatchMode,         // NameOnly | NameAndArgs | NameAndParent
    parent_filter: Option<String>, // e.g., "Terminal" or "iTerm2"
    enabled: bool,
}

enum MatchMode {
    NameOnly,       // Any process with this name
    NameAndArgs,    // Name + at least one arg pattern present
    NameAndParent,  // Name + spawned from specific parent
}
```

**Default watchlist (shipped with app):**

| Process | Args Filter | Description |
|---------|-------------|-------------|
| `claude` | `remote-control`, `--rc`, `--remote-control` | Claude Code remote control |
| `claude` | `-p` | Claude Code headless mode |
| `claude` | (any long-running, >60s) | Claude Code interactive session |
| `ssh` | (none — any ssh) | Active SSH connections |
| `rsync` | (none) | File sync operations |
| `scp` | (none) | Secure copy transfers |
| `cargo` | `build`, `test` | Rust builds |
| `xcodebuild` | (none) | Xcode builds |
| `docker` | `run`, `compose` | Docker containers |
| `make` | (none) | Build systems |
| `npm` | `run` | Node script execution |
| `python` | (NameAndParent: Terminal) | Python scripts from terminal |
| `ruby` | (NameAndParent: Terminal) | Ruby scripts from terminal |

**Claude Code config file detection:**
- Read `~/.claude/settings.json` for `remoteControl.enabled: true`
- If enabled globally, assert sleep prevention whenever any `claude` process is running
- File watch via `notify` crate (no polling needed for config changes)

### 3.2 Sleep Manager (`sleep_manager.rs` + platform implementations)

**Responsibility:** Create and release system sleep assertions.

**Platform trait:**

```rust
pub trait SleepInhibitor {
    fn create_assertion(&mut self, reason: &str) -> Result<AssertionHandle>;
    fn release_assertion(&mut self, handle: AssertionHandle) -> Result<()>;
    fn release_all(&mut self) -> Result<()>;
    fn is_holding(&self) -> bool;
}
```

**macOS implementation (`sleep_manager_macos.rs`):**
- Use `IOPMAssertionCreateWithName` via `core-foundation` and `io-kit-sys` crates
- Assertion type: `kIOPMAssertPreventUserIdleSystemSleep`
- Optional: `kIOPMAssertPreventUserIdleDisplaySleep` (user-configurable)
- Single assertion held for all matched processes (not one per process)
- Assertion reason string: `"RestNot: <process_name> is running"`

**Future platform stubs:**
- **Windows:** `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`
- **Linux:** `systemd-inhibit` or D-Bus `org.freedesktop.login1.Manager.Inhibit`

**Grace period logic:**
- When the last watched process ends, start a countdown timer (default: 30 seconds)
- If a new watched process appears within the grace period, cancel the timer
- If timer expires, release the sleep assertion
- Prevents rapid assert/release churn when processes restart

### 3.3 System Tray (`tray.rs`)

**Tray icon states:**

| State | Icon | Tooltip |
|-------|------|---------|
| Idle | Dim/outline icon | "RestNot — No active processes" |
| Active | Filled/lit icon | "RestNot — Preventing sleep (claude)" |
| Paused | Icon with pause badge | "RestNot — Manually paused" |

**Tray menu structure:**

```
┌──────────────────────────────────────┐
│ 🟢 Preventing Sleep                 │
│ ─────────────────────────────────── │
│ Active processes:                    │
│   claude (remote-control) — 2h 14m  │
│   ssh — 45m                          │
│ ─────────────────────────────────── │
│ ⏸  Pause RestNot                    │
│ 📋 What Can RestNot See?            │
│ ⚙️  Settings...                     │
│ ─────────────────────────────────── │
│ 📊 Session History                  │
│ ─────────────────────────────────── │
│ About RestNot                        │
│ Quit                                 │
│                                      │
│ v1.0.0                              │
└──────────────────────────────────────┘
```

### 3.4 Configuration (`config.rs`)

**Storage:** JSON file at `~/.config/restnot/config.json`

```json
{
  "version": 1,
  "poll_interval_seconds": 5,
  "grace_period_seconds": 30,
  "prevent_display_sleep": false,
  "notifications_enabled": true,
  "notify_on_assert": true,
  "notify_on_release": true,
  "launch_at_login": true,
  "show_duration_in_menu": true,
  "log_sessions": false,
  "watchlist": [
    {
      "process_name": "claude",
      "arg_patterns": ["remote-control", "--rc", "--remote-control"],
      "match_mode": "NameAndArgs",
      "parent_filter": null,
      "enabled": true
    }
  ],
  "custom_rules": []
}
```

### 3.5 Notifications (`notifications.rs`)

**Events that trigger notifications:**

| Event | Notification |
|-------|-------------|
| First watched process detected | "RestNot: Keeping awake — claude (remote-control) detected" |
| All processes ended (after grace) | "RestNot: Sleep re-enabled — claude finished after 3h 22m" |
| New process joins during hold | Silent (avoid notification spam) |
| Manual pause activated | "RestNot: Paused — sleep prevention disabled" |

---

## 4. Privacy & Transparency Design

### 4.1 Privacy Principles

1. **No terminal output reading** — RestNot never reads stdout, stderr, or terminal buffer contents
2. **No keystroke monitoring** — No accessibility permissions requested or used
3. **No network access** — App has zero network entitlements; physically cannot phone home
4. **No clipboard access** — Never reads or writes clipboard
5. **No screen recording** — No screen capture permissions requested
6. **Process arguments are sanitized** — Prompt content in `claude -p "..."` is redacted to `claude -p "…"`
7. **All data local** — Config and optional session logs stored in `~/.config/restnot/` only
8. **Open source** — Core scanning logic is ~100 lines, fully auditable

### 4.2 Argument Sanitization (`privacy.rs`)

When displaying process arguments in the UI:

```rust
fn sanitize_args(args: &[String]) -> Vec<String> {
    let redact_next = ["-p", "--prompt", "--message"];
    let mut result = Vec::new();
    let mut skip_next = false;

    for arg in args {
        if skip_next {
            result.push("\"…\"".to_string());
            skip_next = false;
            continue;
        }
        if redact_next.contains(&arg.as_str()) {
            result.push(arg.clone());
            skip_next = true;
        } else {
            result.push(arg.clone());
        }
    }
    result
}
```

**Example:**
- Raw: `claude -p "Refactor the auth module and fix all tests"`
- Displayed: `claude -p "…"`

### 4.3 "What Can RestNot See?" Panel

Accessible from tray menu at all times. Shows a live, real-time view of exactly what RestNot reads:

```
┌─────────────────────────────────────────┐
│  What Can RestNot See?                  │
│                                         │
│  RestNot reads ONLY the following:      │
│                                         │
│  PID    Name     Arguments (sanitized)  │
│  ────   ─────    ─────────────────────  │
│  4821   claude   remote-control         │
│  5102   ssh      user@server.com        │
│                                         │
│  RestNot CANNOT see:                    │
│  ✗ Terminal output or content           │
│  ✗ File contents                        │
│  ✗ Keystrokes or clipboard              │
│  ✗ Screen contents                      │
│  ✗ Network traffic                      │
│                                         │
│  This app has no network permissions    │
│  and cannot send data anywhere.         │
│                                         │
│  Source code: github.com/you/restnot    │
└─────────────────────────────────────────┘
```

### 4.4 First Launch Onboarding

Single screen shown once on first launch:

> **RestNot keeps your Mac awake while your agents work.**
>
> It watches for running processes like `claude`, `ssh`, and `rsync` — and prevents sleep until they finish.
>
> **What it reads:** Process names and their launch flags (e.g., `claude remote-control`).
> **What it never reads:** Terminal output, file contents, keystrokes, clipboard, or network traffic.
> **Network access:** None. This app cannot connect to the internet.
>
> You can verify this anytime via "What Can RestNot See?" in the menu bar.
>
> [Get Started]

---

## 5. Power User Features

### 5.1 CLI Companion (`restnot` command)

A lightweight CLI that communicates with the running app via a local Unix socket:

```bash
# Manually assert sleep prevention for a command (like caffeinate but reports to the UI)
restnot wrap -- cargo build --release

# Add a temporary watch rule for this session only
restnot watch --pid 12345

# Check current status
restnot status
# Output: RestNot: active (claude remote-control — 2h 14m)

# Pause/resume from terminal
restnot pause
restnot resume

# List active assertions
restnot list
```

### 5.2 Session History (Opt-In)

When `log_sessions` is enabled in config:

```json
// ~/.config/restnot/history.jsonl (append-only)
{"start": "2026-04-15T22:30:00Z", "end": "2026-04-16T01:45:00Z", "processes": ["claude (remote-control)"], "duration_minutes": 195}
{"start": "2026-04-16T09:00:00Z", "end": "2026-04-16T09:42:00Z", "processes": ["cargo build"], "duration_minutes": 42}
```

- No prompt content, no file paths, no arguments stored — only process name and timing
- Viewable from tray menu "Session History"
- Exportable as CSV for personal analytics
- User can clear history at any time

### 5.3 Conditional Rules

Power users can create rules with conditions:

```json
{
  "process_name": "python",
  "match_mode": "NameAndParent",
  "parent_filter": "Terminal",
  "conditions": {
    "min_runtime_seconds": 60,
    "min_cpu_percent": 5.0,
    "time_window": {
      "after": "18:00",
      "before": "09:00"
    }
  }
}
```

- **Minimum runtime:** Only trigger for processes running longer than N seconds (prevents false positives from quick scripts)
- **CPU threshold:** Only trigger if the process is actively working (not idle)
- **Time window:** Only active during certain hours (e.g., only prevent sleep overnight)

### 5.4 Global Hotkey

- Toggle pause/resume with a configurable global keyboard shortcut
- Default: `Cmd + Shift + R`
- Shows a brief HUD overlay: "RestNot Paused" / "RestNot Active"

### 5.5 Battery Safety

- Optional setting: "Only prevent sleep when connected to power"
- When enabled on battery, RestNot shows a warning in the tray: "On battery — will allow sleep in 30m unless plugged in"
- Configurable battery threshold (e.g., "Allow sleep below 20% regardless")

### 5.6 Integration with macOS Focus Modes

- Optionally auto-pause RestNot when a specific Focus mode is active (e.g., "Sleep" focus)
- Optionally auto-enable RestNot when "Work" or "Do Not Disturb" focus is active

### 5.7 Scriptable via Unix Socket

The app exposes a local Unix socket at `/tmp/restnot.sock` for automation:

```bash
# Trigger assertion from any script
echo '{"action":"hold","reason":"My custom build"}' | socat - UNIX-CONNECT:/tmp/restnot.sock

# Release
echo '{"action":"release"}' | socat - UNIX-CONNECT:/tmp/restnot.sock

# Query status
echo '{"action":"status"}' | socat - UNIX-CONNECT:/tmp/restnot.sock
```

This enables integration with CI scripts, Makefiles, git hooks, and custom tooling.

---

## 6. Test Plan

### 6.1 Process Detection Tests

| # | Test Case | Expected Result |
|---|-----------|-----------------|
| 1 | `claude remote-control` is running | Detected, assertion created |
| 2 | `claude --rc` flag variant | Detected, assertion created |
| 3 | `claude --remote-control` flag variant | Detected, assertion created |
| 4 | `claude -p "some prompt"` headless | Detected, assertion created |
| 5 | `claude` interactive (long-running) | Detected after min_runtime threshold |
| 6 | `claude --version` (short-lived) | NOT detected (exits before threshold) |
| 7 | `ssh user@host` running | Detected, assertion created |
| 8 | `rsync` transferring files | Detected, assertion created |
| 9 | Multiple watched processes simultaneously | All listed in menu, single assertion held |
| 10 | No watched processes running | No assertion, idle state |
| 11 | Process name collision (user script named `claude`) | Detected (by design — user can disable rule) |
| 12 | Process with matching name but non-matching args | NOT detected (when NameAndArgs mode) |
| 13 | Process spawned between poll intervals | Detected on next poll cycle |
| 14 | Rapid process start/stop within one poll cycle | May be missed (acceptable — documented limitation) |

### 6.2 Sleep Assertion Tests

| # | Test Case | Expected Result |
|---|-----------|-----------------|
| 15 | Single watched process starts | IOPMAssertion created |
| 16 | Second watched process starts while first running | No additional assertion (single assertion held) |
| 17 | First process ends, second still running | Assertion maintained |
| 18 | All processes end | Grace period timer starts |
| 19 | Grace period expires with no new processes | Assertion released |
| 20 | New process starts during grace period | Grace timer cancelled, assertion maintained |
| 21 | App quit while assertion is held | Assertion released on cleanup |
| 22 | App crash while assertion is held | OS automatically releases (IOKit behavior) |
| 23 | User toggles "prevent display sleep" setting | Assertion type updated on next cycle |
| 24 | Duplicate assertions not created on rapid polls | Single assertion verified |

### 6.3 UI Tests

| # | Test Case | Expected Result |
|---|-----------|-----------------|
| 25 | App launch — no processes running | Idle icon, "No active processes" in menu |
| 26 | App launch — processes already running | Active icon, processes listed immediately |
| 27 | Process detected during runtime | Icon changes to active, menu updates |
| 28 | All processes end | Icon changes to idle (after grace period) |
| 29 | Duration counter accuracy | Timer increments correctly in menu |
| 30 | Multiple processes listed | All shown with individual durations |
| 31 | "What Can RestNot See?" opens | Panel shows live process data |
| 32 | Settings changes apply | Poll interval, grace period, watchlist update without restart |
| 33 | Manual pause via menu | Assertion released, icon shows paused state |
| 34 | Manual resume via menu | Scanning resumes, assertion re-created if processes found |
| 35 | Notification on assertion start | System notification shown (if enabled) |
| 36 | Notification on assertion release | System notification with duration shown |

### 6.4 Privacy Tests

| # | Test Case | Expected Result |
|---|-----------|-----------------|
| 37 | Process with `-p "secret prompt"` detected | UI shows `claude -p "…"` (redacted) |
| 38 | SSH with password in args (shouldn't happen, but) | Args truncated/sanitized |
| 39 | Session history (opt-in) logging | Only process name + timestamps stored |
| 40 | No network calls made by app | Verified via network monitor / Little Snitch |
| 41 | Config file contains no sensitive data | Watchlist rules only, no process output |

### 6.5 Edge Case Tests

| # | Test Case | Expected Result |
|---|-----------|-----------------|
| 42 | Mac wakes from sleep with processes running | Assertion re-created immediately |
| 43 | System under heavy load | Poll timer may drift but recovers |
| 44 | 100+ processes running simultaneously | Scan completes in <100ms |
| 45 | User adds empty watchlist rule | Ignored, no crash |
| 46 | Corrupted config file | Falls back to defaults, warns user |
| 47 | Permissions denied for process scanning | Graceful degradation, notifies user |
| 48 | Launch at login enabled | App starts with system, begins scanning |
| 49 | Battery drops below threshold | Assertion released with warning notification |
| 50 | Focus mode integration toggle | Assertion paused/resumed with Focus changes |

---

## 7. Milestone Plan

### MVP (v0.1) — Target: 2–3 weeks

- [x] Rust + Tauri project scaffold
- [ ] Process watcher with default watchlist
- [ ] macOS sleep assertion (IOPMAssertion)
- [ ] System tray with idle/active icon states
- [ ] Tray menu showing active processes and duration
- [ ] Grace period logic
- [ ] Basic settings UI (watchlist management)
- [ ] First-launch onboarding screen
- [ ] "What Can RestNot See?" transparency panel
- [ ] Argument sanitization for displayed process args

### v0.2 — Notifications & Polish

- [ ] Native notifications (assertion start/end)
- [ ] Launch at login support
- [ ] Persistent config file
- [ ] "Pause RestNot" toggle
- [ ] Battery safety (optional power adapter requirement)
- [ ] README with privacy section
- [ ] Homebrew formula
- [ ] GitHub Releases with signed binaries

### v0.3 — Power User Features

- [ ] CLI companion (`restnot wrap`, `restnot status`)
- [ ] Unix socket API
- [ ] Session history (opt-in)
- [ ] Conditional rules (min runtime, CPU threshold, time window)
- [ ] Global hotkey for pause/resume
- [ ] Claude Code config file detection (`~/.claude/settings.json`)

### v0.4 — Cross-Platform Groundwork

- [ ] Windows sleep assertion implementation (`SetThreadExecutionState`)
- [ ] Linux sleep inhibitor implementation (`systemd-inhibit` / D-Bus)
- [ ] Cross-platform CI builds (GitHub Actions)
- [ ] Platform-specific installer scripts

### v1.0 — Stable Release

- [ ] macOS Focus Mode integration
- [ ] Comprehensive test suite
- [ ] Documentation site
- [ ] Community-contributed watchlist presets
- [ ] Localization (i18n) support

---

## 8. Distribution

### 8.1 Homebrew

```ruby
# Formula: restnot.rb
class Restnot < Formula
  desc "Process-aware sleep prevention for macOS"
  homepage "https://github.com/youruser/restnot"
  url "https://github.com/youruser/restnot/releases/download/v0.1.0/restnot-macos-arm64.tar.gz"
  sha256 "..."
  license "MIT"

  depends_on :macos

  def install
    bin.install "RestNot.app"
  end
end
```

**Installation:**
```bash
brew tap youruser/restnot
brew install restnot
```

### 8.2 GitHub Releases

Each release includes:
- `RestNot-macos-arm64.dmg` — Apple Silicon
- `RestNot-macos-x86_64.dmg` — Intel
- `RestNot-macos-universal.dmg` — Universal binary
- SHA256 checksums
- Signed with developer certificate (or ad-hoc for initial releases)

### 8.3 CI/CD (GitHub Actions)

```yaml
# Triggered on tag push (v*)
# Steps: build Rust + Tauri → code sign → notarize → create DMG → upload to release
```

---

## 9. Repository Structure & Open Source

### 9.1 README.md Outline

1. **What is RestNot?** — One-paragraph description
2. **Why?** — The problem (lost agent work from unexpected sleep)
3. **How it works** — Process watching → sleep assertion → automatic release
4. **Installation** — Homebrew + manual download
5. **Default watchlist** — Table of out-of-the-box supported processes
6. **Configuration** — How to add custom rules
7. **Privacy** — Dedicated section with direct links to scanning code
8. **CLI** — Usage examples
9. **Building from source** — `cargo tauri build`
10. **Contributing** — Guidelines
11. **License** — MIT

### 9.2 PRIVACY.md

Standalone privacy document covering:
- What data is read (process names, PIDs, launch arguments)
- What data is NEVER read (terminal output, files, keystrokes, network)
- What is stored locally (config + optional session history)
- What leaves the machine (nothing — no network entitlement)
- How to verify (link to specific source files, entitlements plist)

### 9.3 License

MIT — maximum adoption, no friction for contributors.

---

## 10. Learning Summary

### Key Technical Concepts

**IOPMAssertionCreateWithName (macOS):**
The macOS power management API allows apps to declare "power assertions" that prevent system sleep. RestNot uses `kIOPMAssertPreventUserIdleSystemSleep` to tell the OS "don't sleep — work is happening." When the assertion is released (or the app quits/crashes), normal sleep behavior resumes. The OS automatically cleans up assertions from terminated processes.

**Process enumeration without special permissions:**
On macOS, any app can read the list of running processes and their command-line arguments using `sysctl` with `KERN_PROC` / `KERN_PROCARGS2`. No accessibility permissions, no entitlements, no user approval required. This is the same mechanism `ps` and Activity Monitor use.

**Tauri's system tray model:**
Tauri v2 provides `SystemTray` with native menu support. The tray icon and menu are updated from Rust via event emission. The webview (settings UI) communicates with the Rust backend via Tauri's IPC commands. This gives native performance with web-based UI flexibility.

**Platform abstraction via traits:**
The `SleepInhibitor` trait defines the interface for sleep prevention. Each platform implements this trait differently (IOKit on macOS, `SetThreadExecutionState` on Windows, `systemd-inhibit` on Linux). The rest of the app is platform-agnostic — it only interacts with the trait, not the implementation. This is Rust's zero-cost abstraction in practice.

**Grace period pattern:**
A debounce mechanism that prevents rapid assertion create/release cycles. When processes end, a timer starts. If new processes appear before the timer fires, it resets. This handles common scenarios like a build tool that spawns and terminates child processes in rapid succession.
