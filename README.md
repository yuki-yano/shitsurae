<p align="center">
  <img src="Shitsurae/AssetSources/icon.png" alt="Shitsurae" width="256" />
</p>

# Shitsurae

[日本語](README.ja.md)

**Shitsurae** is a macOS workspace arranger that brings order to your desktop with a single command.

The name comes from the Japanese word *室礼（しつらえ）* — the traditional art of arranging a room with intention and harmony. Just as a physical space is carefully set for its purpose, Shitsurae lets you define and instantly reproduce your ideal digital workspace.

## What It Solves

- Rebuilding your window layout manually every morning
- Losing window positions when displays are connected or disconnected
- Slow context-switching with `Cmd+Tab` across many windows
- Repeating the same layout work for different tasks (coding, review, meetings, etc.)

Define your ideal setup in YAML, then apply it with one command:

```bash
shitsurae arrange work
```

## Key Features

### 1. One-command layout apply (`arrange`)

Define layouts in YAML, and `shitsurae arrange <name>` will:

- Launch apps that aren't running yet (`launch: true`)
- Move windows to the designated Spaces
- Position and resize each window to the specified frame
- Set initial focus after arrangement
- Update runtime slot state only with `--state-only`

Position and size accept flexible units: `%` (screen ratio), `pt` (logical points), `px` (physical pixels), `r` (0.0–1.0 ratio).

### 2. Keyboard-first workflow

Every operation is available from the keyboard. Default shortcuts:

| Action | Default | Description |
|--------|---------|-------------|
| Slot focus | `Cmd+1` – `Cmd+9` | Jump directly to a numbered window |
| Workspace switch | `Ctrl+1` – `Ctrl+9` | In virtual mode, switch the active logical workspace |
| Send window to workspace | `Alt+1` – `Alt+9` | In virtual mode, send the current window to a logical workspace |
| Next window | `Cmd+Ctrl+J` | Cycle forward within the current Space |
| Previous window | `Cmd+Ctrl+K` | Cycle backward within the current Space |
| Switcher | `Cmd+Tab` | Open the window switcher overlay |
| Snap presets | Configurable | Left half, right half, thirds, maximize, center, etc. |

All shortcuts are fully configurable in YAML. You can also disable specific shortcuts per app to avoid conflicts (e.g., `Cmd+1` in Discord).

### 3. Built-in window switcher

A custom switcher triggered by `Cmd+Tab` (configurable):

- Windows are listed in MRU (most recently used) order — the last-active window appears second, so a single `Cmd+Tab` press switches to the previous window (like Windows Alt+Tab)
- In virtual mode, activation is tracked at the OS level via `NSWorkspace.didActivateApplicationNotification`, so Dock clicks, Mission Control, and direct window clicks all update the MRU order
- Each candidate gets a quick key (`1`, `2`, `3`, `4`, …) for one-keystroke selection
- Releasing the modifier always confirms the current selection
- Configurable trigger, accept/cancel keys, and quick key string

`Cmd+Ctrl+J/K` uses a separate cycle order: slotted windows stay fixed first, then non-slotted windows follow in observed order for that Space. With `shortcuts.cycle.mode: overlay`, the same order can be shown in the overlay UI instead of switching immediately on each keypress.

### 4. Window snap actions

Built-in snap presets for quick window positioning:

- `leftHalf`, `rightHalf`, `topHalf`, `bottomHalf`
- `leftThird`, `centerThird`, `rightThird`
- `maximize`, `center`

Bind any of these to a global shortcut in your YAML config.

### 5. Virtual mode

When `mode.space: virtual` is enabled, `spaceID` is treated as a logical workspace ID rather than a macOS native Space number. All workspace management is performed on a single native Space by moving windows on/offscreen.

```yaml
mode:
  space: virtual
  followFocus: true  # default: true
```

#### Bootstrap

1. Run `shitsurae arrange <layout> --dry-run --json` and inspect `availableSpaceIDs`
2. Run `shitsurae arrange <layout> --state-only --space <id>` to initialize the active layout and active space
3. Make sure the tracked windows for that workspace are present on the host native Space, then run `shitsurae arrange <layout> --space <id>`

The GUI uses the same flow: *Initialize Active Space* (step 2) and *Apply Selected Space* (step 3).

#### Behavior

- `space current/list/switch` use the active virtual space as the source of truth
- `focus --slot`, cycle, and switcher only operate on tracked windows in the active virtual space
- `switcher list --json --include-all-spaces true` lists all tracked windows in the active layout
- `Ctrl+1`–`Ctrl+9` switch the active virtual workspace
- `Alt+1`–`Alt+9` / `window workspace <id>` reassign tracked windows between workspaces; windows sent away from the active space are moved offscreen instead of being minimized

#### Follow-focus

When `mode.followFocus` is enabled (default), focusing a managed window by any means — Dock click, Mission Control, direct click, `Cmd+Tab` — automatically switches to the virtual workspace that owns that window.

### 6. Menu bar + GUI app

Shitsurae runs as a standard macOS app with both a menu bar presence and a main window.

#### Menu bar

Always available from the system menu bar:

- **Layout submenus** — each defined layout appears as a submenu with:
  - *Apply All* — apply the layout to all Spaces
  - *Apply Current Space* — apply the layout to the currently active Space only
- **Open Shitsurae** — open the main window
- **Preferences…** — open the settings window
- **Open Config Directory** — reveal the config folder in Finder
- **Quit** — terminate the app

#### Main window

A full GUI with sidebar navigation: **Arrange**, **Layouts**, **General**, **Shortcuts**, **Permissions**, and **Diagnostics**.

<p align="center">
  <img src="https://github.com/user-attachments/assets/3adc77fe-03f4-4035-99d6-46ec116cf171" alt="Layout detail view" width="720" />
</p>
<p align="center">
  <img src="https://github.com/user-attachments/assets/8852c847-3091-4773-9c6c-5e8c4d1b6bfd" alt="Layout detail view (dashboard)" width="720" />
</p>
<p align="center">
  <img src="https://github.com/user-attachments/assets/89261418-4110-491f-8bc0-4920fe5de1af" alt="Shortcuts view" width="720" />
</p>

#### Window switcher overlay

<p align="center">
  <img src="https://github.com/user-attachments/assets/9bc0e59f-392a-4c0a-8ea1-2facc9d7b104" alt="Window switcher overlay" width="720" />
</p>

A floating overlay triggered by the switcher hotkey (`Cmd+Tab` by default):

- Displays candidate windows as horizontal cards, each showing:
  - App icon and window title
  - Quick-select key (`1`, `2`, `3`, …)
  - Bundle ID
  - Window thumbnail preview (requires Screen Recording permission) or an icon-based fallback
- The selected card is visually highlighted
- **Keyboard:** Tab / Shift+Tab to cycle, number keys for quick select, custom accept/cancel keys, or release the modifier to confirm
- **Mouse:** click any card to activate it

### 7. CLI + automation

The CLI exposes the same functionality for shell scripts and automation:

```bash
shitsurae arrange <layout> --dry-run --json    # Preview the execution plan
shitsurae arrange <layout> --json              # Apply a layout
shitsurae arrange <layout> --space 2 --json    # Apply to a specific Space
shitsurae arrange <layout> --state-only --json # Update runtime state only
shitsurae layouts list                         # List defined layouts
shitsurae validate --json                      # Validate config files
shitsurae diagnostics --json                   # Show system diagnostics
shitsurae space current --json                 # Current space info
shitsurae space list --json                    # List spaces
shitsurae space switch 2 --json                # Switch active space in virtual mode
shitsurae space recover --force-clear-pending --yes --json # Force-clear recovery state
shitsurae window current --json                # Current window info
shitsurae window workspace 2 --json            # In virtual mode, reassign a window to workspace 2
shitsurae window set --x 0% --y 0% --w 50% --h 100%   # Move + resize
shitsurae focus --slot 1                       # Focus by slot number
shitsurae focus --bundle-id com.apple.TextEdit # Focus by app
shitsurae switcher list --json                 # List switcher candidates
shitsurae switcher list --json --include-all-spaces true  # In virtual mode, list the whole active layout
```

`window workspace`, `window move`, `window resize`, and `window set` default to the focused window when you omit a selector. Selectors: `--window-id` (exact window), `--bundle-id` (app), `--title` (combined with `--bundle-id`).

### 8. Multi-display support

- Match displays by role (`primary` / `secondary`) or resolution conditions
- Define multiple resolution-specific layouts for the same Space — the first match is applied
- Seamless switching between MacBook-only and external-monitor setups without config changes

### 9. Config auto-reload

- Reads all `*.yml` / `*.yaml` files in the config directory (sorted by filename)
- Watches for file changes and auto-reloads
- On syntax errors, keeps the last valid config and shows errors in diagnostics

## Requirements

- macOS 15 (Sequoia) or later
- Accessibility permission (required)
- Screen Recording permission (optional — only for thumbnail overlays in the switcher)

No network communication is required for normal operation.

## Installation

### Install with Homebrew Cask

```bash
brew tap yuki-yano/shitsurae
brew install --cask shitsurae
xattr -dr com.apple.quarantine /Applications/Shitsurae.app
open /Applications/Shitsurae.app
```

This installs:

- `Shitsurae.app` to `/Applications`
- `shitsurae` CLI to Homebrew's `bin` directory so it is available on your shell `PATH`

> [!WARNING]
> `xattr -dr com.apple.quarantine /Applications/Shitsurae.app` is currently a required step for Homebrew installs.
> It removes macOS Gatekeeper quarantine for this unsigned app, so only run it if you trust `https://github.com/yuki-yano/shitsurae`.

Remove the app later with:

```bash
brew uninstall --cask shitsurae
brew zap shitsurae    # optional: also remove config and logs
```

### Direct app bundle launch (non-notarized builds)

If you distribute the `.app` directly, remove quarantine before first launch:

```bash
xattr -dr com.apple.quarantine Shitsurae.app
open Shitsurae.app
```

## Configuration

### Config directory

Resolved in order:

1. `$XDG_CONFIG_HOME/shitsurae/`
2. `~/.config/shitsurae/`

All `*.yml` / `*.yaml` files are loaded in filename order. Split configs by purpose (`work.yml`, `home.yml`, etc.) as you see fit.

### YAML schema / LSP

Enable YAML LSP validation and completion by adding this comment to your config file:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/yuki-yano/shitsurae/refs/heads/main/schemas/shitsurae-config.schema.json
```

### Basic example

```yaml
layouts:
  work:
    initialFocus:
      slot: 1
    spaces:
      - spaceID: 1
        windows:
          - slot: 1
            launch: false
            match:
              bundleID: com.apple.TextEdit
            frame:
              x: "0%"
              y: "0%"
              width: "50%"
              height: "100%"
          - slot: 2
            launch: false
            match:
              bundleID: com.apple.Terminal
            frame:
              x: "50%"
              y: "0%"
              width: "50%"
              height: "100%"
```

More samples in `samples/`.

### Window matching

Windows are matched using `match`:

- `bundleID` (required) — app bundle identifier
- `title` — match by `equals`, `contains`, or `regex`
- `profile` — Chromium browser profile directory name
- `role` / `subrole` — accessibility role
- `index` — window index within the app (1-based)
- `excludeTitleRegex` — exclude windows whose title matches

### Chromium browser profiles

For Chrome, Brave, Edge, and Chromium, use `match.profile` to target a specific browser profile:

```yaml
- slot: 1
  launch: true
  match:
    bundleID: com.google.Chrome
    profile: Default
  frame:
    x: "0%"
    y: "0%"
    width: "50%"
    height: "100%"
```

- `profile` is the directory name (`Default`, `Profile 1`, etc.), not the display name.
- With `launch: true`, Shitsurae starts the browser with `--profile-directory=<profile> --new-window`.
- `shitsurae window current --json` includes a `profile` field when resolvable.

### Mode

```yaml
mode:
  space: virtual    # native (default) | virtual
  followFocus: true # default: true — auto-switch workspace on window focus (virtual mode only)
```

### Space move method

Control how Shitsurae moves windows between Spaces:

```yaml
executionPolicy:
  spaceMoveMethod: drag
  spaceMoveMethodInApps:
    org.alacritty: displayRelay
```

- `drag` — drags the window while sending the macOS desktop-switch shortcut
- `displayRelay` — in multi-monitor `perDisplay` setups, temporarily relocates the window to another display, switches Space, then moves it back

### Ignore rules

Exclude apps or windows from arrangement and focus operations:

```yaml
ignore:
  apply:
    apps:
      - com.apple.finder
    windows:
      - bundleID: com.google.Chrome
        titleRegex: "^DevTools"
  focus:
    apps:
      - com.apple.SystemPreferences
```

### App behavior

```yaml
app:
  launchAtLogin: true
```

### Shortcut customization

```yaml
shortcuts:
  # Per-app enable/disable for Cmd+1..9 only
  focusBySlotEnabledInApps:
    com.hnc.Discord: false
    com.tinyspeck.slackmacgap: false
    org.alacritty: false

  # Virtual mode: send current window to a workspace (default Alt+1..9)
  moveCurrentWindowToSpace:
    - slot: 1
      key: 1
      modifiers: [alt]
    - slot: 2
      key: 2
      modifiers: [alt]

  # Virtual mode: switch the active workspace (default Ctrl+1..9)
  switchVirtualSpace:
    - slot: 1
      key: 1
      modifiers: [ctrl]
    - slot: 2
      key: 2
      modifiers: [ctrl]

  # Exclude from Cmd+Ctrl+J / K cycling
  cycleExcludedApps:
    - com.hnc.Discord

  # Exclude from Cmd+Tab switcher
  switcherExcludedApps:
    - com.tinyspeck.slackmacgap

  nextWindow:
    key: j
    modifiers: [cmd, ctrl]

  prevWindow:
    key: k
    modifiers: [cmd, ctrl]

  cycle:
    mode: overlay # direct | overlay
    quickKeys: "123456789"
    acceptKeys: [enter]
    cancelKeys: [esc]

  switcher:
    trigger:
      key: tab
      modifiers: [cmd]
    quickKeys: "1234567890qwertyuiopasdfghjklzxcvbnm"
    acceptKeys: [enter]
    cancelKeys: [esc]

  # Snap preset shortcuts
  globalActions:
    - key: H
      modifiers: [cmd, ctrl]
      action:
        type: snap
        preset: leftHalf
    - key: L
      modifiers: [cmd, ctrl]
      action:
        type: snap
        preset: rightHalf
```

## Build from source

```bash
swift build
```

Run tests:

```bash
swift test
```

Build the app bundle:

```bash
make app
```

Output:

- `dist/Shitsurae.app`
- Bundled CLI: `dist/Shitsurae.app/Contents/Resources/shitsurae`

## License

MIT
