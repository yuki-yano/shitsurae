<p align="center">
  <img src="Shitsurae/AssetSources/icon.png" alt="Shitsurae" width="256" />
</p>

# Shitsurae

[日本語](README.ja.md)

**Shitsurae** is a macOS window manager built around its own virtual desktops (virtual workspaces).

The name comes from *shitsurai* (室礼) — the Japanese tradition of arranging a room's furnishings to suit the season and the occasion, making the space both beautiful and functional. Shitsurae brings that aesthetic to your digital workspace.

> [!NOTE]
> v2 is a ground-up rewrite that drops Mission Control / native macOS Spaces integration entirely in favor of self-managed virtual workspaces. See [Migrating from v1](#migrating-from-v1).

## Problems it solves

- Rearranging windows by hand every morning
- Layouts breaking when an external display connects or disconnects
- Hunting for the right window in a crowded `Cmd+Tab`
- Repeating the same layout work for each activity (coding, review, meetings)
- Slow Mission Control desktop-switch animations

Define your ideal arrangement in YAML and apply it with one command:

```bash
shitsurae arrange work
```

## How it works

Shitsurae never touches native macOS Spaces (Mission Control). Every virtual workspace lives on a single desktop: switching workspaces moves the target windows on-screen and parks the rest 1px outside the display edge.

- Workspace switch = coordinate moves, no animation, instant
- Independent of Mission Control and native desktop settings
- Dialogs, sheets, and other transient companion windows stay on-screen during a switch; their main window is temporarily protected from geometry changes and returns to its assigned workspace after the dialog closes

## Features

### 1. One-shot layout application (`arrange`)

Define layouts in YAML and run `shitsurae arrange <name>`:

- Auto-launches apps that aren't running (`launch: true`)
- Places windows at the configured position/size
- Records virtual workspace assignments and parks windows of inactive workspaces
- Sets the initial focus afterwards
- `--state-only` updates the runtime state without touching windows

Flexible units for position/size: `%` (screen ratio), `pt` (points), `px` (physical pixels), `r` (0.0–1.0 ratio).

### 2. Keyboard-first control

| Action | Default | Description |
|--------|---------|-------------|
| Focus slot | `Cmd+1` – `Cmd+9` | Jump straight to a numbered window |
| Switch workspace | `Ctrl+1` – `Ctrl+9` | Switch the active virtual workspace |
| Move window to workspace | `Alt+1` – `Alt+9` | Send the current window to a workspace |
| Next window | `Cmd+Ctrl+J` | Cycle forward within the active workspace |
| Previous window | `Cmd+Ctrl+K` | Cycle backward within the active workspace |
| Switcher | `Cmd+Tab` | Open the built-in window switcher |
| Snap | configurable | Preset placements (left half, maximize, …) |

Every shortcut is configurable in YAML, including per-app disabling (e.g. keep Discord's own `Cmd+1` working).

### 3. Built-in window switcher

- Windows in MRU order — the previous window sits second, so one `Cmd+Tab` flips back (like Alt+Tab on Windows)
- MRU tracking hooks `NSWorkspace.didActivateApplicationNotification`, so Dock clicks and direct clicks update the order too
- Quick keys (`1`, `2`, `3`, …) for one-keystroke selection
- Releasing the modifiers always commits the selection
- Selecting a window of another workspace switches there automatically
- Trigger, accept/cancel keys and the quick-key string are configurable

`Cmd+Ctrl+J/K` cycles in a different, stable order: slotted windows first, then the rest. Set `shortcuts.cycle.mode: overlay` for an overlay UI on top of that order.

### 4. Window snapping

`leftHalf` / `rightHalf` / `topHalf` / `bottomHalf` / `leftThird` / `centerThird` / `rightThird` / `maximize` / `center`, bindable to any global shortcut.

### 5. Follow-focus

With `mode.followFocus` (default on), focusing any managed window — Dock click, direct click, `Cmd+Tab` — automatically switches to its virtual workspace.

### 6. Menu bar + GUI app

- **Layout submenus** — *Apply All* / *Apply Current Space*
- **Open Shitsurae** — main window (Arrange / Layouts / General / Shortcuts / Permissions / Diagnostics)
- **Open Config Directory**
- **Quit** — restores every parked window on the way out

### 7. CLI and automation

The CLI talks to the app over a unix socket and launches the app automatically when needed.

```bash
shitsurae arrange <layout> --dry-run --json    # preview the plan (no changes)
shitsurae arrange <layout> --json              # apply a layout
shitsurae arrange <layout> --space 2 --json    # apply one workspace only
shitsurae arrange <layout> --state-only --json # update runtime state only
shitsurae layouts list                         # list defined layouts
shitsurae validate --json                      # validate config files
shitsurae diagnostics --json                   # diagnostics
shitsurae space current --json                 # active workspace info
shitsurae space list --json                    # workspace list
shitsurae space switch 2 --json                # switch the active workspace
shitsurae space recover --force-clear-pending --yes --json
shitsurae window current --json                # focused window info
shitsurae window workspace 2 --json            # reassign a window to workspace 2
shitsurae window set -x 0% -y 0% -w 50% -h 100%
shitsurae focus --slot 1
shitsurae focus --bundle-id com.apple.TextEdit
shitsurae switcher list --json
shitsurae switcher list --json --include-all-spaces true
```

`window workspace` / `window move` / `window resize` / `window set` target the focused window when no selector is given. Exact selector: `--window-id` + `--pid` + `--process-start-time` + `--bundle-id`. Rule selector: `--bundle-id`, optionally with `--pid` / `--title`.

### 8. Multi-display support

- Match displays by `primary` / `secondary` role or by resolution
- Reconciles window placement when displays connect/disconnect
- Displays are identified by display UUID — stable across reconnects

### 9. Config auto-reload

- Loads `*.yml` / `*.yaml` from the config directory in filename order
- Watches for changes and reloads automatically
- On syntax errors the last valid config stays active; errors show up in Diagnostics

## Requirements

- macOS 15 (Sequoia) or later
- Accessibility permission (required)
- Screen Recording permission (optional — switcher thumbnails only)

No network access is needed in normal operation.

## Architecture

v2 is a two-process design:

- **Shitsurae.app** — menu-bar resident GUI; the single owner of virtual workspace state; hotkeys, switcher, follow-focus, config reload
- **shitsurae CLI** — a thin client connected over a unix domain socket

The v1 resident agent (ShitsuraeAgent + XPC + launchctl) is gone.

## Installation

### Homebrew Cask

```bash
brew tap yuki-yano/shitsurae
brew install --cask shitsurae
xattr -dr com.apple.quarantine /Applications/Shitsurae.app
open /Applications/Shitsurae.app
```

This installs:

- `Shitsurae.app` into `/Applications`
- the `shitsurae` CLI symlinked into Homebrew's `bin`

> [!WARNING]
> The distributed app is not notarized; run `xattr -dr com.apple.quarantine /Applications/Shitsurae.app` once before first launch, and only if you trust `https://github.com/yuki-yano/shitsurae`.

To uninstall:

```bash
brew uninstall --cask shitsurae
brew zap shitsurae    # optional: also removes config and logs
```

### Direct `.app` distribution (no notarization)

```bash
xattr -dr com.apple.quarantine Shitsurae.app
open Shitsurae.app
```

## Configuration

### Config directory

1. `$XDG_CONFIG_HOME/shitsurae/`
2. `~/.config/shitsurae/`

All `*.yml` / `*.yaml` files load in filename order; split them as you like (`work.yml`, `home.yml`, …).

### YAML Schema / LSP

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
      - spaceID: 2
        windows:
          - slot: 1
            launch: false
            match:
              bundleID: com.apple.Notes
            frame:
              x: "0%"
              y: "0%"
              width: "100%"
              height: "100%"
```

`spaceID` is the logical virtual-workspace number. More samples live in `samples/`.

### Getting started

Run `shitsurae arrange <layout>` once — it launches, places and tracks every window and parks inactive workspaces. *Apply All* in the GUI does the same.

- The runtime state is discarded every time the app quits; start each session with an apply
- `--dry-run --json` previews the plan and `availableSpaceIDs`
- `--state-only` builds tracking state without moving windows (advanced; normally unnecessary)

### Window matching

- `bundleID` (required)
- `title` — `equals` / `contains` / `regex`
- `profile` — Chromium browser profile directory name
- `role` / `subrole` — accessibility roles
- `index` — window index within the app (1-based)
- `excludeTitleRegex`

> [!IMPORTANT]
> When the same `bundleID` appears in multiple slots, every one of those slots must carry a discriminator (`title` / `profile` / `index`). Ambiguous matchers are a config-load error in v2 — they were the root cause of v1's window-tracking corruption.

### Chromium profiles

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

`profile` is the profile *directory* name (`Default`, `Profile 1`, …), not the display name. With `launch: true` the browser starts with `--profile-directory=<profile> --new-window`.

### Mode

```yaml
mode:
  followFocus: true # default: true
```

### Ignore rules

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
  focusBySlotEnabledInApps:
    com.hnc.Discord: false

  moveCurrentWindowToSpace:
    - slot: 1
      key: "1"
      modifiers: [alt]

  switchVirtualSpace:
    - slot: 1
      key: "1"
      modifiers: [ctrl]

  cycleExcludedApps:
    - com.hnc.Discord

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

## Migrating from v1

1. **Config**: delete these keys (they are load errors now):
   - `mode.space` (always virtual; `mode.followFocus` still works)
   - `executionPolicy` (whole section)
2. **Runtime state**: unsupported or corrupt state is preserved and startup stops instead of assuming no windows are parked. Quit the previous version normally to restore its windows, then move `~/.local/state/shitsurae/runtime-state.json` aside and apply a v2 layout.
3. **Same app in multiple slots**: each slot now needs a `title` / `profile` / `index` discriminator.
4. **ShitsuraeAgent is gone**: you can delete `~/Library/LaunchAgents/com.yuki-yano.shitsurae.agent.plist` if it remains.

## Building from source

```bash
swift build
swift test
make app
```

Outputs:

- `dist/Shitsurae.app`
- bundled CLI: `dist/Shitsurae.app/Contents/Resources/shitsurae`

## License

MIT
