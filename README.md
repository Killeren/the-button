# The Button

A floating **Allow / Deny** panel for Claude Code permission prompts — answer
approvals from any window, on any screen, without hunting for the terminal.

When Claude Code needs your approval and you're working elsewhere, small
Claude-styled cards fade in on whatever screen your mouse is on, each showing
**exactly what you're approving** (the command, file path, or URL) and **which
session** is asking. Click Allow or Deny and keep working. When you're already
looking at a session's window, that card stays out of your way.

Two components, driven by the same Claude Code hooks:

| Component | Covers |
|---|---|
| `TheButton.app` (macOS, native) | Every app and screen — floats system-wide |
| `vscode-extension/` | Inside VS Code/Cursor — answers in the background, cross-platform |

## How it works

The heart of v0.2 is **decide mode**. A `PermissionRequest` hook fires the
instant a permission dialog is due and *blocks*, waiting for your answer.
Claude Code shows a quiet `Waiting for permission…` in the terminal meanwhile.
Your click is written to a small answer file; the hook returns the decision
straight to Claude Code — so **no keystrokes are ever synthesized and no window
is ever focused**. It works in every terminal, including ones the old keystroke
path couldn't reach (Ghostty, kitty, Alacritty, ssh sessions, …).

```
                        ┌───────────── decide mode (default) ─────────────┐
claude code             │  hook blocks ⇢ you click ⇢ answer file ⇢ hook   │
   │ PermissionRequest  │  returns {allow|deny} to Claude Code directly    │
   ▼ (blocks)           └──────────────────────────────────────────────────┘
events/<session>--p<pid>.json ──▶  panel shows one card per prompt
   ▲                                   │ Allow / Deny / Always allow / note
   └────────── answers/<same>.json ◀───┘
```

If no decide-capable listener is running (the app/extension is closed, or an
older `hook.py` is installed), the hook doesn't block — Claude Code shows its
normal dialog and the panel falls back to the **keystroke path** below. The
same happens the moment you focus the asking session's own terminal: the card
steps aside and hands you the native dialog.

**Keystroke fallback** (also used for any `mode:"keystroke"` card):

| Session runs in | Delivery | Focus change? |
|---|---|---|
| tmux (default socket) | `tmux send-keys` to the matching pane | none |
| iTerm2 | AppleScript `write text` to the session by tty | none |
| Terminal.app — Allow | `do script` writes a newline to the tab's tty | none |
| Terminal.app — Deny | selects the tab by tty, then Esc | brief, restored |
| VS Code / Cursor / editors | AX raises the project's window, then keystroke | brief, restored |
| VS Code with the extension | writes to the right integrated terminal | none |

**Never types blind**: if the right target can't be reached (Automation
denied, window won't focus, unknown host), the card keeps the prompt and tells
you why instead of sending a keystroke into the wrong app.

## What each card shows and does

- **Session identity** — project folder, tty, and a per-session accent dot, so
  three simultaneous prompts are three distinguishable cards, not one.
- **Allow / Deny**, plus a `▾` on each (decide mode only):
  - **Allow ▾ → Always allow** — persists a project-local rule to
    `.claude/settings.local.json` (Bash → the exact command; other tools →
    tool-wide), so Claude never asks for that again. Same file the terminal's
    own "don't ask again" writes.
  - **Deny ▾ → Deny with note** — send a one-line reason back to Claude.
- **✕** dismisses one card (you'll answer it in the terminal); the rest stay.
- An **elapsed timer** ("waiting 45s") and the live count in the menu bar.

Up to four cards stack at once; a "+N more waiting" footer counts the rest.

## Menu bar & shortcuts

The menu bar item (`✳`) shows the pending count and a menu to:
jump to any waiting prompt, **Pause The Button**, toggle the new-prompt sound,
**Launch at Login**, and **Quit**.

Global hotkeys answer the top card from anywhere:
**⌃⌥⏎ = Allow**, **⌃⌥⎋ = Deny**.

## Install (macOS app)

```bash
./install.sh                 # builds the app + wires hooks into ~/.claude/settings.json
open TheButton.app           # start the floating button (background app, no Dock icon)
```

Then:

1. **Accessibility** (required for the keystroke fallback + reliable focus):
   enable *TheButton* under System Settings → Privacy & Security → Accessibility
   when prompted.
2. **Automation** (recommended): the first Terminal.app/iTerm2 answer asks to
   control that app — click Allow so answers can target the exact tab.
3. **Restart running claude sessions** so they pick up the hooks.
4. Optional: use the menu bar → **Launch at Login** (keep `TheButton.app` where
   it is — an ad-hoc–signed login item is tied to its location on disk).

Preview the UI anytime: `TheButton.app/Contents/MacOS/TheButton --test`
Debug logging: run with `--debug` (logs to stderr).

## Install (VS Code extension)

```bash
cd vscode-extension
npx @vscode/vsce package     # produces a .vsix; install via "Install from VSIX"
```

Or open the folder in VS Code and press F5 for a development host. The
extension shows an Allow/Deny notification and answers the right integrated
terminal directly — no focus changes. Run **The Button: Install Hooks** if you
haven't run `install.sh`. When several prompts are pending, the Allow/Deny
commands show a picker.

## Behavior details

- **Drag anywhere** — the whole stack is a drag handle. Position is stored as a
  fraction of the screen, so "top-right" means top-right of whichever display
  you're on. Visible across all Spaces and full-screen apps.
- **Hides intelligently, per card** — a card hides only while *its* session's
  window is the one you're focused on (with several windows, only the matching
  one). Other sessions' cards stay put.
- **Multiple concurrent sessions** are first-class: every prompt is its own
  file and its own card; answering or clearing one never touches another.
- Prompts clear automatically when answered, when the tool finishes, or when
  the session ends; prompts from dead processes drop.

## Caveats

- **Allow = the highlighted "Yes".** "Always allow" writes a project-local rule
  for you; deeper dialog options remain a terminal choice.
- A decide-mode answer reaches the terminal ~0.3–0.5s after you focus it (the
  hook is releasing the native dialog). Answering from the panel is instant.
- tmux on a non-default socket (`tmux -L …`) isn't discovered by the keystroke
  fallback; decide mode doesn't care which socket you use.
- The legacy single `event.json` is still written for one release so older
  installs keep working, and will be removed in a future version.

## Uninstall

```bash
./uninstall.sh
```

## Files

| File | Purpose |
|---|---|
| `Sources/*.swift` | Floating panel app (AppKit, zero dependencies) |
| `hook.py` | Claude Code hooks → decide answers + event files |
| `build.sh` / `install.sh` / `uninstall.sh` | Build, wire hooks, remove |
| `vscode-extension/` | Cross-platform VS Code companion extension |

MIT licensed. PRs welcome.
