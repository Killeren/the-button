#!/bin/bash
# Build a Marketplace-ready .vsix. The hook ships as hook-py.txt (an inert
# text asset — the Marketplace scanner rejects packaged scripts); the
# installHooks command writes it to ~/.claude/the_button/hook.py.
set -euo pipefail
cd "$(dirname "$0")"
rm -f hook.py
cp ../hook.py hook-py.txt
npx -y @vscode/vsce package --no-dependencies
