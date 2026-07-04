# The Button

A floating **Allow / Deny** panel for Claude Code permission prompts — answer
approvals from any window, on any screen, without hunting for the terminal.

When Claude Code needs your approval and you're working elsewhere, a small
Claude-styled panel fades in on whatever screen your mouse is on, showing
**exactly what you're approving** (the command, file path, or URL). Click
Allow or Deny and keep working. When you're already looking at the session's
window, the button stays out of your way.

Two components:

| Component | Covers |
|---|---|
| `TheButton.app` (macOS, native) | Every app and screen — floats system-wide |
| `vscode-extension/` | Inside VS Code/Cursor — answers fully in the background, cross-platform |

Both are driven by the same Claude Code hooks and event file.

## How it works

```
claude code ──PermissionRequest/PreToolUse/Notification hooks──▶ ~/.claude/the_button/event.json
     ▲                                                                    │ (cleared by PostToolUse/
     │                                                                    │  Stop/UserPromptSubmit/
     └──── targeted answer (Enter = Allow, Esc = Deny) ◀── your click ────┘  SessionEnd hooks)
```

- The **PermissionRequest** hook fires the moment a permission dialog appears
  and carries the tool name + input — that's the preview on the panel. The
  hook also records the session's process ancestry and tty, so the answer can
  be routed to the *exact* terminal that asked.
- Answers are delivered by the most precise route available:

| Session runs in | Delivery | Focus change? |
|---|---|---|
| tmux (default socket) | `tmux send-keys` to the matching pane | none |
| iTerm2 | AppleScript `write text` to the session by tty | none |
| Terminal.app | AppleScript selects the right tab by tty, then keystroke | brief, restored |
| VS Code / Cursor / editors | AX raises the window whose title matches the project, then keystroke | brief, restored |
| VS Code with the extension | `terminal.sendText` to the right integrated terminal | none |

- **Never types blind**: if the right target can't be reached (Automation
  denied, window won't focus, unknown host), the panel keeps the prompt and
  tells you why instead of sending a keystroke into the wrong app.

## Install (macOS app)

```bash
./install.sh                 # builds the app + wires hooks into ~/.claude/settings.json
open TheButton.app           # start the floating button (background app, no Dock icon)
```

Then:

1. **Accessibility** (required): enable *TheButton* under System Settings →
   Privacy & Security → Accessibility when prompted.
2. **Automation** (recommended): the first Terminal.app/iTerm2 answer asks to
   control that app — click Allow so answers can target the exact tab.
3. **Restart running claude sessions** so they pick up the hooks.
4. Optional: add `TheButton.app` to System Settings → General → Login Items.

Preview anytime: `TheButton.app/Contents/MacOS/TheButton --test`
Debug logging: run with `--debug` (logs to stderr).

## Install (VS Code extension)

```bash
cd vscode-extension
npx @vscode/vsce package     # produces a .vsix; install via "Install from VSIX"
```

Or open the folder in VS Code and press F5 for a development host. The
extension shows a notification with Allow/Deny inside VS Code and answers the
correct integrated terminal directly — no focus changes at all. Run the
"The Button: Install Hooks" command if you haven't run `install.sh`.

## Behavior details

- **Drag it anywhere** — the whole card is a drag handle. Position is stored
  as a fraction of the screen, so "top-right corner" means top-right of
  whichever display you're on. Visible across all Spaces and full-screen apps.
- **Hides intelligently**: hidden while the app hosting the session is
  frontmost — and if that app has several windows (e.g. two VS Code windows),
  only while the *session's* window is the focused one.
- **✕ dismisses one prompt** without answering; the next prompt shows again.
- Prompts clear automatically when answered in the terminal, when the tool
  finishes, or when the session ends; stale prompts from dead processes drop.
- Multiple concurrent sessions: last prompt wins the panel; a `clear` from one
  session never dismisses another session's pending prompt (hook writes are
  flock-serialized, with a session check on both sides).

## Caveats

- Allow sends Enter (the highlighted "Yes"). Options like "don't ask again"
  are still a terminal-only choice.
- VS Code without the extension: the keystroke path targets the right window,
  but if the Claude terminal isn't the active tab *within* that window's
  panel, use the extension — it targets the exact terminal by pid.
- tmux on a non-default socket (`tmux -L ...`) isn't discovered; the panel
  will tell you instead of guessing.

## Uninstall

```bash
./uninstall.sh
```

## Files

| File | Purpose |
|---|---|
| `Sources/main.swift` | Floating panel app (AppKit, zero dependencies) |
| `hook.py` | Claude Code hooks → event file (permreq/pretool/notify/clear) |
| `build.sh` / `install.sh` / `uninstall.sh` | Build, wire hooks, remove |
| `vscode-extension/` | Cross-platform VS Code companion extension |

MIT licensed. PRs welcome.
