# Meerkat Runner — Design Handoff

The visual and interaction spec for Meerkat Runner, written for a SwiftUI build. It goes with `meerkat-runner-dev-guide.md`, which covers behaviour and architecture. When the two disagree on **behaviour**, the dev guide wins; when they disagree on **look**, this file wins.

Reference renders sit next to this file:

| File | Shows |
| --- | --- |
| `Main.png` | Menu dropdown (360 pt wide) |
| `AddServer.png` | Add server sheet with detected commands (540 pt) |
| `ScriptChanged.png` | Re-approval sheet when a start script changes (460 pt) |

The PNGs are rendered at 2× with a fallback sans font, because SF Pro isn't available off-Mac. **Build with the system font**, not the font in the images. Treat the PNGs as layout and hierarchy references, not pixel-exact comps.

Last updated: 2026-10-13

---

## 1. Principles

1. **Native first.** It should feel like it shipped with macOS: system font, materials, semantic colours, SF Symbols, standard controls. Don't hardcode a colour when a semantic one exists.
2. **Scan in one glance.** The dropdown answers "what's running and where" without hovering. Status is the leftmost thing on every row.
3. **Nothing runs by surprise.** Every surface that leads to running code shows the exact command in monospace before the button that runs it.
4. **Quiet by default.** Colour is reserved for state: green = running, orange = warning, red = error, accent = selection and the primary action. Everything else is greys.
5. **Light and dark mode are equal.** Every colour below has both values.

---

## 2. Tokens

### 2.1 Colour

Prefer the semantic SwiftUI or AppKit colour in the right column. Define the hex values as Asset Catalog colours (with Any/Dark appearances) only where no system colour fits.

| Token | Use | Light | Dark | SwiftUI |
| --- | --- | --- | --- | --- |
| `textPrimary` | Names, body | #1D1D1F | #F5F5F7 | `.primary` |
| `textSecondary` | Meta lines, captions, section headers | #5F5F64 | #AEAEB2 | `.secondary` |
| `textTertiary` | Hollow dot stroke, disabled | #8E8E93 | #636366 | `.tertiary` |
| `surfacePopover` | Dropdown background | #F6F6F7 | — | Window material (`MenuBarExtra(.window)` default); don't paint over it |
| `surfaceSheet` | Sheet background | #ECECEE | — | `Color(nsColor: .windowBackgroundColor)` |
| `surfaceCard` | Command list card, diff card | #FFFFFF | #2C2C2E | `Color(nsColor: .controlBackgroundColor)` |
| `fillControl` | Filter field, Start button, info callout | rgba(0,0,0,.06) | rgba(255,255,255,.08) | `Color.primary.opacity(0.06)` |
| `fillCode` | Resolved-script box | #F4F4F6 | rgba(255,255,255,.06) | `Color.primary.opacity(0.04)` |
| `separator` | Dividers, card borders | rgba(0,0,0,.10) | rgba(255,255,255,.12) | `Divider()` / `Color(nsColor: .separatorColor)` |
| `accent` | Selected row, primary button, Suggested badge, links | #0A64D6 | system | `Color.accentColor` — **follows the user's macOS accent**; the blue in the renders is only the default |
| `statusRunning` | Running dot | #1F8A4C | #30D158 | `Color(nsColor: .systemGreen)` |
| `statusStopped` | Hollow dot stroke | #8E8E93 | #636366 | `.tertiary` |
| `statusOther` | Other-listener dot | #8E8E93 | #636366 | `.tertiary` |
| `warningText` | LAN visible badge text, warning icon | #9A4A00 | #FFB35C | Asset colour |
| `warningFill` | LAN visible badge bg, warning icon tile | rgba(214,120,0,.14) | rgba(255,159,10,.20) | Asset colour |
| `errorText` | Crashed state, exit code | #B3261E | #FF6961 | Asset colour |
| `diffRemovedText` | Diff `−` line | #8F1D1D | #FF8A80 | Asset colour |
| `diffRemovedFill` | Diff `−` line bg | rgba(200,40,40,.08) | rgba(255,69,58,.16) | Asset colour |
| `diffAddedText` | Diff `+` line | #145C33 | #7EE2A8 | Asset colour |
| `diffAddedFill` | Diff `+` line bg | rgba(30,140,80,.10) | rgba(48,209,88,.16) | Asset colour |

`systemOrange` and `systemGreen` alone fail contrast for **text** on light backgrounds. Use them only for dots and icons, and the asset colours above for text.

### 2.2 Typography

macOS has no Dynamic Type, so use explicit sizes. Everything uses the system font except commands and diffs, which use `.monospaced` (SF Mono).

| Token | Size / weight | SwiftUI | Used for |
| --- | --- | --- | --- |
| `title` | 15 semibold | `.system(size: 15, weight: .semibold)` | Sheet titles |
| `header` | 14 semibold | `.system(size: 14, weight: .semibold)` | Dropdown "Servers" |
| `rowName` | 13 semibold | `.system(size: 13, weight: .semibold)` | Server names |
| `body` | 13 regular | `.body` | Menu actions, checkbox labels |
| `bodySmall` | 12.5 regular | `.system(size: 12.5)` | Sheet subtitles, filter field |
| `label` | 12 semibold | `.system(size: 12, weight: .semibold)` | Field labels ("Name", "How should it start?") |
| `meta` | 11.5 regular | `.system(size: 11.5)` | Row meta lines, hints, sources |
| `section` | 11 semibold, uppercase, tracking 0.2 | `.system(size: 11, weight: .semibold).tracking(0.2)` + `.textCase(.uppercase)` | Section headers |
| `badge` | 11 semibold | `.system(size: 11, weight: .semibold)` | Badges |
| `code` | 12.5 / 12 / 11.5 mono | `.system(size: 12.5, design: .monospaced)` | Command (12.5, semibold when selected), diff (12), resolved script (11.5) |
| `port` | 12 regular, tabular | `.system(size: 12).monospacedDigit()` | Port numbers in Other listeners |

### 2.3 Spacing, radii, sizes

Base unit 2 pt; most values are multiples of 4.

| Token | Value | Where |
| --- | --- | --- |
| Popover width | 360 | Fixed |
| Popover max height | 620, then the list scrolls | Header, filter and footer stay pinned |
| Header padding | top 12, trailing 12, bottom 10, leading 16 | |
| List inset | 6 horizontal | Row highlights sit 6 pt in from the popover edge |
| Row padding | 7 vertical, leading 10, trailing 8 | Other-listener rows: 6 vertical |
| Row gap (dot → text, text → actions) | 10 | |
| Row radius | 7 | Selection highlight |
| Status dot | 8 × 8 | Hollow: 1.5 stroke |
| Header icon button | 28 × 28, radius 6, glyph 15 | |
| Row icon button | 26 × 26, radius 6, glyph 12–13 | |
| Filter field | height 28, radius 7, glyph 12 | |
| Footer row | height 30, radius 6, padding 0/10 | |
| Section header | padding top 8 (first) / 4, bottom 4, leading 10 | |
| Section divider | inset 10 each side, 6 above and below | |
| Sheet padding | 24 | |
| Sheet vertical gap | 18 (Add), 16 (Re-approval) | |
| Card radius | 9 | Command list, diff |
| Card row padding | 12 vertical, 14 horizontal | |
| Icon tile | 40 × 40, radius 9, glyph 20 | Sheet headers |
| Badge | padding 2/6, radius 4 | |
| Text field | height 28, radius 6 | Use the native `TextField` with `.textFieldStyle(.roundedBorder)` |
| Buttons in sheets | min width 96, height ~28 | Native `Button` with `.controlSize(.large)` |

### 2.4 Icons (SF Symbols)

| Purpose | Symbol |
| --- | --- |
| Add server | `plus` |
| Settings | `gearshape` |
| Filter | `magnifyingglass` |
| Open in browser | `arrow.up.forward.square` |
| Logs | `text.alignleft` |
| Stop | `stop.fill` |
| Start | `play.fill` |
| Restart in Runner | `arrow.clockwise` |
| Folder / Add from folder | `folder` |
| Warning (re-approval, LAN) | `exclamationmark.triangle.fill` |
| Safety callout | `lock.shield` |
| Started in Terminal badge | `terminal` |
| Crashed | `xmark.octagon.fill` |
| Menu bar icon | Custom template image (a meerkat silhouette or a stacked-servers glyph), 18 × 18, `isTemplate = true`. Until the artwork exists, use `server.rack` |

---

## 3. Components

Build these as small SwiftUI views and reuse them everywhere.

### `StatusDot(state)`
8 pt circle. Running → filled `statusRunning`. Starting/stopping → `statusRunning` at 50% opacity with a 1 s opacity pulse (off when Reduce Motion is on). Stopped → hollow 1.5 pt `statusStopped` ring. Needs approval → filled `warningText`. Crashed → filled `errorText`. Other listener → filled `statusOther`. On a selected (accent-filled) row the dot is white. `accessibilityHidden(true)`; the state is spoken by the row's label.

### `Badge(text, style)`
Styles: `.warning` (LAN visible: `warningText` on `warningFill`), `.neutral` (Started in Terminal: `.secondary` on `fillControl`, `terminal` glyph at 10 pt), `.accent` (Suggested: accent text on accent at 10% opacity). Never truncate; badges hide before the meta line truncates.

### `IconButton(symbol, label, prominence)`
26 × 26 (row) or 28 × 28 (header). Rows: background `fillControl`; on a selected row, white glyph on white at 18% opacity. Header: no background until hover (`fillControl`). **Always** has `.help(label)` (tooltip) and `.accessibilityLabel(label)`.

### `ServerRow(project)`
Leading `StatusDot` · VStack(name `rowName`, meta `meta` in `.secondary`) · Spacer · trailing slot.

Meta line format: `Framework · localhost:port · uptime`. Use `localhost`, not `127.0.0.1`. Uptime as `6m`, `41m`, `2h 14m`, `3d`. Stopped rows: `Framework · command · :port`.

Trailing slot by state:

| State | Trailing (at rest) | Trailing (hover or selected) |
| --- | --- | --- |
| Running, managed | Badges (LAN visible) or nothing | Open · Logs · Stop |
| Running, started in Terminal | `Started in Terminal` badge | Open · Restart in Runner · Stop |
| Starting / Stopping | `ProgressView().controlSize(.small)` | same |
| Stopped | Start button (always visible) | Start |
| Crashed | `Exited (1)` in `errorText`, `meta` size | View logs · Start |
| Needs approval | `Review` button (bordered, small) | Review |

The renders show the `api` row with `PID 51022` at rest. Drop that: PID goes in the row's context menu and tooltip, not the row.

Selection: whole row fills `accent`, all text and glyphs turn white, meta at 90% white. Hover (not selected): `fillControl` background. Clicking the row body opens the server in the browser (running) or does nothing (stopped).

Context menu (right-click), running: Open in Browser, Copy URL, Show Logs, Reveal in Finder, Copy PID, Restart, Stop, Edit…, Remove from Runner…. Stopped: Start, Edit…, Reveal in Finder, Remove from Runner….

### `OtherListenerRow(listener)`
Dot · `processName` in `.primary` + ` — folder` in `.secondary` (folder abbreviated with `~`, middle-truncated) · Spacer · `:port` (`port` token). Hover reveals: Open, Copy URL, `Add as server…`. **No Stop, anywhere, including the context menu.**

### `SectionHeader(title, count?)`
Uppercase `section` style in `.secondary`. Optional count right-aligned in the same style. Not focusable.

### `CommandOption(proposal, selected)`
A row inside a card. Radio (native `Picker(.radioGroup)` or a custom radio) · command in `code` 12.5 (semibold when selected) · optional `Suggested` badge · Spacer · source file in `meta` `.secondary`. When selected, the resolved script appears below in a `fillCode` box, radius 6, padding 6/8, prefixed `runs: `. Unselected options show a single line with notes after the source (`package.json · needs a build first`).

### `DiffView(old, new, title)`
Card with a title bar (`label` style, `.secondary`, the key that changed, e.g. `scripts.dev`), then one row per line, padding 6/12, `code` 12 pt. Removed lines start with `−` (U+2212) and use the diff-removed colours; added lines start with `+` and use the diff-added colours. The prefix glyph is required so the meaning doesn't rest on colour alone. Long lines wrap; never scroll horizontally. Max height 220, then the card scrolls vertically.

### `InfoCallout(symbol, text)`
`fillControl` background, radius 8, padding 10/12, `lock.shield` 14 pt, text 12 pt `.secondary` with line spacing 2. Used for the "This command runs as you…" note.

---

## 4. Screens

### 4.1 Menu dropdown — `Main.png`

`MenuBarExtra { MenuView() }.menuBarExtraStyle(.window)`, fixed 360 wide.

Top to bottom:

1. **Header.** "Servers" (`header`) over a summary in `meta` `.secondary`: `3 running · 1 stopped · 2 other`. Omit zero counts (`2 running · 1 other`). Trailing: Add (`plus`) and Settings (`gearshape`) icon buttons.
2. **Filter field.** Placeholder "Filter by name or port". Filters all sections live, matching name, framework, folder and port (typing `30` matches `:3000`). Esc clears it, and a second Esc closes the popover. Hidden when there are fewer than 6 rows in total.
3. **Running.** `ServerRow`s sorted by name. Matched terminal-started servers sit in this section with their badge (no separate section).
4. **Needs approval.** Only when something is blocked. Rows show the `Review` button.
5. **Stopped.** Sorted by last run (most recent first).
6. **Other listeners.** Sorted by port. Collapsed to the first 5 with a "Show 7 more" row.
7. **Footer** (pinned, separator above): "Add Server from Folder…" with `⌘N` right-aligned in `.secondary`; "Stop All Managed Servers" (disabled when nothing managed is running); then a quiet "Made by Meerkat" link in `meta` `.tertiary`, centred, 8 pt below. Only managed servers count for "Stop all"; terminal-started ones are excluded and the label says so in its tooltip.

Dividers sit between sections, never above the first.

**Empty state** (no projects, no listeners): centred within a 220 pt tall area: `server.rack` at 28 pt `.tertiary`; "No dev servers running" (`rowName`); "Add a project folder and Runner will find how it starts." (`meta`, `.secondary`, max width 240); a bordered `Add Server from Folder…` button; then a 12 pt gap and "Monitor these sites once they're live → Meerkat" as a `.tertiary` link.

**Projects but nothing running:** no empty state. Show Stopped and Other as normal.

### 4.2 Add server sheet — `AddServer.png`

Present in its own window (`Window` scene or `NSPanel`), not inside the popover: a popover closes when focus moves. 540 wide, height fits the content.

1. **Header:** folder icon tile · `Add <folder name>` (`title`) over `~/path · Framework version · package manager (lockfile)` in `bodySmall` `.secondary` · trailing "Change folder…" link.
2. **"How should it start?"** (`label`) over a card of `CommandOption`s. The first is pre-selected. The last option is always "Custom command…", which expands to an argv text field (monospace) plus a "Run as shell command" checkbox. Ticking it shows a `warningText` line: "Shell commands can run anything your shell can. Only use this if you trust every part of the command."
3. **Monorepo variant:** above the card, a segmented control "This folder / Each workspace (3)". "Each workspace" swaps the card for a checklist of workspaces, each showing its own command.
4. **Name / Port** in a two-column grid. Port hint under the field in `meta` `.secondary`: "Next.js default · learned on first run", or "From --port in the script", or "From PORT in .env.local". If the port is already in use, the hint turns `warningText`: "In use by node (~/scratch/proxy)".
5. **Options** (native checkboxes): `Load .env.local (4 variables, values hidden)` (one row per env file found); `Start when I log in`; `Bind to localhost only` (hidden when the framework has no known flag, see dev guide §6.6).
6. Flexible space.
7. **InfoCallout:** "This command runs as you, inside `~/Sites/docs`. Nothing has run yet. If the script changes later, you'll be asked to approve it again."
8. **Buttons**, right-aligned: Cancel (`.cancelAction`, Esc) · Add · **Add and Start** (`.borderedProminent`, `.defaultAction`, Return).

**No proposals found:** the card shows a single message, "Couldn't find a start command in this folder", with the Custom command field already expanded.

### 4.3 Re-approval sheet — `ScriptChanged.png`

Own window, 460 wide.

1. **Header:** warning tile (`warningFill` background, `exclamationmark.triangle.fill` in `warningText`) · "The start script for `<name>` changed" (`title`) over "`<file>` was edited since you approved it on `<date>`. Review the new command before it runs." (`bodySmall`, `.secondary`). Date format: `Oct 2`, or `Oct 2, 2025` if it's not the current year.
2. **DiffView** of the old vs new resolved script, titled with the key that changed.
3. **Referenced files:** "New file referenced: `scripts/setup.js` · Reveal in Finder" (one line each, max 3, then "+2 more"). The "Last commit touching it" line is optional; show it only when the folder is a git repo, and compute it without running git (read `.git` metadata) or drop it.
4. Flexible space, then a separator, then a 16 pt gap.
5. **Buttons:** leading, a link-style "Run previous version" (hidden when the previous command can't be reconstructed exactly). Trailing: **Don't Run** (bordered, `.cancelAction` so Esc triggers it) and **Approve and Start** (`.borderedProminent`, **no** keyboard shortcut, so approving always takes a click).

When it's opened from an auto-start notification, the primary button reads "Approve and Start" all the same; never auto-start after approval without the click.

### 4.4 Not mocked yet — build to this spec

**Log window.** A `Window` per project, titled `<name> — Logs`, default 720 × 440, resizable. Toolbar: search field, "Copy All (Redacted)", "Clear", "Reveal Log File". Content: monospace 12 pt, ANSI colours mapped to the system palette, line height 1.35, text selectable. Auto-scrolls unless the user has scrolled up, in which case a "Jump to latest" pill appears bottom-centre. For terminal-started servers: centred `.secondary` text, "This server was started in Terminal, so its output is there. Restart it in Runner to see logs here." with a Restart in Runner button.

**Settings.** A standard `Settings` scene with tabs:
- **General:** Launch at login · On quit (Stop managed servers / Leave running / Ask) · Hide system listeners · Show port count in menu bar.
- **Environment:** a read-only view of the captured PATH (monospace, selectable) · "Reload Shell Environment" button with a last-loaded timestamp.
- **About:** app icon, version, "Made by Meerkat" link, Acknowledgements.

**Notifications.** Crash: title `<name> stopped unexpectedly`, body `Exited with code 1`, action `View Logs`. Needs approval (auto-start): title `<name> needs approval`, body `Its start script changed since you approved it.`, action `Review`.

**Menu bar icon.** Template image. When at least one server is running, show the count next to it (setting). When anything needs approval, add a small dot to the icon (template-safe: a drawn badge, not colour).

---

## 5. Interaction

| Key | Action (dropdown) |
| --- | --- |
| ↑ / ↓ | Move selection through actionable rows (skips headers) |
| Return | Open selected running server in browser; start a stopped one |
| ⌘. | Stop selected |
| ⌘R | Restart selected (Restart in Runner for terminal-started ones) |
| ⌘L | Show logs |
| ⌘C | Copy URL |
| ⌘N | Add server from folder |
| ⌘, | Settings |
| Esc | Clear filter, then close |
| Type any character | Focuses the filter |

Drag a folder from Finder onto the open dropdown → Add sheet for that folder. Show a dashed accent outline around the list while dragging.

Stop on a terminal-started server shows a confirmation popover anchored to the button: "Stop `<name>`? It was started in Terminal. The terminal stays open." [Cancel] [Stop]. Managed servers stop without confirmation.

Remove from Runner asks for confirmation as a sheet. If the server is running: "Stop it and remove?", with Cancel / Remove / Stop and Remove.

**Motion:** row insert/remove uses `.animation(.snappy(duration: 0.2))` with an opacity + move transition; state changes cross-fade the dot. Respect Reduce Motion (no pulse, no movement, opacity only).

---

## 6. Accessibility

- Each row is one accessibility element: label `"marketing-site, running, Astro on localhost port 4321, up 2 hours 14 minutes"`; the row actions are exposed as `accessibilityAction`s (Open, Logs, Stop, Restart in Runner).
- Every icon-only button has a label and a tooltip.
- Contrast: all text ≥ 4.5:1 in both appearances. Badges and diff text use the asset colours in §2.1, not raw system orange/green/red.
- Never rely on colour alone: hollow vs filled dots, the `−`/`+` diff prefixes, and badge text carry the meaning.
- Full keyboard operation of both sheets; focus starts on the selected command option in the Add sheet and on **Don't Run** in the Re-approval sheet.
- Increase Contrast: separators and card borders at 2× opacity.

---

## 7. Copy reference

| Where | Text |
| --- | --- |
| Header summary | `3 running · 1 stopped · 2 other` |
| Filter placeholder | `Filter by name or port` |
| Section headers | `Running`, `Needs approval`, `Stopped`, `Other listeners` (rendered uppercase) |
| Badges | `LAN visible`, `Started in Terminal`, `Suggested` |
| LAN tooltip | `Listening on all network interfaces. Other devices on your network can reach it.` |
| Footer | `Add Server from Folder…`, `Stop All Managed Servers`, `Made by Meerkat` |
| Safety callout | `This command runs as you, inside <path>. Nothing has run yet. If the script changes later, you'll be asked to approve it again.` |
| Re-approval title | `The start script for <name> changed` |
| Re-approval buttons | `Run previous version`, `Don't Run`, `Approve and Start` |
| Add sheet buttons | `Cancel`, `Add`, `Add and Start` |

Use the typographic ellipsis (…) and the middle dot (·) as shown. Use title case for buttons and menu-style actions (macOS convention) and sentence case for everything else. The renders show some actions in sentence case; follow this table instead.
