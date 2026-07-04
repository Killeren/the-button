# The Button — Claude Code Approvals (VS Code extension)

Answer Claude Code permission prompts from inside VS Code — **in the
background**, without touching the terminal, changing focus, or synthesizing
keystrokes.

This is the cross-platform companion to
[The Button](../README.md), the macOS floating Allow/Deny panel that lives in
the same repository.

## What it does

The Button's `hook.py` (wired into `~/.claude/settings.json`) writes every
Claude Code permission prompt to a small event file,
`~/.claude/the_button/event.json`. This extension polls that file (300 ms) and:

- **Permission prompt** → a warning-colored status bar item
  (`$(bell) Claude: <tool>`) plus a non-modal notification with
  **Allow / Deny / Dismiss** buttons.
- **Allow** sends `\r` (Enter — confirms the highlighted "Yes" option) and
  **Deny** sends `\u001b` (Esc — declines) straight into the right integrated
  terminal via `terminal.sendText(text, false)`. The terminal is never
  focused or revealed; you keep typing wherever you were.
- **Claude waiting for input** → a quiet `$(watch) Claude is waiting` status
  bar item, no notification.
- **Prompt resolved elsewhere** (you answered in the terminal, or the macOS
  panel did) → everything clears automatically.

Stale clicks are safe: before acting, the extension re-reads the event file
and verifies the prompt is still the exact one the notification was created
for; otherwise it no-ops with an info message.

### Terminal targeting

The extension answers only when it can identify *the* terminal running that
Claude session, in this order:

1. A terminal whose shell **pid appears in the event's ancestor chain** (the
   shell is an ancestor of the `claude` process).
2. A **unique** terminal whose `creationOptions.cwd` equals the event's `cwd`.
3. The only terminal, when exactly one exists.

It never guesses among multiple candidates — if the session can't be
identified, you get an error notification instead of a keystroke in the wrong
shell.

## Commands

| Command | What it does |
| --- | --- |
| `The Button: Allow Pending Claude Prompt` (`theButton.allow`) | Send Enter to the pending prompt |
| `The Button: Deny Pending Claude Prompt` (`theButton.deny`) | Send Esc to the pending prompt |
| `The Button: Dismiss Pending Claude Prompt` (`theButton.dismiss`) | Hide the prompt locally (answer it yourself) |
| `The Button: Install Claude Code Hooks` (`theButton.installHooks`) | Wire `hook.py` into `~/.claude/settings.json` (same result as `install.sh`) |

Bind `theButton.allow` / `theButton.deny` to keys for one-keystroke approvals.

## Settings

- `theButton.eventFile` (string, default `""`): path to the event file.
  Empty means `~/.claude/the_button/event.json`.

## Install for development

No build step, no npm dependencies — plain JavaScript on the VS Code API.

- **Run from source:** open this folder in VS Code and press **F5**
  ("Run Extension"). A new Extension Development Host window starts with the
  extension loaded.
- **Package a .vsix:** `npx @vscode/vsce package` in this folder, then
  "Extensions: Install from VSIX…" (or `code --install-extension
  claude-code-the-button-0.1.0.vsix`).

Then run **The Button: Install Claude Code Hooks** once (or the repo's
`./install.sh` on macOS) and restart any running `claude` sessions.

## How it complements the macOS floating app

- **This extension** answers prompts **in the background inside VS Code**:
  no focus games, no AppleScript, no CGEvent keystrokes — just
  `terminal.sendText` into the correct integrated terminal. It also works on
  Linux (and eventually Windows).
- **The macOS floating app** covers everything else: Claude sessions in
  Terminal.app, iTerm2, tmux, or any other app, with a floating Allow/Deny
  panel that follows you across Spaces and hides while you're already looking
  at the session.

Both read the same `event.json` and both remember which event `ts` they
handled, so answering in one place clears the other on its next poll.

## Current limitations

- Requires the `hook.py` hooks to be installed in `~/.claude/settings.json`
  (use `theButton.installHooks` or the repo's `install.sh`).
- Hook installation is **macOS/Linux only for now** — `hook.py` shells out to
  `ps` to build the process ancestry. Windows support is pending.
- Only prompts from Claude sessions running in VS Code integrated terminals
  can be answered; sessions in external terminals are the macOS app's job.
- One prompt at a time: the event file is last-write-wins by design.
