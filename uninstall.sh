#!/bin/bash
# Remove The Button's hooks from ~/.claude/settings.json and its state dir.
set -euo pipefail

pkill -f "TheButton.app/Contents/MacOS/TheButton" 2>/dev/null || true

python3 - <<'PY'
import json, os

path = os.path.expanduser("~/.claude/settings.json")
if not os.path.exists(path):
    raise SystemExit("no settings.json; nothing to do")
with open(path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for event in list(hooks):
    entries = []
    for entry in hooks[event]:
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "the_button/hook.py" not in h.get("command", "")]
        if entry["hooks"]:
            entries.append(entry)
    if entries:
        hooks[event] = entries
    else:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print("Hooks removed from", path)
PY

rm -rf "$HOME/.claude/the_button"
echo "Removed ~/.claude/the_button. You can now delete this folder (TheButton.app included)."
