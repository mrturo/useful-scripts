#!/usr/bin/env bash
# AI Code Puppy Safe Launcher
# Runs 'caffeinate -d -m -- $HOME/.code-puppy-venv/bin/code-puppy -i' from the current directory.
# If running from home directory, redirects to ~/Documents first.
# Usage: ./ai-code-puppy.sh

set -euo pipefail

# If in home directory, redirect to ~/Documents
if [[ "$PWD" == "$HOME" ]]; then
  cd "$HOME/Documents"
fi

exec caffeinate -d -m -- $HOME/.code-puppy-venv/bin/code-puppy -i
