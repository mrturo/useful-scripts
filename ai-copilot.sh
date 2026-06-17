#!/usr/bin/env bash
# AI Copilot Safe Launcher
# Runs 'caffeinate -d -m -- zsh -c "source $HOME/Documents/scripts/unset_proxies.sh; copilot -i ''suggest'' --disable-builtin-mcps"' from the current directory.
# If running from home directory, redirects to ~/Documents first.
# Usage: ./ai-copilot.sh

set -euo pipefail

# If in home directory, redirect to ~/Documents
if [[ "$PWD" == "$HOME" ]]; then
  cd "$HOME/Documents"
fi

exec caffeinate -d -m -- zsh -c "source $HOME/Documents/scripts/unset_proxies.sh; copilot -i ''suggest'' --disable-builtin-mcps"
