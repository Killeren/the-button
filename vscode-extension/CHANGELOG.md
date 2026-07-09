# Changelog

## 0.2.1 — 2026-07-09

Cards stay answerable; hook fixes now reach installed users automatically.

- **Fixed (app):** a prompt's floating card could be silently downgraded to a
  bare Allow/Deny card — losing its ▾ Always-allow / Deny-with-note options — or
  retired for good, after you focused the session's editor/terminal window and
  switched away. A decide card now keeps its full options no matter how often
  you glance at the session: the card simply hides while that window is
  frontmost and returns unchanged when you look away. ✕ still hands the prompt
  back to the terminal.
- **Fixed (app):** the card no longer flickers around focus changes — it starts
  hidden when its prompt arrives while you're already on the session, appears
  the instant you switch away, and drops the instant you switch back (no
  fade-out lingering over the window, no one-frame flash while the accessibility
  probe settles).
- **hook.py v3:** a decide card no longer lingers (up to the 10-minute hook
  window) after its tool was approved without touching the panel — auto-accept
  mode, an allow-rule, or an agent. PostToolUse now retires that tool's own card
  even while its hook is still blocking, and the freed hook exits cleanly instead
  of resurrecting the card as a keystroke prompt. A parallel prompt you're still
  deciding is untouched. PreToolUse also clears a session's answered
  keystroke-mode events immediately (instead of waiting for PostToolUse), so a
  fallback card can't linger and send a stray keystroke into a running turn.
- **Extension:** on activation, an already-installed
  `~/.claude/the_button/hook.py` is auto-refreshed when the bundled copy is
  newer (compared via the new `HOOK_VERSION` stamp) — future hook fixes ship
  with normal extension auto-updates, no re-running "Install Claude Code
  Hooks". Never installs unsolicited.

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
