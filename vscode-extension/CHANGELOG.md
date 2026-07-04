# Changelog

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
