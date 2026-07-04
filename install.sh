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

def ensure(event, kind):
    cmd = f'python3 "$HOME/.claude/the_button/hook.py" {kind}'
    entries = hooks.setdefault(event, [])
    for entry in entries:
        for h in entry.get("hooks", []):
            if "the_button/hook.py" in h.get("command", ""):
                h["command"] = cmd
                return
    entries.append({"hooks": [{"type": "command", "command": cmd}]})

ensure("PermissionRequest", "permreq")
ensure("PreToolUse", "pretool")
ensure("Notification", "notify")
for event in ("PostToolUse", "PostToolUseFailure", "Stop", "UserPromptSubmit", "SessionEnd"):
    ensure(event, "clear")

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print(f"Hooks installed in {path}")
PY

echo
echo "Done. Start the button with:  open \"$(pwd)/TheButton.app\""
echo "Restart any running claude sessions so they pick up the new hooks."
