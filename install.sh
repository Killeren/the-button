#!/bin/bash
# Build the app, install the hook script, and wire the hooks into
# ~/.claude/settings.json (user-level, so it works in every project).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

mkdir -p "$HOME/.claude/the_button"
cp hook.py "$HOME/.claude/the_button/hook.py"

python3 - <<'PY'
import json, os

path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})

def ensure(event, kind, timeout=None):
    cmd = f'python3 "$HOME/.claude/the_button/hook.py" {kind}'
    entries = hooks.setdefault(event, [])
    for entry in entries:
        for h in entry.get("hooks", []):
            if "the_button/hook.py" in h.get("command", ""):
                h["command"] = cmd
                if timeout:
                    h["timeout"] = timeout
                else:
                    h.pop("timeout", None)
                return
    hook = {"type": "command", "command": cmd}
    if timeout:
        hook["timeout"] = timeout
    entries.append({"hooks": [hook]})

# permreq may block while the panel decides; the timeout must never kill it
# mid-wait (hook.py's own decide window is 590s, safely inside).
ensure("PermissionRequest", "permreq", 600)
ensure("PreToolUse", "pretool")
ensure("Notification", "notify")
for event in ("PostToolUse", "PostToolUseFailure", "Stop", "UserPromptSubmit", "SessionEnd"):
    ensure(event, "clear")

# Atomic write: a truncated settings.json would break every Claude Code hook.
import tempfile
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, path)
print(f"Hooks installed in {path}")
PY

echo
echo "Done. Start the button with:  open \"$(pwd)/TheButton.app\""
echo "Restart any running claude sessions so they pick up the new hooks."
