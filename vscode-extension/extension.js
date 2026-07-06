'use strict';

// The Button — Claude Code Approvals (VS Code companion), v0.2.
//
// Watches the per-prompt event files written by hook.py
// (~/.claude/the_button/events/*.json) and answers Claude Code permission
// prompts IN THE BACKGROUND:
//
//   decide mode    the hook is blocked waiting on an answer file; we write
//                  {"behavior":"allow"|"deny"} and the hook returns the
//                  decision to Claude Code. No keystrokes, no terminal
//                  targeting, works over ssh — any terminal, any platform.
//   keystroke mode the dialog is already on screen (old hook.py, or the
//                  decide window expired): terminal.sendText Enter/Esc into
//                  the right integrated terminal, as v0.1 did.
//
// A 1s heartbeat file advertises this listener to hook.py; without any fresh
// heartbeat the hook never blocks. Legacy single-file mode (event.json) is
// kept for old hook.py installs.

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');

const POLL_INTERVAL_MS = 300;
const HEARTBEAT_MS = 1000;
const DETAIL_MAX = 80;
const ENTER = '\r';
const ESCAPE = '\u001b';
const LEGACY_KEY = '__legacy__';

let statusItem = null;
let pollTimer = null;
let heartbeatTimer = null;
let heartbeatPath = null;
const pendingTimers = new Set(); // decide→keystroke fallback timers, cleared on deactivate

/** filename -> { mtimeMs, ev, filePath } for events/ dir mode. */
const fileState = new Map();
/** filename -> ts of the event we last popped a notification for. */
const notifiedTs = new Map();
/** filename -> ts answered/dismissed locally; never act on it again. */
const handledTs = new Map();
let legacyMtimeMs = -1;
let legacyEvent = null; // parsed event.json (legacy mode only)

// ---------------------------------------------------------------------------
// Paths & config
// ---------------------------------------------------------------------------

function expandHome(p) {
  if (p === '~' || p.startsWith('~/') || p.startsWith('~\\')) {
    return path.join(os.homedir(), p.slice(1));
  }
  return p;
}

function configuredPath(key) {
  try {
    const value = vscode.workspace.getConfiguration('theButton').get(key, '');
    if (typeof value === 'string' && value.trim() !== '') return expandHome(value.trim());
  } catch (_e) {
    /* configuration unavailable */
  }
  return null;
}

function resolveEventsDir() {
  return configuredPath('eventsDir')
    || path.join(os.homedir(), '.claude', 'the_button', 'events');
}

function resolveLegacyEventFile() {
  return configuredPath('eventFile')
    || path.join(os.homedir(), '.claude', 'the_button', 'event.json');
}

/** hook.py's STATE_DIR: heartbeats and temp files live here. */
function resolveStateDir() {
  return path.dirname(resolveEventsDir());
}

// ---------------------------------------------------------------------------
// Event files
// ---------------------------------------------------------------------------

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

function isDecide(ev) {
  return ev && ev.mode === 'decide' && typeof ev.answer_path === 'string' && ev.answer_path;
}

/** Atomic write next to the target so the blocked hook never sees a partial file. */
function writeAnswer(answerPath, payload) {
  const stateDir = resolveStateDir();
  fs.mkdirSync(path.dirname(answerPath), { recursive: true });
  const tmp = path.join(stateDir, '.vsext-' + process.pid + '-' + Date.now() + '.tmp');
  fs.writeFileSync(tmp, JSON.stringify(payload));
  fs.renameSync(tmp, answerPath);
}

// ---------------------------------------------------------------------------
// Heartbeat (tells hook.py a decide-capable listener is alive)
// ---------------------------------------------------------------------------

function beat() {
  try {
    const stateDir = resolveStateDir();
    fs.mkdirSync(stateDir, { recursive: true });
    const target = path.join(stateDir, 'heartbeat-vscode.json');
    const tmp = path.join(stateDir, '.hb-vscode-' + process.pid + '.tmp');
    fs.writeFileSync(tmp, JSON.stringify({
      caps: ['decide'],
      ts: Date.now() / 1000, // hook.py compares against time.time() (seconds)
      pid: process.pid,
    }));
    fs.renameSync(tmp, target);
    heartbeatPath = target;
  } catch (_e) {
    /* state dir unwritable: decide mode simply stays off */
  }
}

function stopHeartbeat() {
  if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
  if (heartbeatPath) {
    try { fs.unlinkSync(heartbeatPath); } catch (_e) { /* already gone */ }
    heartbeatPath = null;
  }
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------

function scan() {
  const dir = resolveEventsDir();
  let names = null;
  try {
    names = fs.readdirSync(dir).filter((n) => n.endsWith('.json'));
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      names = null; // dir truly absent: old hook.py — legacy single-file mode
    } else {
      return; // transient readdir error (EMFILE/EACCES): keep state, skip tick
    }
  }

  if (names === null) {
    fileState.clear();
    scanLegacy();
  } else {
    legacyEvent = null;
    legacyMtimeMs = -1;
    const seen = new Set();
    for (const name of names) {
      const filePath = path.join(dir, name);
      let st;
      try { st = fs.statSync(filePath); } catch (_e) { continue; }
      seen.add(name);
      const prev = fileState.get(name);
      if (prev && prev.mtimeMs === st.mtimeMs) continue;
      fileState.set(name, { mtimeMs: st.mtimeMs, ev: readEventFile(filePath), filePath });
    }
    for (const name of [...fileState.keys()]) {
      if (!seen.has(name)) {
        fileState.delete(name);
        notifiedTs.delete(name);
        handledTs.delete(name);
      }
    }
  }
  updateUI();
}

function scanLegacy() {
  const filePath = resolveLegacyEventFile();
  let st;
  try {
    st = fs.statSync(filePath);
  } catch (_e) {
    legacyEvent = null;
    legacyMtimeMs = -1; // reset so a delete+recreate with the same mtime re-reads
    return;
  }
  if (st.mtimeMs === legacyMtimeMs) return;
  legacyMtimeMs = st.mtimeMs;
  const ev = readEventFile(filePath);
  if (!ev || ev.type === 'clear') { legacyEvent = null; return; }
  legacyEvent = ev;
}

/** Pending entries: [{ key, ev, filePath }] oldest-first, permissions only. */
function pendingPermissions() {
  const out = [];
  if (legacyEvent) {
    if (legacyEvent.type === 'permission'
        && !claudeIsDead(legacyEvent)
        && handledTs.get(LEGACY_KEY) !== eventTs(legacyEvent)) {
      out.push({ key: LEGACY_KEY, ev: legacyEvent, filePath: resolveLegacyEventFile() });
    }
    return out;
  }
  for (const [name, entry] of fileState) {
    const ev = entry.ev;
    if (!ev || ev.type !== 'permission') continue;
    if (claudeIsDead(ev)) continue;
    if (handledTs.get(name) === eventTs(ev)) continue;
    out.push({ key: name, ev, filePath: entry.filePath });
  }
  out.sort((a, b) => eventTs(a.ev) - eventTs(b.ev));
  return out;
}

function anyWaiting() {
  if (legacyEvent) return legacyEvent.type === 'notify' && !claudeIsDead(legacyEvent);
  for (const entry of fileState.values()) {
    if (entry.ev && entry.ev.type === 'notify' && !claudeIsDead(entry.ev)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Status bar + notifications
// ---------------------------------------------------------------------------

function updateUI() {
  const pending = pendingPermissions();

  if (pending.length === 0) {
    if (anyWaiting()) {
      statusItem.text = '$(watch) Claude is waiting';
      statusItem.tooltip = 'Claude Code is waiting for input';
      statusItem.backgroundColor = undefined;
      statusItem.show();
    } else {
      statusItem.hide();
    }
  } else {
    const first = pending[0];
    statusItem.text = pending.length === 1
      ? '$(bell) Claude: ' + String(first.ev.tool_name || 'permission')
      : '$(bell) Claude: ' + pending.length + ' pending';
    statusItem.tooltip = pending
      .map((p) => truncate(p.ev.detail || p.ev.message, 120) || 'permission prompt')
      .join('\n');
    statusItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    statusItem.show();
  }

  for (const entry of pending) {
    if (notifiedTs.get(entry.key) !== eventTs(entry.ev)) {
      notifiedTs.set(entry.key, eventTs(entry.ev));
      showPermissionNotification(entry);
    }
  }
}

function describe(ev) {
  const toolName = String(ev.tool_name || 'a tool');
  const detail = truncate(ev.detail || ev.message, DETAIL_MAX);
  const project = ev.cwd ? path.basename(String(ev.cwd)) : '';
  return { toolName, detail, project };
}

function showPermissionNotification(entry) {
  const ts = eventTs(entry.ev);
  const { toolName, detail, project } = describe(entry.ev);
  const message = 'Claude needs permission: ' + toolName
    + (detail ? ' — ' + detail : '')
    + (project ? '  (' + project + ')' : '');

  Promise.resolve(
    vscode.window.showWarningMessage(message, 'Allow', 'Deny', 'Dismiss')
  )
    .then((choice) => {
      if (!choice) return undefined; // notification closed/expired: leave event alone

      // The click may arrive long after the notification appeared. Re-read
      // the event file and only act if it is still the exact same event.
      const current = readEventFile(entry.filePath);
      if (
        !current ||
        current.type !== 'permission' ||
        eventTs(current) !== ts ||
        eventTs(current) === handledTs.get(entry.key)
      ) {
        vscode.window.showInformationMessage(
          'The Button: that Claude prompt is no longer pending.'
        );
        return undefined;
      }

      if (choice === 'Allow') return respond(entry.key, entry.filePath, current, true);
      if (choice === 'Deny') return respond(entry.key, entry.filePath, current, false);
      return dismiss(entry.key, entry.filePath, current); // hide locally
    })
    .then(undefined, (err) => {
      console.error('The Button: notification handling failed:', err);
    });
}

// ---------------------------------------------------------------------------
// Answering
// ---------------------------------------------------------------------------

async function respond(key, filePath, ev, allow) {
  handledTs.set(key, eventTs(ev));
  if (isDecide(ev)) {
    try {
      writeAnswer(ev.answer_path, allow
        ? { behavior: 'allow' }
        : { behavior: 'deny', message: 'Denied by the user via The Button (VS Code).' });
    } catch (err) {
      handledTs.delete(key);
      vscode.window.showErrorMessage(
        "The Button: couldn't write the answer file: " + (err && err.message)
      );
      return;
    }
    // The hook deletes its event file once the decision is delivered. If it
    // instead flipped to keystroke mode (timed out a beat before our answer),
    // deliver the intent by keystroke.
    const timer = setTimeout(() => {
      pendingTimers.delete(timer);
      const current = readEventFile(filePath);
      if (current && current.mode === 'keystroke' && eventTs(current) === eventTs(ev)) {
        respondKeystroke(current, allow).catch((err) =>
          console.error('The Button: keystroke fallback failed:', err));
      }
    }, 1200);
    pendingTimers.add(timer);
    updateUI();
    return;
  }
  // Keystroke mode: only stay "handled" if delivery actually happened, else
  // the prompt would be filtered out forever with the dialog still live.
  const delivered = await respondKeystroke(ev, allow);
  if (!delivered) handledTs.delete(key);
  updateUI();
}

/** ✕ / Dismiss: hide locally; a decide prompt is first handed back to the
 * native dialog so it stays answerable in the terminal. */
function dismiss(key, filePath, ev) {
  if (isDecide(ev)) {
    try { writeAnswer(ev.answer_path, { behavior: 'ask' }); } catch (_e) { /* best effort */ }
  }
  handledTs.set(key, eventTs(ev));
  updateUI();
}

// ---------------------------------------------------------------------------
// Keystroke fallback: terminal targeting (unchanged from v0.1)
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

  // (c) exactly one terminal — ONLY when there was no routing evidence at
  // all. If ancestors were present but matched nothing, claude is provably not
  // in a terminal we can identify (e.g. it's in iTerm, or behind tmux which
  // breaks the ppid chain); guessing could fire a staged command into the
  // wrong terminal, so refuse and let the caller tell the user.
  if (terminals.length === 1 && ancestors.length === 0) return terminals[0];

  return null;
}

function normalizeDir(p) {
  let out = path.normalize(String(p));
  while (out.length > 1 && (out.endsWith('/') || out.endsWith('\\'))) {
    out = out.slice(0, -1);
  }
  return out;
}

/** Returns true only if the answer was actually sent to a terminal. */
async function respondKeystroke(ev, allow) {
  let terminal = null;
  try {
    terminal = await findClaudeTerminal(ev);
  } catch (err) {
    console.error('The Button: terminal lookup failed:', err);
  }
  if (!terminal) {
    vscode.window.showErrorMessage(
      "The Button: couldn't identify the Claude terminal \u2014 answer it in the terminal."
    );
    return false;
  }
  try {
    // No newline appended: "\r" itself is the Enter, the ESC control char is the Esc.
    terminal.sendText(allow ? ENTER : ESCAPE, false);
    return true;
  } catch (err) {
    console.error('The Button: sendText failed:', err);
    vscode.window.showErrorMessage(
      "The Button: couldn't send to the Claude terminal \u2014 answer it there."
    );
    return false;
  }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

async function pickPending(placeHolder) {
  const pending = pendingPermissions();
  if (pending.length === 0) {
    vscode.window.showInformationMessage('The Button: no Claude prompt is pending.');
    return null;
  }
  if (pending.length === 1) return pending[0];
  const items = pending.map((entry) => {
    const { toolName, detail, project } = describe(entry.ev);
    const age = Math.max(0, Math.round(Date.now() / 1000 - eventTs(entry.ev)));
    return {
      label: '$(shield) ' + toolName + (detail ? ' — ' + detail : ''),
      description: (project ? project + ' · ' : '') + age + 's',
      entry,
    };
  });
  const picked = await vscode.window.showQuickPick(items, { placeHolder });
  return picked ? picked.entry : null;
}

async function commandAnswer(allow) {
  const entry = await pickPending(allow ? 'Allow which prompt?' : 'Deny which prompt?');
  if (!entry) return;
  const current = readEventFile(entry.filePath);
  if (
    !current ||
    current.type !== 'permission' ||
    eventTs(current) !== eventTs(entry.ev) ||
    eventTs(current) === handledTs.get(entry.key)
  ) {
    vscode.window.showInformationMessage(
      'The Button: that Claude prompt is no longer pending.'
    );
    return;
  }
  await respond(entry.key, entry.filePath, current, allow);
}

async function commandDismiss() {
  const entry = await pickPending('Dismiss which prompt?');
  if (!entry) return;
  const current = readEventFile(entry.filePath) || entry.ev;
  dismiss(entry.key, entry.filePath, current);
}

// ---------------------------------------------------------------------------
// theButton.installHooks — cross-platform port of install.sh
// ---------------------------------------------------------------------------

/**
 * Mirror of install.sh's ensure():
 *   - command string: python3 "$HOME/.claude/the_button/hook.py" <kind>
 *   - if any existing hook command mentions "the_button/hook.py", rewrite it
 *     in place and stop; otherwise append a new entry.
 *   - permreq gets an explicit 600s timeout: the hook may block while the
 *     panel decides, and the default must never kill it mid-wait.
 */
function ensureHook(hooks, event, kind, timeoutSeconds) {
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
        if (timeoutSeconds) h.timeout = timeoutSeconds;
        else delete h.timeout;
        return;
      }
    }
  }
  const hook = { type: 'command', command: cmd };
  if (timeoutSeconds) hook.timeout = timeoutSeconds;
  entries.push({ hooks: [hook] });
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
      'The Button: hook installation is macOS/Linux only for now (hook.py uses `ps` and POSIX file locks).'
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
  ensureHook(hooks, 'PermissionRequest', 'permreq', 600);
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

  // Atomic write: settings.json is the single most valuable Claude Code file;
  // a truncated write (ENOSPC/crash) would break every hook and permission.
  const settingsTmp = settingsPath + '.tb-' + process.pid + '.tmp';
  fs.writeFileSync(settingsTmp, JSON.stringify(settings, null, 2));
  fs.renameSync(settingsTmp, settingsPath);
  vscode.window.showInformationMessage(
    'The Button: hooks installed in ' +
      settingsPath +
      ' (' +
      hookNote +
      '). Restart running claude sessions so they pick up the hooks.'
  );
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

function activate(context) {
  statusItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    10000
  );
  context.subscriptions.push(statusItem);

  context.subscriptions.push(
    vscode.commands.registerCommand('theButton.allow', () =>
      commandAnswer(true).catch((err) =>
        console.error('The Button: allow failed:', err)
      )
    ),
    vscode.commands.registerCommand('theButton.deny', () =>
      commandAnswer(false).catch((err) =>
        console.error('The Button: deny failed:', err)
      )
    ),
    vscode.commands.registerCommand('theButton.dismiss', () =>
      commandDismiss().catch((err) =>
        console.error('The Button: dismiss failed:', err)
      )
    ),
    vscode.commands.registerCommand('theButton.installHooks', () =>
      installHooks().catch((err) => {
        console.error('The Button: installHooks failed:', err);
        vscode.window.showErrorMessage(
          'The Button: hook installation failed: ' + (err && err.message)
        );
      })
    )
  );

  pollTimer = setInterval(() => {
    try { scan(); } catch (err) { console.error('The Button: scan failed:', err); }
  }, POLL_INTERVAL_MS);
  heartbeatTimer = setInterval(beat, HEARTBEAT_MS);
  beat();
  scan();
}

function deactivate() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  for (const t of pendingTimers) clearTimeout(t);
  pendingTimers.clear();
  stopHeartbeat();
}

module.exports = { activate, deactivate };
