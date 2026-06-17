#!/usr/bin/env bash
# AI Wibey Safe Launcher
# Runs 'caffeinate -d -m -- wibey' from the current directory.
# If running from home directory, redirects to ~/Documents first.
# Usage: ./ai-wibey.sh

set -euo pipefail

# If in home directory, redirect to ~/Documents
if [[ "$PWD" == "$HOME" ]]; then
  cd "$HOME/Documents"
fi

exec caffeinate -d -m -- wibey
