# Meerkat Runner — Development Guide

Handoff spec for building Meerkat Runner, a native macOS menu bar app that lists every local dev server, lets you register projects from a folder with auto-detected start commands, and starts/stops them from one dropdown.

Read this whole file before writing code. Build in the milestone order in §11, and do not start a milestone until the previous one meets its acceptance criteria. Where this guide says **MUST**, treat it as a hard requirement; the security rules in §8 are not negotiable trade-offs.

Last updated: 2026-10-13

---

## 1. Product summary

| | |
| --- | --- |
| Name | Meerkat Runner (working) |
| Platform | macOS 14 Sonoma and later, Apple silicon + Intel (universal) |
| UI | Menu bar only (`LSUIElement`), no Dock icon |
| Language | Swift 5.10+ / Swift 6 language mode where practical, SwiftUI + small AppKit bridges |
| Distribution | Developer ID–signed, notarized, **outside** the Mac App Store; Sparkle 2 updates; Homebrew cask |
| Price | Undecided (leaning free). Do not build licensing or payments |
| Relationship | Marketing companion to **Meerkat**, a website monitoring dashboard that is not public yet |

### What it does

1. Shows every TCP listener owned by the current user, grouped as **Running** (registered projects), **Stopped** (registered, not running) and **Other listeners**.
2. **Add server from folder:** user picks a directory; the app *reads* manifests (never executes them) and proposes ranked start commands.
3. User approves the exact command before it ever runs. If the underlying script later changes, the user must re-approve after seeing a diff.
4. Starts/stops/restarts registered servers, shows logs, opens them in the browser.
5. Can stop any server matched to a registered project, **including one the user started in a terminal**, and offers **Restart in Runner** to take it over so the terminal can be closed.

### Decisions already made

- Stop is allowed for any listener matched to a registered project (launched by Runner, or started elsewhere with its working directory inside the project). Unmatched listeners are **view-only**.
- **No** tunnel / public sharing feature.
- **No** privileged helper, no root, no daemons. One process.
- **Not** sandboxed (the sandbox forbids launching the user's toolchains).

### Non-goals (do not build)

Tunnels or sharing · killing unmatched processes · installing dependencies (`npm install` etc.) · editing project files · Windows/Linux · App Store build · telemetry containing paths, commands, or env · licensing/payments · Lighthouse/localhost audits · Docker container management (v1.0 only *maps* compose ports, see §11).

---

## 2. Architecture

```
┌────────────────────┐ state     ┌────────────────────┐ listeners ┌────────────────────┐
│ Menu bar UI        │◀──────────│ Server registry    │◀──────────│ Port scanner       │
│ (SwiftUI)          │           │ (@Observable)      │           │ (libproc)          │
└─────────┬──────────┘           └─────────▲──────────┘           └────────────────────┘
          │ add folder                     │ managed PIDs / exits
          ▼                                │
┌────────────────────┐ proposals ┌─────────┴──────────┐ approved  ┌────────────────────┐
│ Detectors          │──────────▶│ Approval gate      │──────────▶│ Process            │
│ (read-only)        │           │                    │           │ supervisor         │
└────────────────────┘           └─────────┬──────────┘           └─────────┬──────────┘
                                           │ saves                          │ spawn / signal
                                           ▼                                ▼
                                 ┌────────────────────┐           ┌────────────────────┐
                                 │ Project store      │           │ Your dev servers   │
                                 │ (0600 + HMAC)      │           │ (own sessions)     │
                                 └────────────────────┘           └────────────────────┘
```

Invariant: **the approval gate is the only path from a detected or saved command to a running process.** No other code may call the supervisor's spawn API.

### Package layout

Use an Xcode app target plus a local Swift package so the core is testable without UI.

```
MeerkatRunner/
├── App/                          # Xcode app target
│   ├── MeerkatRunnerApp.swift    # @main, MenuBarExtra(.window)
│   ├── Views/                    # MenuView, ServerRow, AddServerSheet,
│   │                             # ReapprovalSheet, LogWindow, SettingsView
│   ├── Info.plist                # LSUIElement = YES
│   └── MeerkatRunner.entitlements
├── Packages/RunnerKit/
│   ├── Sources/
│   │   ├── CProcInfo/            # C shim: module.modulemap + libproc wrappers
│   │   ├── ProcInfo/             # Swift API over CProcInfo
│   │   ├── Scanner/              # PortScanner, ListenerClassifier
│   │   ├── Detection/            # Detector protocol + one file per detector
│   │   ├── Approval/             # ApprovalGate, ScriptFingerprint
│   │   ├── Store/                # ProjectStore, Keychain HMAC, migrations
│   │   ├── Supervisor/           # ProcessSupervisor, PTY, LogBuffer, ShellEnv
│   │   └── Registry/             # ServerRegistry (merges scanner + store + supervisor)
│   └── Tests/
│       ├── DetectionTests/       # fixture-driven
│       ├── ApprovalTests/
│       ├── StoreTests/
│       ├── SupervisorTests/      # spawns real test servers
│       └── Fixtures/             # sample projects (see §10)
└── Scripts/
    ├── release.sh                # archive, sign, notarize, staple, Sparkle appcast
    └── test-servers/             # tiny servers used by SupervisorTests
```

---

## 3. Data model

All types `Codable`, `Sendable`, value types. Persist with a schema `version` field from day one.

```swift
struct Project: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String                 // "docs"
    var path: String                 // canonical realpath of the folder
    var bookmark: Data?              // regular (non-security-scoped) bookmark, survives moves
    var detector: DetectorID         // .node, .procfile, .rails, ...
    var command: LaunchCommand
    var envOverrides: [String: String]   // user-entered; never logged
    var envFiles: [String]               // relative paths, e.g. [".env.local"]
    var expectedPort: Int?           // predicted or user-entered
    var learnedPort: Int?            // observed on a real run
    var healthURL: URL?
    var autoStartAtLogin: Bool
    var preferLocalhostBind: Bool    // see §6.6
    var approval: Approval?          // nil = never approved; cannot start
    var liveURL: URL?                // reserved for Meerkat integration (later)
}

enum LaunchCommand: Codable, Sendable {
    case argv([String])              // default: ["pnpm", "run", "dev"]
    case shell(String)               // opt-in, labelled "Shell command" in UI
}

struct Approval: Codable, Sendable {
    var fingerprint: String          // hex SHA-256, see §8.2
    var approvedAt: Date
    var displayedCommand: String     // exactly what the user saw, for the diff
    var resolvedScript: String?      // e.g. package.json scripts.dev body
}

struct Listener: Hashable, Sendable {
    var pid: pid_t
    var pgid: pid_t
    var ppid: pid_t
    var port: Int
    var address: ListenAddress       // .loopback, .wildcard, .specific(String)
    var family: AddressFamily        // .v4, .v6
    var executablePath: String
    var argv: [String]
    var cwd: String?
    var startTime: timeval           // from proc_bsdinfo; identity check before signaling
}

enum ServerState {
    case running(managed: Bool, listeners: [Listener], since: Date)   // managed = Runner launched it
    case starting, stopping, stopped
    case crashed(exitCode: Int32, at: Date)
    case needsReapproval
}
```

The **registry** exposes a single `@Observable` model the UI renders:

```swift
@Observable final class ServerRegistry {
    private(set) var projects: [ProjectRow]        // running + stopped
    private(set) var otherListeners: [Listener]    // unmatched, view-only
}
```

### Storage

- Location: `~/Library/Application Support/MeerkatRunner/projects.json`, file mode `0600`, directory `0700`.
- Logs: `~/Library/Logs/MeerkatRunner/<project-id>.log`, rotated at 5 MB, keep 3.
- Runtime state (PGIDs Runner launched, for re-adoption after relaunch): `~/Library/Application Support/MeerkatRunner/runtime.json`.
- **Integrity:** the store is a JSON envelope `{ version, projects, mac }` where `mac` is HMAC-SHA256 over the canonical encoding of `projects`, keyed by a random 32-byte key in the Keychain (`kSecClassGenericPassword`, service `us.okayplus.meerkat-runner.store`, created on first launch). On load, a bad or missing MAC → load projects but mark **every** approval invalid (force re-approval) and show a one-time warning. This is tamper-*evidence*, not tamper-proofing; say so in code comments.
- Writes are atomic (`Data.write(options: .atomic)`), then `chmod 0600`.

---

## 4. Port scanner

Use libproc through a small C module (`CProcInfo`) with a `module.modulemap` that includes `<libproc.h>` and `<sys/proc_info.h>`. Do **not** shell out to `lsof` or `netstat`.

### Algorithm (one scan)

1. `proc_listpids(PROC_UID_ONLY, getuid(), …)` → candidate PIDs (current user only).
2. For each PID, `proc_pidinfo(pid, PROC_PIDLISTFDS, …)` → `proc_fdinfo[]`; keep `proc_fdtype == PROX_FDTYPE_SOCKET`.
3. For each socket fd, `proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, …)` → `socket_fdinfo`. Keep `psi.soi_kind == SOCKINFO_TCP` and `tcpsi_state == TSI_S_LISTEN`.
4. Port = `ntohs(insi_lport)`; address from `insi_vflag` (`INI_IPV4` / `INI_IPV6`) and `insi_laddr`. Classify: `127.0.0.0/8` or `::1` → loopback; `0.0.0.0` or `::` → wildcard (**LAN-reachable**); anything else → specific.
5. Metadata per PID (cache by `(pid, startTime)`):
   - `PROC_PIDTBSDINFO` → `pbi_ppid`, `pbi_pgid`, `pbi_start_tvsec/usec`, `pbi_name`.
   - `proc_pidpath` → executable path.
   - `PROC_PIDVNODEPATHINFO` → `pvi_cdir.vip_path` (cwd).
   - `sysctl([CTL_KERN, KERN_PROCARGS2, pid])` → argv (parse argc, skip exec path and padding NULs).
6. De-duplicate: a server listening on both v4 and v6 for the same port is one row with two listeners.

Calls fail with `EPERM`/`ESRCH` for processes that exit mid-scan or are protected — skip silently, never log per-PID errors at default level.

### Scheduling

- Menu open: scan every 2 s. Menu closed: every 15 s (feeds the badge count).
- Run on a background actor; publish diffs to the registry on the main actor.
- For processes Runner launched, also attach `DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)` for instant exit events.

### Matching listeners to projects

A listener matches project P when any of these hold, checked in order:

1. Its PGID is one Runner launched for P (from the supervisor or `runtime.json`).
2. Its cwd, or the cwd of any ancestor up to (not including) the first shell or `launchd`, is inside `P.path`.
3. Its argv contains an absolute path inside `P.path`.

Compare canonical paths (`realpath`, resolve symlinks, case-insensitive comparison on case-insensitive volumes). If several projects match (monorepo + workspace), choose the **deepest** path.

### Classifier (labels and icons)

Map argv/executable to a framework label: `next dev` → Next.js, `vite` → Vite, `astro dev` → Astro, `rails s|server`, `puma` → Rails, `manage.py runserver` → Django, `uvicorn` / `gunicorn` / `flask run` → Python, `php artisan serve` → Laravel, `node` (fallback) → Node. Keep the table in one file with tests.

**Known system listeners** owned by the user should be hidden from "Other listeners" by default (toggle in Settings): `ControlCenter` (AirPlay Receiver on 5000 and 7000), `rapportd`, `sharingd`, `identityservicesd`, and similar. Keep this as a data table.

**App listeners** (desktop apps such as Dropbox, Adobe, Raycast, editor helpers) are hidden from "Other listeners" by default too (separate Settings toggle): any listener whose executable is inside a `.app` bundle, unless that bundle is nested in a `.framework` (python.org/Homebrew Python run from `Python.framework/…/Python.app`) or is on a keep-list of dev-server apps (Postgres.app, DBngin, Herd, Docker, OrbStack, Rancher Desktop). Keep the keep-list as a data table.

---

## 5. Detection (Add server from folder)

### Flow

1. `NSOpenPanel` (directories only), or drag a folder onto the Add server window. (Not onto the menu: a `MenuBarExtra(.window)` closes as soon as Finder becomes active, so it can't receive a drag.)
2. Run all detectors concurrently against the folder. Detectors are **pure functions of file contents**: they read files with a 1 MB size cap per file and MUST NOT execute anything, spawn processes, or touch the network.
3. Merge results into ranked `Proposal`s; show the Add sheet (§9.2).
4. User picks or edits a proposal → approval gate (§8.2) → saved.

```swift
protocol Detector: Sendable {
    static var id: DetectorID { get }
    func detect(in folder: URL, files: FileSnapshot) -> [Proposal]
}

struct Proposal: Sendable {
    var detector: DetectorID
    var label: String               // "pnpm dev"
    var command: LaunchCommand
    var resolvedScript: String?     // "next dev --turbopack"
    var source: String              // "package.json"
    var framework: String?          // "Next.js 15"
    var predictedPort: Int?
    var confidence: Int             // ranking only
    var notes: [String]             // e.g. "needs a build first"
}
```

`FileSnapshot` reads the folder once (top level plus known config paths) so detectors don't each hit the disk.

### Detector table

| Detector | Reads | Proposes | Rules |
| --- | --- | --- | --- |
| Node | `package.json`, lockfiles | `<pm> run <script>` for `dev`, `start`, `serve`, `develop`, `preview` (that order) | Package manager by lockfile: `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `bun.lockb`/`bun.lock` → bun, `package-lock.json` → npm; else `packageManager` field; else npm. Framework from deps (`next`, `vite`, `astro`, `@remix-run/*`, `nuxt`, `@sveltejs/kit`). `start` gets note "needs a build first" for Next/Nuxt. Include `pre<name>`/`post<name>` scripts in `resolvedScript` when present |
| Monorepo | `pnpm-workspace.yaml`, `package.json#workspaces`, `turbo.json`, `nx.json` | Root `dev` plus one proposal per workspace with a `dev` script | Offer "Add each as its own server" in the sheet |
| Procfile | `Procfile.dev`, `Procfile` | One proposal per line | Prefer `.dev` |
| Rails | `Gemfile`, `bin/dev`, `bin/rails` | `bin/dev`, else `bin/rails server` | |
| Django | `manage.py` | `<python> manage.py runserver` | `<python>` = `.venv/bin/python`, `venv/bin/python`, else `python3` |
| Python ASGI/WSGI | `pyproject.toml`, `requirements*.txt` | `uvicorn <module>:app --reload`, `flask run` | Only when the dependency is declared; module guessed from `main.py`/`app.py` and marked low confidence |
| Laravel | `artisan`, `composer.json` | `php artisan serve` | |
| Make / Just | `Makefile`, `justfile` | Targets named `dev`, `run`, `serve`, `start` | Parse target names only; `resolvedScript` = recipe lines |
| Docker Compose | `compose.yaml`, `compose.yml`, `docker-compose.yml` | `docker compose up` | Ports from `ports:`; mark "Docker" |
| Static | `index.html` and nothing else | Built-in static server | **v0.3+**, optional |

### Port prediction

Order: explicit `--port`/`-p` in the resolved script → `PORT=` in the selected env files (read the key, never display the value) → framework default (Next 3000, Vite 5173, Astro 4321, Remix 3000, Nuxt 3000, SvelteKit 5173, Django 8000, Rails 3000, Flask 5000, Laravel 8000). Flask on 5000 collides with AirPlay Receiver — show a warning.

After the first successful start, learn the real port (§6.4) and store `learnedPort`.

---

## 6. Process supervisor

### 6.1 Environment

GUI apps launched by `launchd` don't inherit shell config, so `nvm`, `asdf`, `mise`, `fnm`, `pyenv`, and Homebrew paths are missing.

- On first need, capture the login environment by running the user's `$SHELL` (fall back to `/bin/zsh`) with `-l -i -c` and a command that prints a unique sentinel, then `env -0`, then the sentinel again. Parse only between the sentinels (interactive rc files often print banners). Timeout 5 s; on timeout fall back to a minimal PATH (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`) and show a non-blocking notice.
- Cache the result; "Reload shell environment" in Settings refreshes it.
- Per project: if `.nvmrc`, `.node-version`, `.tool-versions` or `mise.toml` exists, run the command **through** the version manager only when it's installed (e.g. `mise exec --`, `fnm exec --`); otherwise use the captured PATH as-is. Keep this mapping in one table.
- Final env = captured env + values from approved env files + `envOverrides` + `FORCE_COLOR=1`. Never log env values.

### 6.2 Spawning

- Use `posix_spawn` (not `fork`, not `Foundation.Process`): `POSIX_SPAWN_SETSID` so each server is its own session and process group (PGID = child PID), `posix_spawn_file_actions_adddup2` to wire the PTY slave to fds 0–2, `posix_spawn_file_actions_addchdir_np` for cwd, `POSIX_SPAWN_CLOEXEC_DEFAULT` so no app fds leak.
- PTY via `openpty`, window size 120×40 (`TIOCSWINSZ`). Tools see `isatty(1) == true` and keep colour/progress output. Acquiring a controlling terminal is not required.
- `.argv` commands resolve the executable against the final PATH yourself, then spawn with the array. `.shell` commands run as `[$SHELL, "-c", string]` and are only allowed when the user explicitly saved a shell command.
- Record `(projectID, pid, pgid, startTime)` in memory and in `runtime.json`.

### 6.3 Logs

- Read the PTY master on a dispatch source; append to a ring buffer of the last 5,000 lines in memory and to the rotating log file.
- Keep raw bytes with ANSI for the log viewer; keep a stripped copy for search.
- Redact on display and export: values for keys matching `(?i)(key|token|secret|password|passwd|auth|cookie|session)` in `KEY=value` and `"key": "value"` shapes.

### 6.4 Learning the port

The first of these wins:

1. A new listener whose PID is in the server's session/process group or descends from the spawned PID.
2. A URL in output matching `https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})`.

Mark the server **running** once a listener appears. If `healthURL` is set, also require one successful HTTP GET (2xx–4xx counts as up) with a 2 s timeout, retried for 60 s.

### 6.5 Stopping

Before sending **any** signal, re-read the target's `proc_bsdinfo` and verify PID + start time + executable path still match what was recorded. Abort on mismatch (PID reuse).

**Runner-launched servers:** `killpg(pgid, SIGTERM)` → wait up to 5 s → `killpg(pgid, SIGKILL)`. Because of `SETSID`, the group contains exactly the server and its children (esbuild, webpack workers).

**Terminal-started servers (matched, not launched):**

1. Find the server's process group. With job control, an interactive shell puts `npm run dev` in its own group, distinct from the shell's.
2. Signal the **group** only if no member of the group is a shell (`zsh`, `bash`, `fish`, `sh`, `dash`, `nu`, `tmux`, `screen`, terminal apps) and the PGID differs from the parent shell's PGID.
3. Otherwise, signal the matched PID and each of its descendants (walk `ppid` links from a fresh process list), deepest first.
4. Same TERM → 5 s → KILL sequence. **Never** signal a shell, the terminal app, `launchd`, or a process owned by another UID.

**Restart in Runner:** stop the external server as above, wait until its port is free (poll up to 10 s), then start the saved command through the normal approval-checked path. If the port doesn't free up, report it and don't start.

### 6.6 Localhost-only binding

The app cannot force a bind address. When `preferLocalhostBind` is on, the detector's framework entry adds the right flag or env (Vite `--host 127.0.0.1`, Next `-H 127.0.0.1`, Astro `--host 127.0.0.1`, Django `127.0.0.1:<port>`, Rails `-b 127.0.0.1`, generic `HOST=127.0.0.1`). The resulting command is what gets approved and fingerprinted. If the server still binds a wildcard address, show the **LAN visible** badge.

### 6.7 Quit and relaunch

Setting: **On quit** → Stop all managed servers (default) / Leave running / Ask. On launch, read `runtime.json`; for each record whose PID + start time still match, re-adopt it (attach an exit source; logs resume from the file only). Drop stale records.

### 6.8 Crashes

Exit with a non-zero code within 10 s of start, or any unexpected exit → state `crashed`, notification ("docs exited with code 1 — View logs"), no automatic restart in v1.

---

## 7. Menu bar app shell

- `MenuBarExtra(…) { MenuView() }.menuBarExtraStyle(.window)`.
- Menu bar icon: template image; badge shows the running count (hide at 0).
- `Info.plist`: `LSUIElement = YES`, `LSMinimumSystemVersion = 14.0`.
- Launch at login: `SMAppService.mainApp.register()/unregister()` from Settings.
- Global hotkey to open the menu (v0.3): user-configurable; default none.
- Settings window: General (launch at login, on quit, hide system listeners, hide app listeners, poll intervals), Environment (reload shell env, show captured PATH), About (version, "Made by Meerkat" link → `[MEERKAT WAITLIST URL]`).
- Deep link scheme `meerkatrunner://` (v0.3): `start?id=<uuid>` and `stop?id=<uuid>` only, only for already-approved projects, always posts a notification. No command text is ever accepted from a URL.

---

## 8. Security requirements

Threat model: Runner is a one-click code launcher running as the user. Anything that can write to a project folder or the app's config could try to get code run. The design goal is that **nothing runs that the user did not see and approve in its current form.**

### 8.1 Hard rules

1. Detectors never execute, spawn, or fetch anything.
2. Only the approval gate can call the supervisor's spawn API (enforce with access control: the spawn function is `internal` to a module that only `ApprovalGate` uses).
3. Spawn with argv arrays. Never interpolate paths, names, or env values into a shell string. Shell mode is opt-in per project and labelled.
4. Never signal unmatched processes, other-UID processes, shells, terminal apps, or `launchd`. Verify identity (PID + start time + executable path) right before every signal.
5. Never write env values to logs, crash reports, analytics, or exports. Redact secrets in the log viewer.
6. Never run `install`, `postinstall`, or any lifecycle script on the user's behalf.
7. No network listener in the app itself. No outbound requests except Sparkle update checks and links the user clicks.
8. Hardened Runtime on; no `com.apple.security.cs.disable-library-validation`, no `allow-unsigned-executable-memory`, no `allow-dyld-environment-variables`.

### 8.2 Approval and fingerprints

`ScriptFingerprint` = SHA-256 over a canonical, length-prefixed encoding of:

- canonical project path
- `LaunchCommand` (argv elements or shell string)
- `resolvedScript`, including any `pre`/`post` hooks the package manager would run
- for Make/Just: the target's recipe lines; for Procfile: the line; for Compose: the compose file bytes
- names (not values) of env files and env override keys
- the version-manager wrapper, if any

Before **every** start (manual, auto-start, deep link, Restart in Runner):

1. Recompute the fingerprint from current files.
2. Equal to `approval.fingerprint` → start.
3. Different or missing → don't start; set state `needsReapproval` and show the re-approval sheet (§9.3) with a line diff of `displayedCommand`/`resolvedScript` old vs new. Auto-start at login never shows UI; it posts a notification instead.

The approval UI must show the **exact** command and the resolved script body, plus any local script files the command references (e.g. `node scripts/setup.js`) with a "Reveal in Finder" link. Hashing referenced files is optional for v1; if implemented, cap at 256 KB per file.

### 8.3 Store integrity

As in §3: 0600 file, Keychain-keyed HMAC, and a MAC failure invalidates all approvals.

---

## 9. UI specification

Mockups are on the design canvas "Dev Server Menu — UI Exploration" (three artboards). Match their structure; exact pixels are not required. Use system fonts, system materials, and semantic colours so dark mode works.

### 9.1 Dropdown (360 pt wide)

Header: title "Servers", summary line (`3 running · 1 stopped · 2 other`), Add (+) and Settings buttons. Filter field below.

Sections, in order (hide a section when it's empty):

| Section | Row content | Actions |
| --- | --- | --- |
| Running | Status dot, name, `Framework · localhost:port · uptime` | Open in browser, Logs, Stop. Badges: **LAN visible** (wildcard bind), **Started in Terminal** (matched but not launched by Runner) |
| Running — started in terminal | Same as above, with the badge | Stop, **Restart in Runner**, Open, Logs (Logs shows "Output is in your terminal" since Runner has no PTY for it) |
| Stopped | Hollow dot, name, `Framework · command · :port` | Start. Crashed rows show exit code + "View logs" |
| Needs approval | Warning dot | Review (opens §9.3) |
| Other listeners | Grey dot, process name, folder (abbreviated with `~`), `:port` | Open, Copy URL, Reveal folder, "Add as server…" (pre-fills the Add sheet with the cwd). **No Stop** |

Footer: "Add server from folder… ⌘N", "Stop all managed servers", and a quiet "Made by Meerkat" link.

Empty state (no projects, no listeners): one line explaining what the app does + "Add server from folder…" button + a quiet line "Monitor these sites once they're live → Meerkat" linking to the waitlist.

Keyboard: arrow keys move selection, Return opens in browser, ⌘. stops, ⌘R restarts, ⌘L logs, ⌘N add.

### 9.2 Add server sheet

Folder header (icon, name, path, framework, package manager + lockfile, "Change folder…"). Radio list of proposals, each showing the command in monospace, a **Suggested** badge on the top one, the source file, and the resolved script body in a code box. "Custom command…" option (argv editor; a toggle for "Run as shell command" with a warning).

Fields: Name, Port (with hint "Next.js default · learned on first run"). Checkboxes: Load `<env file>` (shows variable count, never values), Start when I log in, Bind to localhost only.

Info line: "This command runs as you, inside `<path>`. Nothing has run yet. If the script changes later, you'll be asked to approve it again."

Buttons: Cancel · Add · **Add and Start** (primary).

### 9.3 Re-approval sheet

Warning icon, title "The start script for `<name>` changed", subtitle with the previous approval date. Diff box (removed lines red, added lines green, monospace). Referenced new files with "Reveal in Finder".

Buttons: left-aligned link-style "Run previous version" (runs the previously approved command only if it can still be reconstructed exactly, e.g. from `displayedCommand` for argv commands; otherwise hide it). Right: "Don't Run" and primary "Approve and Start". **Esc = Don't Run. Return is not bound to Approve** (approval must be a deliberate click). Flagged in §13 for confirmation.

### 9.4 Log window

Separate `Window` scene per project: monospace, ANSI colours rendered, search field, "Copy all (redacted)", "Clear", "Reveal log file". Auto-scroll unless the user has scrolled up.

---

## 10. Testing

Run `swift test` for RunnerKit and `xcodebuild test` for the app on every milestone.

**Detection (fixture-driven, required):** `Tests/Fixtures/` contains minimal projects; each has an `expected.json` with the ranked proposals. At minimum: next-pnpm, vite-npm, astro-yarn, remix-bun, pnpm-monorepo (2 workspaces), turbo-monorepo, rails-bin-dev, django-venv, flask (port 5000 warning), laravel, procfile-dev, makefile-targets, justfile, compose, npm with `predev` hook, a malicious `package.json` whose `dev` contains `curl … | sh` (detector must propose it verbatim and never run it), an unreadable file, a 5 MB `package.json` (size cap).

**Approval:** fingerprint changes when the script, a hook, the argv, the env file *names* or the wrapper change; does **not** change when env *values* change; a tampered store invalidates approvals.

**Supervisor (integration, real processes):** small test servers in `Scripts/test-servers/` (a Python `http.server`, a Node server that spawns a child worker). Verify: start → port learned within 5 s; stop kills the child worker too; SIGTERM-ignoring server is SIGKILLed after 5 s; PID-reuse guard aborts on a changed start time; terminal-started simulation (spawn `zsh -i -c` running a server in its own group) → stop leaves the shell alive; Restart in Runner frees the port then restarts.

**Scanner:** listener appears/disappears within one poll; v4+v6 de-dup; wildcard vs loopback classification; system-listener filter.

**Manual QA checklist (each release):** fresh user account (no nvm in PATH) starts an nvm project; Desktop/Documents TCC prompt shown once; dark mode; VoiceOver labels on icon-only buttons; quit behaviours; relaunch re-adopts running servers; Sparkle update from previous build.

---

## 11. Milestones

Each milestone ends with a signed, notarized build the owner can run.

### v0.1 — Observe

Scanner, classifier, system-listener filter, dropdown with Other listeners only (plus Running/Stopped sections wired to an empty store), open in browser, copy URL, reveal folder, menu bar badge, Settings shell, launch at login, "Made by Meerkat" footer.

Accept when: every user-owned listener appears within one poll; LAN-visible badge is correct; scanning with the menu closed uses < 1% CPU averaged over a minute on an M-series Mac.

### v0.2 — Manage

Store + HMAC, detectors (Node, Monorepo, Procfile, Rails, Django, Python, Laravel, Make/Just), Add sheet, approval gate + fingerprints, re-approval sheet, shell env capture, supervisor (spawn, PTY, logs, learn port, stop), matching of terminal-started servers, Stop + Restart in Runner, log window, crash notifications, quit/relaunch behaviour.

Accept when: all §10 detection and supervisor tests pass; no code path can spawn without a matching fingerprint (reviewer greps for spawn call sites); a changed `dev` script blocks start until re-approved.

### v0.3 — Polish

Monorepo "add each as a server", health URLs, global hotkey, `meerkatrunner://` deep links, keyboard navigation, localhost-bind flags, static server detector, accessibility pass, Sparkle updates, Homebrew cask.

### v1.0 — Extend

Docker Compose port → project mapping (read-only: query the Docker socket for `com.docker.compose.project.working_dir` labels; no container control), port-conflict resolver ("3000 is used by X — stop it or use 3001?" only offering Stop when X is matched), Shortcuts actions (start/stop approved projects).

---

## 12. Build, signing, release

- Xcode 16+, Swift 6 toolchain. Deployment target macOS 14.0. Universal binary.
- Signing: Developer ID Application certificate; Hardened Runtime enabled; entitlements file is empty except what Sparkle requires.
- Notarize: `xcrun notarytool submit <zip> --keychain-profile <profile> --wait`, then `xcrun stapler staple`.
- Updates: Sparkle 2 with EdDSA-signed appcast over HTTPS. `SUPublicEDKey` in `Info.plist`. Private key never in the repo.
- `Scripts/release.sh` does archive → export → notarize → staple → DMG/zip → `generate_appcast`.
- Bundle ID: `us.okayplus.meerkat-runner` (confirmed). Developer ID team still open (§13).
- CI (GitHub Actions, macOS runner): `swift test`, `xcodebuild build`, SwiftLint/SwiftFormat check. Signing and notarization run locally only.

### Code conventions

- Swift Concurrency throughout: actors for the scanner and supervisor; UI state on `@MainActor`. No `DispatchQueue.main.sync`.
- Unsafe libproc/posix calls live only in `CProcInfo`, `ProcInfo` and `Supervisor`; every `Unsafe*` buffer has an explicit size check.
- No third-party dependencies except Sparkle. Ask before adding any.
- Errors are typed enums per module; user-facing messages are written in the view layer.
- Log with `os.Logger` (subsystem `us.okayplus.meerkat-runner`). Paths are `.private` by default; commands and env are never logged.

---

## 13. Open questions (ask the owner, don't guess)

1. Pricing: free vs $4.99 one-time. Don't build licensing either way.
2. Re-approval keyboard default: is "Return does nothing, Esc = Don't Run" right, or should Return = Don't Run?
3. Developer ID team (bundle ID confirmed: `us.okayplus.meerkat-runner`).
4. Meerkat waitlist URL for the footer and empty state.
5. Whether to hash referenced local script files (e.g. `scripts/setup.js`) into the fingerprint in v0.2 or defer.

---

## 14. Things that will bite

- **GUI PATH.** Everything works from Xcode (which inherits your terminal env) and fails from Finder. Always test a build launched from Finder.
- **AirPlay Receiver** listens on 5000/7000 as the user; Flask defaults to 5000.
- **`npm run` hooks.** `predev`/`postdev` run automatically under npm; they must be shown and fingerprinted.
- **Interactive shell noise.** `zsh -l -i` prints banners, may prompt (oh-my-zsh updates), and can hang. Use sentinels and a timeout.
- **PID reuse.** Never signal a PID you looked up earlier without re-checking its start time.
- **Process groups from terminals.** Without the shell check, `killpg` on the wrong group closes the user's terminal tab.
- **Docker/OrbStack ports** belong to the VM helper process, not the project. Leave them in Other listeners until v1.0.
- **IPv6.** Vite and Node often bind `::1` only; `localhost` in the browser still works, `127.0.0.1` may not. Open URLs with `localhost`.
- **TCC prompts** for Desktop, Documents, iCloud Drive appear the first time a project there is scanned or started. Don't scan those folders until a project inside them is added.
- **`MenuBarExtra(.window)`** doesn't close on outside click when a sheet is open; present sheets in a separate window instead of inside the popover.
