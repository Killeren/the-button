# Changelog

## 0.2.0 — 2026-07-07

Decide mode + multi-session support.

- Watch the per-prompt event directory `~/.claude/the_button/events/`
  (configurable via `theButton.eventsDir`); every concurrent Claude session
  gets its own prompt instead of clobbering a shared file.
- **Decide mode**: when the hook is blocked awaiting a decision, answer by
  writing an answer file — Claude Code resolves the prompt directly, with no
  keystrokes and no terminal targeting (works over ssh, any platform). Falls
  back to the v0.1 `terminal.sendText` path when the dialog is already shown.
- Advertise a decide-capable heartbeat (`heartbeat-vscode.json`) so the hook
  knows to wait for this listener.
- Status bar shows a pending count; a QuickPick chooses among multiple pending
  prompts for the Allow/Deny/Dismiss commands.
- `installHooks` sets a 600s timeout on the `PermissionRequest` hook so a
  blocking decide wait is never killed early.
- Legacy single-file (`event.json`) mode kept as an automatic fallback for old
  `hook.py` installs.

## 0.1.0 — 2026-07-04

Initial release.

- Watch `~/.claude/the_button/event.json` (configurable via
  `theButton.eventFile`) and surface Claude Code permission prompts as a
  status bar item + Allow/Deny/Dismiss notification.
- Answer prompts in the background with `terminal.sendText` — Enter (`\r`)
  to allow, Esc (`\u001b`) to deny — targeting the terminal by shell pid in
  the event's ancestor chain, then by `cwd`, then the sole terminal; never
  guessing among multiple candidates.
- Stale-click protection: re-read and `ts`-verify the event before acting;
  handled/dismissed events never re-fire.
- Commands `theButton.allow` / `theButton.deny` / `theButton.dismiss` for
  keybinding users.
- `theButton.installHooks`: cross-platform (macOS/Linux) port of
  `install.sh` that merges the hook entries into `~/.claude/settings.json`
  and copies `hook.py` into `~/.claude/the_button/`.
