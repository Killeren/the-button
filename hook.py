#!/usr/bin/env python3
"""Claude Code hook -> event file for The Button (floating approval panel).

Usage (wired into ~/.claude/settings.json by install.sh):
    hook.py permreq  # on PermissionRequest: a permission dialog just appeared
    hook.py pretool  # on PreToolUse: remember what tool is about to run
    hook.py notify   # on Notification: permission / waiting-for-input
    hook.py clear    # on PostToolUse(Failure) / Stop / UserPromptSubmit / SessionEnd

Writes ~/.claude/the_button/event.json atomically. The Swift app polls it.
IMPORTANT: the PermissionRequest hook must print nothing and exit 0, so it
never influences the permission decision itself.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

STATE_DIR = os.path.expanduser("~/.claude/the_button")
EVENT_PATH = os.path.join(STATE_DIR, "event.json")
LOCK_PATH = os.path.join(STATE_DIR, ".lock")


@contextmanager
def state_lock():
    """Serialize read-check-write on the event file across hook processes."""
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


def pending_path(session):
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session or "unknown")
    return os.path.join(STATE_DIR, f"pending-{safe}.json")


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
    os.makedirs(STATE_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE_DIR, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else "notify"
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
        return

    if kind == "clear":
        if payload.get("hook_event_name") == "SessionEnd":
            try:
                os.remove(pending_path(session))
            except OSError:
                pass
        if not session:
            return  # malformed payload must never clear someone's prompt
        with state_lock():
            try:
                with open(EVENT_PATH) as f:
                    current = json.load(f)
            except Exception:
                return
            if current.get("type") == "clear":
                return
            if current.get("session_id") and current["session_id"] != session:
                return  # another session's prompt is pending; leave it alone
            write_json(EVENT_PATH, {"type": "clear", "message": "", "session_id": session,
                                    "claude_pid": 0, "ancestors": [], "ts": time.time()})
        return

    # kind == "permreq" (a permission dialog appeared) or "notify"
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
    tool_name = payload.get("tool_name", "")
    detail = summarize(payload.get("tool_input")) if payload.get("tool_input") else ""
    if etype == "permission" and not detail:
        try:
            with open(pending_path(session)) as f:
                pending = json.load(f)
            if time.time() - pending.get("ts", 0) < 15:
                if not tool_name:
                    tool_name = pending.get("tool_name", "")
                if tool_name == pending.get("tool_name", ""):
                    detail = pending.get("detail", "")
        except Exception:
            pass
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

    with state_lock():
        if kind == "notify" and etype == "permission":
            # PermissionRequest owns permission events on current Claude Code;
            # permission_prompt notifications for the same session (they also
            # re-fire on an idle timer while a dialog waits) must not clobber
            # or resurrect it. Only write when no permission event exists for
            # this session — that's the pre-PermissionRequest fallback path.
            try:
                with open(EVENT_PATH) as f:
                    existing = json.load(f)
                if (existing.get("type") == "permission"
                        and existing.get("session_id") == session):
                    return
            except Exception:
                pass
        write_json(EVENT_PATH, event)


if __name__ == "__main__":
    main()
