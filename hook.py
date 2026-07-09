#!/usr/bin/env python3
"""Claude Code hook -> event files for The Button (floating approval panel).

Usage (wired into ~/.claude/settings.json by install.sh):
    hook.py permreq  # on PermissionRequest: decide via the panel, or fall back
    hook.py pretool  # on PreToolUse: remember what tool is about to run
    hook.py notify   # on Notification: permission / waiting-for-input
    hook.py clear    # on PostToolUse(Failure) / Stop / UserPromptSubmit / SessionEnd

State layout under ~/.claude/the_button/:
    events/<sid>--p<pid>.json     one file PER pending permission prompt
    events/<sid>--notify.json     waiting-for-input card for a session
    answers/<same-basename>.json  the panel's answer to a decide-mode prompt
    heartbeat*.json               decide-capable listeners (app / VS Code ext)
    event.json                    legacy mirror for old readers (deprecated)
    pending-<sid>.json            last PreToolUse (legacy Notification path)
    .lock                         flock serializing read-check-write
    disable                       kill switch: hooks do nothing while present

Decide mode: when a fresh heartbeat advertises {"caps": ["decide"]}, the
permreq hook BLOCKS (Claude Code renders "Waiting for permission..." and the
native dialog is deferred), polling its answer file. An allow/deny answer is
printed as a PermissionRequest hook decision, so the dialog never appears and
no keystrokes are ever needed. An "ask" answer (user focused the session's
terminal, or dismissed the card), a stale heartbeat, or the deadline rewrites
the event as mode:"keystroke" and exits silently -- the native dialog then
appears and the panel falls back to the old keystroke delivery.

IMPORTANT: outside a decide answer, hooks must print nothing and exit 0 so
they never influence the permission decision themselves.
"""
import fcntl
import glob
import json
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

# Bump on every hook.py change. Installers (VS Code extension, install.sh)
# compare this against an installed copy and only overwrite older ones.
HOOK_VERSION = 3

STATE_DIR = os.path.expanduser("~/.claude/the_button")
EVENTS_DIR = os.path.join(STATE_DIR, "events")
ANSWERS_DIR = os.path.join(STATE_DIR, "answers")
EVENT_PATH = os.path.join(STATE_DIR, "event.json")  # legacy mirror
LOCK_PATH = os.path.join(STATE_DIR, ".lock")
DISABLE_PATH = os.path.join(STATE_DIR, "disable")

HEARTBEAT_FRESH = 3.0     # seconds; listener heartbeats are touched every ~1s
ANSWER_POLL = 0.05        # seconds between answer-file polls while deciding
RECHECK_EVERY = 1.0       # seconds between liveness re-checks while deciding

# Captured at import — the earliest possible read, before any subprocess call
# can let claude die and reparent us. A later change means claude went away.
START_PPID = os.getppid()


def decide_window():
    """How long permreq may block. install.sh sets the hook timeout to 600s;
    clamp to [5, 590] so we always exit cleanly instead of being killed (and
    never emit a non-finite deadline_ts that strict JSON parsers reject)."""
    try:
        value = float(os.environ.get("THE_BUTTON_DECIDE_WINDOW", "590"))
    except ValueError:
        return 590.0
    if not math.isfinite(value):
        return 590.0
    return min(max(5.0, value), 590.0)


@contextmanager
def state_lock():
    """Serialize read-check-write on the state files across hook processes."""
    os.makedirs(STATE_DIR, exist_ok=True)
    f = open(LOCK_PATH, "w")
    try:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        f.close()  # releases the lock

DETAIL_KEYS = ("command", "file_path", "url", "pattern", "query",
               "prompt", "description", "skill")
DETAIL_MAX = 260


def proc_table():
    """pid -> (ppid, command) for every running process."""
    try:
        out = subprocess.run(
            ["ps", "-ax", "-o", "pid=,ppid=,comm="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return {}
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2:
            try:
                table[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
            except ValueError:
                pass
    return table


def ancestry():
    """Our ancestor pids, nearest first: shell -> claude -> ... -> terminal app."""
    table = proc_table()
    chain, pid = [], os.getpid()
    for _ in range(25):
        entry = table.get(pid)
        if not entry:
            break
        ppid = entry[0]
        if ppid <= 1:
            break
        chain.append(ppid)
        pid = ppid
    return chain, table


def tty_of(pid):
    if not pid:
        return ""
    try:
        out = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return "/dev/" + out if out and out != "??" else ""
    except Exception:
        return ""


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def safe_name(session):
    return re.sub(r"[^A-Za-z0-9_-]", "_", session or "unknown")


def pending_path(session):
    return os.path.join(STATE_DIR, f"pending-{safe_name(session)}.json")


def perm_event_path(session, pid):
    return os.path.join(EVENTS_DIR, f"{safe_name(session)}--p{pid}.json")


def notify_event_path(session):
    return os.path.join(EVENTS_DIR, f"{safe_name(session)}--notify.json")


def session_perm_events(session):
    return glob.glob(os.path.join(EVENTS_DIR, f"{safe_name(session)}--p*.json"))


def answer_path_for(event_path):
    return os.path.join(ANSWERS_DIR, os.path.basename(event_path))


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def decide_listener_alive():
    """True when a fresh heartbeat advertises decide capability."""
    if os.environ.get("THE_BUTTON_NO_DECIDE"):
        return False
    now = time.time()
    for path in glob.glob(os.path.join(STATE_DIR, "heartbeat*.json")):
        hb = read_json(path)
        if (isinstance(hb, dict)
                and "decide" in (hb.get("caps") or [])
                and isinstance(hb.get("ts"), (int, float))
                and now - hb["ts"] < HEARTBEAT_FRESH):
            return True
    return False


def summarize(tool_input):
    ti = tool_input if isinstance(tool_input, dict) else {}
    for key in DETAIL_KEYS:
        value = ti.get(key)
        if isinstance(value, str) and value.strip():
            text = " ".join(value.split())
            return text[:DETAIL_MAX] + ("…" if len(text) > DETAIL_MAX else "")
    try:
        text = json.dumps(ti)
        return text[:DETAIL_MAX] + ("…" if len(text) > DETAIL_MAX else "")
    except Exception:
        return ""


def write_json(path, obj):
    """Atomic write. Temp files live in STATE_DIR (never events/), so the
    directory scanners can never observe a partial file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def remove_quiet(path):
    try:
        os.remove(path)
    except OSError:
        pass


# --- legacy event.json mirror (old app/extension versions; deprecated) ------
# Decide-mode events are intentionally NOT mirrored: an old reader would type
# keystrokes at a dialog that is not on screen.

def mirror_write(event):
    write_json(EVENT_PATH, event)


def mirror_notify_permission(event, session):
    """Old suppression semantics: a permission_prompt notification must not
    clobber or resurrect an existing same-session permission event."""
    existing = read_json(EVENT_PATH)
    if (isinstance(existing, dict)
            and existing.get("type") == "permission"
            and existing.get("session_id") == session):
        return
    mirror_write(event)


def mirror_clear(session):
    current = read_json(EVENT_PATH)
    if not isinstance(current, dict):
        return
    if current.get("type") == "clear":
        return
    if current.get("session_id") and current["session_id"] != session:
        return  # another session's prompt is pending; leave it alone
    write_json(EVENT_PATH, {"type": "clear", "message": "", "session_id": session,
                            "claude_pid": 0, "ancestors": [], "ts": time.time()})


# --- decide mode -------------------------------------------------------------

def escape_rule_content(text):
    """Match Claude Code's Tool(content) escaping (Xzu): backslash first,
    then parens."""
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


# Tools whose Always-allow must be scoped to specific content, never tool-wide
# (a blanket "allow all Bash" from one command click would be a footgun).
CONTENT_SCOPED_TOOLS = {"Bash"}


def build_rule(event):
    """(rule_string, updatedPermissions) for an Always-allow. Bash rules are
    scoped to the exact command; every other tool is allowed tool-wide. Refuse
    a content-scoped tool with no content rather than persist a blanket rule."""
    tool = event.get("rule_tool", "")
    if not tool:
        return None, None
    content = event.get("rule_content", "")
    if tool in CONTENT_SCOPED_TOOLS and not content:
        return None, None
    rule_obj = {"toolName": tool}
    if content:
        rule_obj["ruleContent"] = content
        rule_string = f"{tool}({escape_rule_content(content)})"
    else:
        rule_string = tool
    updated = [{
        "type": "addRules",
        "rules": [rule_obj],
        "behavior": "allow",
        "destination": "localSettings",
    }]
    return rule_string, updated


def persist_local_rule(cwd, rule_string):
    """Merge an allow rule into <cwd>/.claude/settings.local.json. Hook
    updatedPermissions only bind the live session; this is what survives a
    restart (parity with the dialog's own "don't ask again"). Serialized under
    state_lock so two concurrent always-allow clicks can't lose each other's
    rule (can't guard against Claude Code editing the file, but the loss self-
    heals via a re-prompt)."""
    if not cwd or not rule_string:
        return
    settings_dir = os.path.join(cwd, ".claude")
    path = os.path.join(settings_dir, "settings.local.json")
    try:
        with state_lock():
            os.makedirs(settings_dir, exist_ok=True)
            try:
                with open(path) as f:
                    settings = json.load(f)
                if not isinstance(settings, dict):
                    return  # unexpected shape: never clobber
            except FileNotFoundError:
                settings = {}
            except Exception:
                return  # invalid JSON: never clobber
            perms = settings.setdefault("permissions", {})
            if not isinstance(perms, dict):
                return
            allow = perms.setdefault("allow", [])
            if not isinstance(allow, list):
                return
            if rule_string not in allow:
                allow.append(rule_string)
            fd, tmp = tempfile.mkstemp(dir=settings_dir, suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump(settings, f, indent=2)
                os.replace(tmp, path)
            except Exception:
                remove_quiet(tmp)  # don't leak the temp file
                raise
    except Exception:
        pass  # persistence is best-effort; the session rule still applies


def emit_decision(answer, event):
    behavior = answer.get("behavior")
    if behavior == "allow":
        decision = {"behavior": "allow"}
        if answer.get("always"):
            rule_string, updated = build_rule(event)
            if updated:
                decision["updatedPermissions"] = updated   # binds this session
                persist_local_rule(event.get("cwd", ""), rule_string)  # + on disk
        elif isinstance(answer.get("updatedPermissions"), list) and answer["updatedPermissions"]:
            decision["updatedPermissions"] = answer["updatedPermissions"]
    else:
        decision = {"behavior": "deny"}
        message = answer.get("message")
        if isinstance(message, str) and message.strip():
            decision["message"] = message.strip()
        if answer.get("interrupt") is True:
            decision["interrupt"] = True
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": decision,
    }}))


def wait_for_answer(apath, window, claude_pid, epath):
    """Poll the answer file until an answer, a fallback condition, or death of
    our claude process. Returns a dict answer, "fallback", or "orphan". Uses a
    monotonic deadline so an NTP step can't extend the block past the hook
    timeout; always reads the answer one last time before giving up, so a click
    that lands in the same tick a liveness check trips is still honored."""
    mono_deadline = time.monotonic() + window
    last_check = 0.0
    while time.monotonic() < mono_deadline:
        answer = read_json(apath)
        if isinstance(answer, dict) and answer.get("behavior") in ("allow", "deny", "ask"):
            return answer
        now = time.monotonic()
        if now - last_check >= RECHECK_EVERY:
            last_check = now
            # Our event file is gone: PostToolUse cleared it because the tool it
            # gated already ran (approved without touching the panel — auto-accept
            # mode, an allow-rule, an agent). The prompt is moot; exit as orphan
            # so the tail doesn't resurrect it as a keystroke card.
            if not os.path.exists(epath):
                return "orphan"
            # claude gone (reparented from the import-time ancestor, or the
            # recorded claude pid is dead): nobody is waiting for us.
            if os.getppid() != START_PPID or (claude_pid and not pid_alive(claude_pid)):
                final = read_json(apath)  # honor an answer that just landed
                if isinstance(final, dict) and final.get("behavior") in ("allow", "deny", "ask"):
                    return final
                return "orphan"
            if not decide_listener_alive() or os.path.exists(DISABLE_PATH):
                final = read_json(apath)
                if isinstance(final, dict) and final.get("behavior") in ("allow", "deny", "ask"):
                    return final
                return "fallback"  # panel gone; show the native dialog
        time.sleep(ANSWER_POLL)
    return "fallback"


def do_permreq(event, session):
    epath = perm_event_path(session, os.getpid())
    apath = answer_path_for(epath)

    # No session means no clear hook can ever target this file (clear bails on
    # empty session), so never enter a blocking decide wait we couldn't cancel.
    # The keystroke event still drops app-side when claude's pid dies.
    if not session or not decide_listener_alive():
        event["mode"] = "keystroke"
        with state_lock():
            write_json(epath, event)
            mirror_write(event)
        return

    event["mode"] = "decide"
    event["hook_pid"] = os.getpid()
    event["answer_path"] = apath
    window = decide_window()
    event["deadline_ts"] = time.time() + window  # wall-clock, for the panel

    def cleanup(*_args):
        remove_quiet(epath)
        remove_quiet(apath)

    def die(signum, _frame):
        cleanup()
        os._exit(0)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, die)
        except (OSError, ValueError):
            pass

    os.makedirs(ANSWERS_DIR, exist_ok=True)  # listeners write answers here
    remove_quiet(apath)  # never consume a stale answer
    with state_lock():
        write_json(epath, event)

    answer = wait_for_answer(apath, window, event.get("claude_pid", 0), epath)

    if isinstance(answer, dict) and answer.get("behavior") in ("allow", "deny"):
        emit_decision(answer, event)
        cleanup()
        return
    if answer == "orphan":
        cleanup()
        return

    # claude may have died during the wait; don't leave a keystroke ghost for a
    # session that will never fire a clear hook again.
    claude_pid = event.get("claude_pid", 0)
    if os.getppid() != START_PPID or (claude_pid and not pid_alive(claude_pid)):
        cleanup()
        return

    # "ask" / timeout / listener vanished: hand the prompt to the native
    # dialog and let the panel fall back to keystroke delivery.
    remove_quiet(apath)
    event["mode"] = "keystroke"
    event["hook_pid"] = 0
    event.pop("answer_path", None)
    event.pop("deadline_ts", None)
    with state_lock():
        write_json(epath, event)
        mirror_write(event)


# --- main --------------------------------------------------------------------

def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "notify"
    if os.path.exists(DISABLE_PATH):
        return
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    session = payload.get("session_id", "")
    message = payload.get("message", "")

    if kind == "pretool":
        write_json(pending_path(session), {
            "tool_name": payload.get("tool_name", ""),
            "detail": summarize(payload.get("tool_input")),
            "ts": time.time(),
        })
        # A tool starting means any keystroke-mode permission dialog for this
        # session was just answered in the terminal. Clear those events right
        # away (instead of waiting for PostToolUse) so a released card the
        # panel re-shows can't go stale and type into the running turn. Live
        # decide hooks own their files, same guard as the clear path.
        if session:
            removed = False
            with state_lock():
                for path in session_perm_events(session):
                    ev = read_json(path)
                    if (isinstance(ev, dict) and ev.get("mode") == "decide"
                            and pid_alive(ev.get("hook_pid", 0))):
                        continue
                    remove_quiet(path)
                    remove_quiet(answer_path_for(path))
                    removed = True
                if removed:
                    mirror_clear(session)
        return

    if kind == "clear":
        if payload.get("hook_event_name") == "SessionEnd":
            remove_quiet(pending_path(session))
        if not session:
            return  # malformed payload must never clear someone's prompt
        # Identity of the tool this PostToolUse belongs to, so we can retire its
        # own decide card even while the hook still blocks (see below).
        done_tool = payload.get("tool_name", "")
        done_detail = summarize(payload.get("tool_input")) if payload.get("tool_input") else ""
        with state_lock():
            remove_quiet(notify_event_path(session))
            for path in session_perm_events(session):
                ev = read_json(path)
                if not isinstance(ev, dict):
                    remove_quiet(path)  # malformed: clean it up
                    continue
                # A live decide hook owns its file: PostToolUse for a *parallel*
                # tool must not dismiss a prompt still being decided — UNLESS the
                # blocked prompt is for this very tool, which just ran (approved
                # off-panel, so the hook never got an answer and would otherwise
                # block for its full window). Clearing the file makes that hook
                # exit as orphan on its next re-check instead of lingering.
                live_decide = ev.get("mode") == "decide" and pid_alive(ev.get("hook_pid", 0))
                is_this_tool = (done_tool and ev.get("tool_name") == done_tool
                                and ev.get("detail", "") == done_detail)
                if not live_decide or is_this_tool:
                    remove_quiet(path)
                    remove_quiet(answer_path_for(path))  # no orphan answer left
            mirror_clear(session)
        return

    # kind == "permreq" (a permission dialog is due) or "notify"
    ntype = payload.get("notification_type", "")
    if kind == "permreq":
        etype = "permission"
    elif ntype:
        if ntype == "permission_prompt":
            etype = "permission"
        elif ntype in ("idle_prompt", "agent_needs_input", "elicitation_dialog"):
            etype = "notify"
        else:
            return  # auth_success, elicitation_complete, ... nothing to answer
    else:  # older Claude Code without notification_type: fall back to message
        etype = "permission" if "permission" in message.lower() else "notify"

    # What is being approved? Prefer the dialog's own tool info
    # (PermissionRequest payloads carry tool_name/tool_input), then the last
    # PreToolUse recorded for this session. Keep the pending-file window tight:
    # a dialog appears right after its own PreToolUse, and a wide window would
    # let a parallel tool call mislabel the approval.
    tool_input = payload.get("tool_input")
    tool_name = payload.get("tool_name", "")
    detail = summarize(tool_input) if tool_input else ""
    if etype == "permission" and not detail:
        pending = read_json(pending_path(session))
        if isinstance(pending, dict) and time.time() - pending.get("ts", 0) < 15:
            if not tool_name:
                tool_name = pending.get("tool_name", "")
            if tool_name == pending.get("tool_name", ""):
                detail = pending.get("detail", "")
    m = re.search(r"permission to use (.+)$", message)
    if m and not tool_name:
        tool_name = m.group(1).strip()

    chain, table = ancestry()
    claude_pid = 0
    for pid in chain:
        base = os.path.basename(table.get(pid, (0, ""))[1]).lower()
        if "claude" in base or base == "node":
            claude_pid = pid
            break

    event = {
        "type": etype, "message": message, "session_id": session,
        "claude_pid": claude_pid, "ancestors": chain,
        "tty": tty_of(claude_pid), "cwd": payload.get("cwd", ""),
        "tool_name": tool_name, "detail": detail,
        "ts": time.time(),
    }

    # For "Always allow": the exact rule the panel may persist. Bash gets the
    # exact command; other tools get a tool-wide rule (ruleContent omitted).
    if etype == "permission" and tool_name:
        event["rule_tool"] = tool_name
        command = (tool_input or {}).get("command") if isinstance(tool_input, dict) else None
        if tool_name == "Bash" and isinstance(command, str) and command.strip():
            event["rule_content"] = command.strip()

    if kind == "permreq":
        do_permreq(event, session)
        return

    # kind == "notify"
    if etype == "permission":
        # PermissionRequest owns permission events on current Claude Code;
        # permission_prompt notifications for the same session (they also
        # re-fire on an idle timer while a dialog waits) must not clobber or
        # duplicate one. Only write when no permission event exists for this
        # session — that's the pre-PermissionRequest fallback path.
        event["mode"] = "keystroke"
        with state_lock():
            for path in session_perm_events(session):
                ev = read_json(path)
                if isinstance(ev, dict) and ev.get("type") == "permission":
                    return
            write_json(perm_event_path(session, os.getpid()), event)
            mirror_notify_permission(event, session)
    else:
        with state_lock():
            write_json(notify_event_path(session), event)
            mirror_write(event)  # verbatim old semantics for waiting events


if __name__ == "__main__":
    main()
