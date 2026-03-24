# muxwatch

An event-driven tmux watcher that monitors Claude Code sessions via hooks and shows live status in the tmux status bar:

- **▶ blue** — running (generating, tool use, thinking)
- **✓ green** — done (finished, waiting for next prompt)
- **! red** — need input (permission dialog)
- **~ dim** — idle (fresh prompt, no task yet)

When Claude Code exits or muxwatch stops, the original window name is restored.

## Architecture

```
Claude Code hooks  →  muxwatch notify  →  event socket  →  daemon
                                                             |
                                          broadcast socket → waybar
```

No polling. Claude Code hooks push state changes to the daemon instantly via a Unix socket.

## Install

```bash
go install github.com/matteobortolazzo/claude-tools/muxwatch@latest
```

Or build from source:

```bash
git clone https://github.com/matteobortolazzo/claude-tools.git
cd claude-tools/muxwatch
make build
```

## Setup

### 1. Enable the plugin

**Via marketplace (recommended):**

```bash
# Register the repo as a marketplace (works with private repos too)
claude plugin marketplace add matteobortolazzo/claude-tools

# Install the plugin (persists across sessions)
claude plugin install muxwatch
```

To update later: `claude plugin update muxwatch`

**Manual (per-session):**

```bash
claude --plugin-dir /path/to/muxwatch/plugin
```

### 2. Start the daemon

```bash
muxwatch        # run in background or a dedicated pane
muxwatch -v     # verbose logging
```

| Flag | Default | Description |
|------|---------|-------------|
| `-v` | `false` | Verbose logging |
| `-event-socket` | `$XDG_RUNTIME_DIR/muxwatch-events.sock` | Event socket for hook notifications |
| `-socket` | `$XDG_RUNTIME_DIR/muxwatch.sock` | Broadcast socket for waybar clients |
| `-sweep` | `30` | Stale session sweep interval in seconds |
| `-style-running` | `fg=blue,dim` | tmux style for running state (inactive windows) |
| `-style-done` | `fg=green,dim` | tmux style for done state (inactive windows) |
| `-style-input` | `fg=red,dim` | tmux style for need-input state (inactive windows) |
| `-style-idle` | `dim` | tmux style for idle state (inactive windows) |
| `-symbol-running` | `▶` | Symbol shown in status bar indicator |
| `-symbol-done` | `✓` | Symbol shown in status bar indicator |
| `-symbol-input` | `!` | Symbol shown in status bar indicator |
| `-symbol-idle` | `~` | Symbol shown in status bar indicator |

### Waybar module

`muxwatch waybar` connects to the daemon's broadcast socket, reads the current state, prints a single line of JSON in the [Waybar custom module protocol](https://github.com/Alexays/Waybar/wiki/Module:-Custom), and exits.

```bash
muxwatch waybar
```

| Flag | Default | Description |
|------|---------|-------------|
| `-socket` | `$XDG_RUNTIME_DIR/muxwatch.sock` | Broadcast socket path |
| `-symbol-running` | `▶` | Symbol for running count |
| `-symbol-done` | `✓` | Symbol for done count |
| `-symbol-input` | `!` | Symbol for need-input count |

#### Waybar config

```jsonc
"custom/muxwatch": {
    "exec": "muxwatch waybar",
    "return-type": "json",
    "interval": 1
}
```

Then add `"custom/muxwatch"` to your bar's modules.

#### Waybar styling

The module sets a `class` based on the highest-priority status: `need-input` > `running` > `done` > `idle`.

```css
#custom-muxwatch {
    padding: 0 8px;
}

#custom-muxwatch.need-input {
    color: #f38ba8;
}

#custom-muxwatch.running {
    color: #89b4fa;
}

#custom-muxwatch.done {
    color: #a6e3a1;
}

#custom-muxwatch.idle {
    color: #6c7086;
}
```

## How it works

### Hook-to-status mapping

| Hook Event | Status | Notes |
|------------|--------|-------|
| `SessionStart` | Idle | Fresh session, no task yet |
| `UserPromptSubmit` | Running | User just submitted a prompt |
| `Notification` (permission_prompt) | NeedInput | Permission dialog shown |
| `PreToolUse` (when NeedInput) | Running | Permission was granted |
| `Stop` | Done | Claude finished responding |
| `SessionEnd` | Remove | Restore window, clean up |

### Stale session sweep

Every 30s (configurable), the daemon checks if tracked pane IDs still exist in tmux. If a pane is gone (e.g. Claude crashed without firing `SessionEnd`), the window is restored.

### Custom status-format integration

muxwatch exposes two per-window user variables for custom `status-format` configs:

- `@muxwatch-symbol` — the status symbol (`~`, `▶`, `✓`, `!`)
- `@muxwatch-style` — the status style (e.g. `fg=blue,dim`)

Use them in your `status-format` to replace the default indicator and color:

```
# Replace ● with muxwatch symbol when active, keep ● otherwise
#{?#{@muxwatch-symbol},#{@muxwatch-symbol},●}

# Use muxwatch style when active, fall back to default color
#{?#{@muxwatch-style},#[#{@muxwatch-style}],#[fg=brightblack]}
```

For users with the default tmux status format, muxwatch automatically prepends `#{@muxwatch-symbol}` to `window-status-format` and `window-status-current-format` during tracking, and restores them on cleanup.

### Manual window names

muxwatch respects manually set window names:

- If a window has `automatic-rename` set to `off` (i.e. you renamed it with `Ctrl+b ,`), muxwatch will show status indicators but keep your window name.
- If you rename a window while Claude is running, muxwatch detects the change and stops overriding your name.
- When Claude exits, manually-named windows keep their name (indicators are removed).

### Daemon restart

If the daemon restarts while Claude sessions are active, it re-discovers them on the next hook event — a `ListPanes` call maps the `$TMUX_PANE` to the correct window.

## Troubleshooting

**No status updates**: Ensure the plugin is loaded (`claude plugin list` or `claude --plugin-dir ./plugin`). Check that `muxwatch notify` can reach the event socket (`muxwatch -v` shows the socket path).

**Names not restoring**: muxwatch restores names on clean exit (Ctrl+C / SIGTERM) and via the stale sweep. If it was killed with SIGKILL, manually rename windows or restart tmux.

**Daemon not running**: `muxwatch notify` fails silently (exit 0) — Claude Code is never blocked.

### Verbose mode

When running with `-v`, muxwatch logs task names derived from pane titles to stderr. These titles may reflect file paths, command output, or other workspace context. Task names and window names are truncated to 50 characters in log output to limit exposure.

If verbose logs are persisted (e.g. by a process supervisor), direct output to a user-owned file with restricted permissions:

```bash
muxwatch -v 2>~/.local/state/muxwatch.log
```

## License

MIT
