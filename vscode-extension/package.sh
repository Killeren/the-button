#!/bin/bash
# Build a Marketplace-ready .vsix. Syncs the bundled hook.py from the repo
# root first so store installs are self-contained.
set -euo pipefail
cd "$(dirname "$0")"
cp ../hook.py hook.py
npx -y @vscode/vsce package --no-dependencies
