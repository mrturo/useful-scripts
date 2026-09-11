#!/usr/bin/env bash
# AI Code Puppy Safe Launcher & Updater
# Default (no args): first triggers the non-forced update (update-code-puppy),
#   which is skipped/aborted silently if it hasn't been 7 days yet or if it
#   fails for any other reason, then ALWAYS launches Code Puppy afterwards
#   via 'caffeinate -d -m -- $HOME/.code-puppy-venv/bin/code-puppy -i'.
#   If running from home directory, redirects to ~/Documents first.
# Commands:
#   ./ai-code-puppy.sh                    -> update (best-effort) + start Code Puppy (default)
#   ./ai-code-puppy.sh start              -> update (best-effort) + start Code Puppy (explicit)
#   ./ai-code-puppy.sh update-code-puppy       -> update only, stops if <7 days since last update
#   ./ai-code-puppy.sh force-update-code-puppy -> update only, ignoring the 7-day check

set -euo pipefail

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_UPDATE_FILE="$SCRIPT_DIR/.ai-code-puppy-last-update"
UPDATE_INTERVAL_DAYS=4
UPDATE_INTERVAL_SECONDS=$((UPDATE_INTERVAL_DAYS * 24 * 60 * 60))

# --- Helpers ---------------------------------------------------------------

# startCodePuppy: launches Code Puppy interactively
startCodePuppy() {
  # If in home directory, redirect to ~/Documents
  if [[ "$PWD" == "$HOME" ]]; then
    cd "$HOME/Documents"
  fi
  exec caffeinate -d -m -- "$HOME/.code-puppy-venv/bin/code-puppy" -i
}

# secondsSinceLastUpdate: echoes elapsed seconds since last successful update,
# or returns 1 if there is no record yet
secondsSinceLastUpdate() {
  if [ ! -f "$LAST_UPDATE_FILE" ]; then
    return 1
  fi
  local lastLine lastEpoch nowEpoch
  lastLine="$(head -n1 "$LAST_UPDATE_FILE" 2>/dev/null || true)"
  lastEpoch="${lastLine%%|*}"
  if [ -z "$lastEpoch" ] || ! [[ "$lastEpoch" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  nowEpoch="$(date +%s)"
  echo $((nowEpoch - lastEpoch))
  return 0
}

# recordSuccessfulUpdate: persists current date/time as the last successful update
recordSuccessfulUpdate() {
  local nowTs
  nowTs="$(date +"%s|%Y-%m-%d %H:%M:%S")"
  echo "$nowTs" > "$LAST_UPDATE_FILE"
  echo -e "${GREEN}Last successful update date saved: ${YELLOW}${nowTs##*|}${NC}"
}

# runUpdatePuppy FORCE: performs the actual update steps.
# FORCE="true" skips the 7-day validation, but the success timestamp is always recorded.
runUpdatePuppy() {
  local force="$1"

  if [ "$force" != "true" ]; then
    local elapsed
    if elapsed=$(secondsSinceLastUpdate); then
      if [ "$elapsed" -lt "$UPDATE_INTERVAL_SECONDS" ]; then
        local remainingSeconds remainingDays
        remainingSeconds=$((UPDATE_INTERVAL_SECONDS - elapsed))
        remainingDays=$(( (remainingSeconds + 86399) / 86400 ))
        echo -e "${YELLOW}Already updated less than ${UPDATE_INTERVAL_DAYS} days ago.${NC}"
        echo -e "${YELLOW}Approx. ${remainingDays} day(s) remaining until the next update is allowed.${NC}"
        echo -e "${YELLOW}Use './ai-code-puppy.sh force-update-code-puppy' to force it anyway.${NC}"
        return 0
      fi
    fi
  fi

  echo -e "${GREEN}Disabling proxies (unset-proxies)...${NC}"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/unset_proxies.sh" 2>/dev/null || true

  echo -e "${GREEN}Updating Code Puppy...${NC}"
  if curl -skSL https://puppy.walmart.com/api/releases/setup_v2 | bash; then
    echo -e "${GREEN}Update completed successfully.${NC}"
    recordSuccessfulUpdate
  else
    echo -e "${RED}The update failed. Last update date was not saved.${NC}"
    return 1
  fi
}

# --- Commands ----------------------------------------------------------------

case "${1:-start}" in
  start)
    echo -e "${GREEN}Checking Code Puppy update before starting...${NC}"
    # Best-effort: any block (7 days) or update failure is ignored,
    # the agent must always start.
    runUpdatePuppy "false" || true
    startCodePuppy
    ;;
  update-code-puppy)
    runUpdatePuppy "false"
    ;;
  force-update-code-puppy)
    runUpdatePuppy "true"
    ;;
  *)
    echo -e "${RED}Unknown command: ${YELLOW}${1}${NC}"
    echo -e "${YELLOW}Uso:${NC} ./ai-code-puppy.sh [start|update-code-puppy|force-update-code-puppy]"
    exit 1
    ;;
esac
