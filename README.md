# Shitsurae

[日本語版はこちら (README.ja.md)](README.ja.md)

Shitsurae is a macOS workspace arranger for people who want repeatable window layouts.
You describe your ideal setup in YAML, then apply it with one command.

The name comes from a Japanese word that means arranging a room with intention and harmony.
This project brings that idea to your digital workspace.

## What It Solves

- Rebuilding your workspace manually every morning
- Losing window order when displays are connected or disconnected
- Slow context switching across apps and windows
- Repeating the same layout work for different tasks (work, review, meeting, etc.)

## Key Features

### 1. One-command layout apply (`arrange`)

- Launches apps when needed
- Moves windows to target Spaces
- Applies exact frames
- Optionally sets initial focus after apply

### 2. Keyboard-first workflow

Default shortcuts:

- `Cmd+1` ... `Cmd+9`: focus by slot
- `Cmd+Ctrl+J`: next window
- `Cmd+Ctrl+K`: previous window
- `Cmd+Tab`: switcher trigger

All shortcuts are configurable in YAML.

### 3. Built-in switcher

- Shows window candidates
- Supports quick keys for one-keystroke selection
- Can prioritize current Space

### 4. Menu bar + Dock app

- App launches as a normal macOS app (visible in Dock)
- Menu bar controls are always available
- Preferences and diagnostics are available from the app

### 5. CLI + automation

Use the same core behavior from shell scripts, terminal workflows, and CI-like local tasks.

### 6. Multi-display aware layouts

- Display matching by role (`primary` / `secondary`) and conditions
- First-match layout selection for display-specific definitions

### 7. Config auto reload

- Reads all `*.yml` / `*.yaml` files in config directory (sorted by filename)
- Watches config changes and auto reloads

## Requirements

- macOS 15 or later
- Accessibility permission (required)
- Screen Recording permission (required only when thumbnail-style overlay features are enabled)

Shitsurae does not require external network communication for normal operation.

## Build From Source

```bash
swift build
```

Run tests:

```bash
swift test
```

Build app bundle:

```bash
make app
```

Output:

- `dist/Shitsurae.app`
- Bundled CLI: `dist/Shitsurae.app/Contents/Resources/shitsurae`

## First Launch for Distributed Builds (Not Notarized)

If you distribute the `.app` directly and users download it, remove quarantine on first launch:

```bash
xattr -dr com.apple.quarantine Shitsurae.app
open Shitsurae.app
```

## Configuration Directory

Shitsurae resolves config directory in this order:

1. `$XDG_CONFIG_HOME/shitsurae/`
2. `~/.config/shitsurae/`

Sample configs:

- `samples/xdg-config-home/shitsurae/01-basic-layout.yaml`

## YAML Schema / LSP

You can enable YAML LSP validation and completion by pointing your config file at the schema:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/yuki-yano/shitsurae/refs/heads/main/schemas/shitsurae-config.schema.json
```

## Common Commands

```bash
shitsurae validate --json
shitsurae layouts list
shitsurae arrange <layoutName> --dry-run --json
shitsurae arrange <layoutName> --json
shitsurae arrange <layoutName> --space 2 --json
shitsurae diagnostics --json
shitsurae window current --json
shitsurae switcher list --json
```

## Space Move Method

Use `executionPolicy.spaceMoveMethod` to set the default backend, and `executionPolicy.spaceMoveMethodInApps` to override it per app bundle ID.

```yaml
executionPolicy:
  spaceMoveMethod: drag
  spaceMoveMethodInApps:
    org.alacritty: displayRelay
```

Available values:

- `drag`: drag the window and send the macOS desktop shortcut
- `displayRelay`: in multi-monitor `perDisplay` setups, temporarily move the window to another monitor, switch the target space, then move it back

## Chromium Browser Profiles

For `com.google.Chrome`, `com.brave.Browser`, `com.microsoft.edgemac`, and `org.chromium.Chromium`, you can pin a window to a specific browser profile with `match.profile`.

```yaml
layouts:
  browser:
    spaces:
      - spaceID: 1
        windows:
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

- `profile` is the Chromium profile directory name, not the display name.
- Typical values are `Default`, `Profile 1`, and `Profile 2`.
- With `launch: true`, Shitsurae starts Chromium with `--profile-directory=<profile> --new-window` and prefers the newly created window for placement.
- `shitsurae window current --json` includes a `profile` field when Shitsurae can resolve it.

## Slot Focus App Scope / Fallback

Use these `shortcuts` options to control `Cmd+1 ... Cmd+9` behavior:

```yaml
shortcuts:
  # Enable slot->app fallback when runtime state has no slot entry.
  focusBySlotFallbackEnabled: true

  # Per-frontmost-app switch for Cmd+1..9 only (true=enabled, false=disabled).
  focusBySlotEnabledInApps:
    com.hnc.Discord: false
    com.tinyspeck.slackmacgap: false

  # Exclude from Cmd+Ctrl+J / Cmd+Ctrl+K candidates.
  cycleExcludedApps:
    - com.hnc.Discord

  # Exclude from Cmd+Tab candidates.
  switcherExcludedApps:
    - com.tinyspeck.slackmacgap
```

If the slot target is not concretely present at dispatch time, `Cmd+1 ... Cmd+9` is passed through to the frontmost app / macOS instead of being consumed by Shitsurae.

`disabledInApps` is still available, but `focusBySlotEnabledInApps` is the better fit when you want pass-through for Cmd+1 ... Cmd+9 only.
