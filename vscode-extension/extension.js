'use strict';

// The Button — Claude Code Approvals (VS Code companion).
//
// Watches the event file written by hook.py (~/.claude/the_button/event.json)
// and answers Claude Code permission prompts IN THE BACKGROUND via
// terminal.sendText — no focus changes, no synthesized keystrokes.
//
// Semantics mirrored from the macOS floating app (Sources/main.swift):
//   - Enter ("\r") confirms the highlighted (first/Yes) option; Esc declines.
//   - One event file, last-write-wins; a handled ts must never re-fire.
//   - Stale events (claude_pid no longer alive) are dropped.

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');

const POLL_INTERVAL_MS = 300;
const DETAIL_MAX = 80;
const ENTER = '\r';
const ESCAPE = '\u001b';

let statusItem = null; // vscode.StatusBarItem
let watchedPath = null; // absolute path currently passed to fs.watchFile
let lastHandledTs = 0; // ts of the last answered/dismissed event
let lastNotifiedTs = 0; // ts of the last event we popped a notification for
let pendingEvent = null; // current unanswered "permission" event, or null

// ---------------------------------------------------------------------------
// Event file
// ---------------------------------------------------------------------------

function defaultEventFile() {
  return path.join(os.homedir(), '.claude', 'the_button', 'event.json');
}

function resolveEventFile() {
  let configured = '';
  try {
    configured = vscode.workspace.getConfiguration('theButton').get('eventFile', '');
  } catch (_e) {
    /* configuration unavailable: fall through to default */
  }
  if (typeof configured === 'string' && configured.trim() !== '') {
    let p = configured.trim();
    if (p === '~' || p.startsWith('~/') || p.startsWith('~\\')) {
      p = path.join(os.homedir(), p.slice(1));
    }
    return p;
  }
  return defaultEventFile();
}

/** Defensive read: returns a parsed event object or null, never throws. */
function readEventFile(filePath) {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed;
    }
  } catch (_e) {
    /* missing file, partial write, bad JSON: treat as no event */
  }
  return null;
}

function eventTs(ev) {
  return ev && typeof ev.ts === 'number' ? ev.ts : 0;
}

/** True when the event's claude process is known to be gone. */
function claudeIsDead(ev) {
  const pid = ev && typeof ev.claude_pid === 'number' ? ev.claude_pid : 0;
  if (!Number.isInteger(pid) || pid <= 0) return false; // unknown: keep the event
  try {
    process.kill(pid, 0); // signal 0 = existence check only
    return false;
  } catch (err) {
    return !(err && err.code === 'EPERM'); // EPERM: alive but not ours
  }
}

function truncate(text, max) {
  const s = String(text || '').replace(/\s+/g, ' ').trim();
  return s.length > max ? s.slice(0, max) + '…' : s;
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

function showStatus(text, warning, tooltip) {
  if (!statusItem) return;
  statusItem.text = text;
  statusItem.tooltip = tooltip || undefined;
  statusItem.backgroundColor = warning
    ? new vscode.ThemeColor('statusBarItem.warningBackground')
    : undefined;
  statusItem.show();
}

function hideStatus() {
  if (statusItem) statusItem.hide();
}

function markHandled(ts) {
  if (ts) lastHandledTs = ts;
  pendingEvent = null;
  hideStatus();
}

// ---------------------------------------------------------------------------
// Event dispatch
// ---------------------------------------------------------------------------

function handleEvent(ev) {
  if (!ev) return;
  const ts = eventTs(ev);

  if (ev.type === 'clear' || (ts !== 0 && ts === lastHandledTs)) {
    pendingEvent = null;
    hideStatus();
    return;
  }

  if (ev.type === 'permission') {
    if (claudeIsDead(ev)) {
      pendingEvent = null;
      hideStatus();
      return;
    }
    pendingEvent = ev;
    const toolName = String(ev.tool_name || 'permission');
    showStatus(
      '$(bell) Claude: ' + toolName,
      true,
      truncate(ev.detail || ev.message, 200) || 'Claude Code is asking for permission'
    );
    if (ts !== lastNotifiedTs) {
      lastNotifiedTs = ts;
      showPermissionNotification(ev);
    }
    return;
  }

  if (ev.type === 'notify') {
    if (claudeIsDead(ev)) {
      pendingEvent = null;
      hideStatus();
      return;
    }
    pendingEvent = null;
    showStatus(
      '$(watch) Claude is waiting',
      false,
      truncate(ev.message, 200) || 'Claude Code is waiting for input'
    );
  }
}

function showPermissionNotification(ev) {
  const ts = eventTs(ev);
  const toolName = String(ev.tool_name || 'a tool');
  const detail = truncate(ev.detail || ev.message, DETAIL_MAX);
  const message =
    'Claude needs permission: ' + toolName + (detail ? ' — ' + detail : '');

  Promise.resolve(
    vscode.window.showWarningMessage(message, 'Allow', 'Deny', 'Dismiss')
  )
    .then((choice) => {
      if (!choice) return undefined; // notification closed/expired: leave event alone

      // The click may arrive long after the notification appeared. Re-read
      // the event file and only act if it is still the exact same event.
      const current = readEventFile(watchedPath || resolveEventFile());
      if (
        !current ||
        current.type !== 'permission' ||
        eventTs(current) !== ts ||
        eventTs(current) === lastHandledTs
      ) {
        vscode.window.showInformationMessage(
          'The Button: that Claude prompt is no longer pending.'
        );
        return undefined;
      }

      if (choice === 'Allow') return respond(current, ENTER);
      if (choice === 'Deny') return respond(current, ESCAPE);
      markHandled(eventTs(current)); // Dismiss: hide locally, answer in terminal yourself
      return undefined;
    })
    .then(undefined, (err) => {
      console.error('The Button: notification handling failed:', err);
    });
}

// ---------------------------------------------------------------------------
// Terminal targeting + answering
// ---------------------------------------------------------------------------

/**
 * Find THE terminal hosting the claude process for this event.
 * Priority:
 *   (a) a terminal whose shell pid appears in event.ancestors (the shell is
 *       an ancestor of the claude process; if several match — e.g. nested
 *       shells — prefer the pid nearest to claude in the chain);
 *   (b) a UNIQUE terminal whose creationOptions.cwd equals event.cwd;
 *   (c) the only terminal, when exactly one exists.
 * Never guesses among multiple candidates: returns null instead.
 */
async function findClaudeTerminal(ev) {
  const terminals = vscode.window.terminals.slice();
  if (terminals.length === 0) return null;

  // (a) shell pid contained in event.ancestors
  const ancestors = Array.isArray(ev.ancestors)
    ? ev.ancestors.map(Number).filter((n) => Number.isInteger(n) && n > 0)
    : [];
  if (ancestors.length > 0) {
    const pids = await Promise.all(
      terminals.map((t) =>
        Promise.resolve(t.processId).then(
          (pid) => pid,
          () => undefined
        )
      )
    );
    let best = null;
    let bestIndex = Infinity;
    for (let i = 0; i < terminals.length; i++) {
      const pid = pids[i];
      if (typeof pid !== 'number') continue;
      const idx = ancestors.indexOf(pid);
      if (idx !== -1 && idx < bestIndex) {
        best = terminals[i];
        bestIndex = idx; // nearest ancestor of claude wins (innermost shell)
      }
    }
    if (best) return best;
  }

  // (b) creationOptions.cwd matches event.cwd (must be unambiguous)
  const evCwd =
    typeof ev.cwd === 'string' && ev.cwd ? normalizeDir(ev.cwd) : '';
  if (evCwd) {
    const matches = terminals.filter((t) => {
      const opts = t.creationOptions || {};
      let cwd = opts.cwd;
      if (cwd && typeof cwd === 'object' && typeof cwd.fsPath === 'string') {
        cwd = cwd.fsPath; // vscode.Uri
      }
      return typeof cwd === 'string' && normalizeDir(cwd) === evCwd;
    });
    if (matches.length === 1) return matches[0];
    if (matches.length > 1) return null; // ambiguous: never guess
  }

  // (c) exactly one terminal exists
  if (terminals.length === 1) return terminals[0];

  return null;
}

function normalizeDir(p) {
  let out = path.normalize(String(p));
  while (out.length > 1 && (out.endsWith('/') || out.endsWith('\\'))) {
    out = out.slice(0, -1);
  }
  return out;
}

/** Send the answer to the claude terminal in the background. */
async function respond(ev, text) {
  let terminal = null;
  try {
    terminal = await findClaudeTerminal(ev);
  } catch (err) {
    console.error('The Button: terminal lookup failed:', err);
  }
  if (!terminal) {
    vscode.window.showErrorMessage(
      "The Button: couldn't identify the Claude terminal."
    );
    return;
  }
  // No newline appended: "\r" itself is the Enter, "\u001b" is the Esc.
  terminal.sendText(text, false);
  // The hooks / macOS app own the event file — we only remember the ts.
  markHandled(eventTs(ev));
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

async function commandAnswer(text) {
  const ev = pendingEvent;
  if (!ev) {
    vscode.window.showInformationMessage(
      'The Button: no Claude prompt is pending.'
    );
    return;
  }
  const current = readEventFile(watchedPath || resolveEventFile());
  if (
    !current ||
    current.type !== 'permission' ||
    eventTs(current) !== eventTs(ev) ||
    eventTs(current) === lastHandledTs
  ) {
    vscode.window.showInformationMessage(
      'The Button: that Claude prompt is no longer pending.'
    );
    return;
  }
  await respond(current, text);
}

function commandDismiss() {
  if (!pendingEvent) {
    vscode.window.showInformationMessage(
      'The Button: no Claude prompt is pending.'
    );
    return;
  }
  markHandled(eventTs(pendingEvent));
}

// ---------------------------------------------------------------------------
// theButton.installHooks — cross-platform port of install.sh
// ---------------------------------------------------------------------------

/**
 * Exact JS mirror of install.sh's ensure():
 *   - command string: python3 "$HOME/.claude/the_button/hook.py" <kind>
 *   - if any existing hook command mentions "the_button/hook.py", rewrite it
 *     in place and stop; otherwise append a new entry.
 */
function ensureHook(hooks, event, kind) {
  const cmd = 'python3 "$HOME/.claude/the_button/hook.py" ' + kind;
  if (!Array.isArray(hooks[event])) hooks[event] = [];
  const entries = hooks[event];
  for (const entry of entries) {
    const inner =
      entry && typeof entry === 'object' && Array.isArray(entry.hooks)
        ? entry.hooks
        : [];
    for (const h of inner) {
      if (
        h &&
        typeof h === 'object' &&
        typeof h.command === 'string' &&
        h.command.includes('the_button/hook.py')
      ) {
        h.command = cmd;
        return;
      }
    }
  }
  entries.push({ hooks: [{ type: 'command', command: cmd }] });
}

/**
 * Locate the hook source: the copy bundled inside the extension package first
 * (shipped as hook-py.txt — the Marketplace rejects packaged scripts; it is
 * written out as hook.py on install), then walk up from __dirname (dev
 * checkout of the repo, where hook.py sits at the root).
 */
function findRepoHookPy() {
  const bundled = path.join(__dirname, 'hook-py.txt');
  try {
    if (fs.statSync(bundled).isFile()) return bundled;
  } catch (_e) {
    /* not bundled; fall through to the repo walk */
  }
  let dir = __dirname;
  for (let i = 0; i < 10; i++) {
    const candidate = path.join(dir, 'hook.py');
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch (_e) {
      /* keep walking */
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

async function installHooks() {
  if (process.platform === 'win32') {
    vscode.window.showWarningMessage(
      'The Button: hook installation is macOS/Linux only for now (hook.py uses `ps`).'
    );
    return;
  }

  const stateDir = path.join(os.homedir(), '.claude', 'the_button');
  const hookDest = path.join(stateDir, 'hook.py');
  fs.mkdirSync(stateDir, { recursive: true });

  let hookNote;
  const hookSource = findRepoHookPy();
  if (hookSource && normalizeDir(hookSource) !== normalizeDir(hookDest)) {
    fs.copyFileSync(hookSource, hookDest);
    hookNote = 'hook.py copied from ' + hookSource;
  } else if (fs.existsSync(hookDest)) {
    hookNote = 'using existing ' + hookDest;
  } else {
    vscode.window.showErrorMessage(
      'The Button: hook.py not found. Clone the_button repo (so hook.py sits above this extension) or copy hook.py to ' +
        hookDest +
        ', then rerun.'
    );
    return;
  }

  const settingsPath = path.join(os.homedir(), '.claude', 'settings.json');
  let settings = {};
  if (fs.existsSync(settingsPath)) {
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    } catch (err) {
      vscode.window.showErrorMessage(
        'The Button: ' +
          settingsPath +
          ' is not valid JSON — not touching it (' +
          (err && err.message) +
          ').'
      );
      return;
    }
    if (!settings || typeof settings !== 'object' || Array.isArray(settings)) {
      vscode.window.showErrorMessage(
        'The Button: ' + settingsPath + ' is not a JSON object — not touching it.'
      );
      return;
    }
  }

  if (
    settings.hooks === undefined ||
    settings.hooks === null ||
    typeof settings.hooks !== 'object' ||
    Array.isArray(settings.hooks)
  ) {
    if (settings.hooks !== undefined) {
      vscode.window.showErrorMessage(
        'The Button: "hooks" in ' + settingsPath + ' has an unexpected shape — not touching it.'
      );
      return;
    }
    settings.hooks = {};
  }
  const hooks = settings.hooks;

  // Same events + kinds as install.sh.
  ensureHook(hooks, 'PermissionRequest', 'permreq');
  ensureHook(hooks, 'PreToolUse', 'pretool');
  ensureHook(hooks, 'Notification', 'notify');
  for (const event of [
    'PostToolUse',
    'PostToolUseFailure',
    'Stop',
    'UserPromptSubmit',
    'SessionEnd',
  ]) {
    ensureHook(hooks, event, 'clear');
  }

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
  vscode.window.showInformationMessage(
    'The Button: hooks installed in ' +
      settingsPath +
      ' (' +
      hookNote +
      '). Restart running claude sessions so they pick up the hooks.'
  );
}

// ---------------------------------------------------------------------------
// File watching + activation
// ---------------------------------------------------------------------------

function onFileChange() {
  try {
    handleEvent(readEventFile(watchedPath || resolveEventFile()));
  } catch (err) {
    console.error('The Button: event handling failed:', err);
  }
}

function setupWatch() {
  const target = resolveEventFile();
  if (watchedPath === target) return;
  if (watchedPath) {
    try {
      fs.unwatchFile(watchedPath, onFileChange);
    } catch (_e) {
      /* ignore */
    }
  }
  watchedPath = target;
  try {
    // fs.watchFile is stat-polling: it works even while the file does not
    // exist yet and survives the atomic tempfile+rename writes hook.py does.
    fs.watchFile(target, { interval: POLL_INTERVAL_MS }, onFileChange);
  } catch (err) {
    console.error('The Button: could not watch ' + target + ':', err);
  }
  onFileChange(); // initial read
}

function activate(context) {
  statusItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    10000
  );
  context.subscriptions.push(statusItem);

  context.subscriptions.push(
    vscode.commands.registerCommand('theButton.allow', () =>
      commandAnswer(ENTER).catch((err) =>
        console.error('The Button: allow failed:', err)
      )
    ),
    vscode.commands.registerCommand('theButton.deny', () =>
      commandAnswer(ESCAPE).catch((err) =>
        console.error('The Button: deny failed:', err)
      )
    ),
    vscode.commands.registerCommand('theButton.dismiss', () =>
      commandDismiss()
    ),
    vscode.commands.registerCommand('theButton.installHooks', () =>
      installHooks().catch((err) => {
        console.error('The Button: installHooks failed:', err);
        vscode.window.showErrorMessage(
          'The Button: hook installation failed: ' + (err && err.message)
        );
      })
    ),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('theButton.eventFile')) setupWatch();
    })
  );

  setupWatch();
}

function deactivate() {
  if (watchedPath) {
    try {
      fs.unwatchFile(watchedPath, onFileChange);
    } catch (_e) {
      /* ignore */
    }
    watchedPath = null;
  }
}

module.exports = { activate, deactivate };
