#!/usr/bin/env bash
# AI Code Puppy Safe Launcher & Updater
# Default (no args): first triggers the non-forced update (update-code-puppy),
#   which is skipped/aborted silently if it hasn't been 7 days yet or if it
#   fails for any other reason, then ALWAYS launches Code Puppy afterwards
#   via 'caffeinate -d -m -- $HOME/.code-puppy-venv/bin/code-puppy -i'.
#   If running from home directory, redirects to ~/Documents first.
#   The installed version is compared against the latest published
#   release FIRST, before any cooldown logic: behind -> update right
#   now (bypassing the cooldown, so Code Puppy's own internal startup
#   auto-updater never gets a chance to fire and stall); already
#   current -> skip immediately, no reinstall of the same version.
#   The day-based cooldown is only a fallback for when that comparison
#   is inconclusive (offline, broken venv, version API unreachable).
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

CODE_PUPPY_VENV_PYTHON="$HOME/.code-puppy-venv/bin/python"

# getInstalledVersion: echoes the installed code_puppy package version, or
# nothing if it can't be determined (missing venv, broken install, etc).
getInstalledVersion() {
  if [ ! -x "$CODE_PUPPY_VENV_PYTHON" ]; then
    return 1
  fi
  "$CODE_PUPPY_VENV_PYTHON" -c "from code_puppy import __version__; print(__version__)" 2>/dev/null
}

# getLatestAvailableVersion: echoes the latest published version from the
# SAME release-metadata endpoint Code Puppy's own internal auto-updater
# checks (api/releases/latest), or nothing if unreachable/unparsable.
getLatestAvailableVersion() {
  local json
  json="$(curl -skS --max-time 10 "https://puppy.walmart.com/api/releases/latest" 2>/dev/null || true)"
  if [ -z "$json" ]; then
    return 1
  fi
  if [ ! -x "$CODE_PUPPY_VENV_PYTHON" ]; then
    return 1
  fi
  "$CODE_PUPPY_VENV_PYTHON" -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get('data', {}).get('version', ''))
except Exception:
    pass
" <<<"$json"
}

# versionIsNewer LATEST CURRENT: succeeds (exit 0) only if LATEST is
# strictly newer than CURRENT, using the same dotted-numeric comparison
# Code Puppy's own version_checker.version_is_newer uses, so we never
# disagree with its internal logic (no accidental downgrades either).
versionIsNewer() {
  local latest="$1" current="$2"
  if [ -z "$latest" ] || [ -z "$current" ] || [ ! -x "$CODE_PUPPY_VENV_PYTHON" ]; then
    return 1
  fi
  "$CODE_PUPPY_VENV_PYTHON" -c "
import sys

def as_tuple(v):
    v = (v or '').lstrip('v')
    try:
        return tuple(int(x) for x in v.split('.'))
    except (ValueError, AttributeError):
        return None

latest = as_tuple(sys.argv[1])
current = as_tuple(sys.argv[2])
sys.exit(0 if (latest is not None and current is not None and latest > current) else 1)
" "$latest" "$current"
}

# runUpdatePuppy FORCE: performs the actual update steps.
# FORCE="true" skips the 7-day validation, but the success timestamp is always recorded.
runUpdatePuppy() {
  local force="$1"

  if [ "$force" != "true" ]; then
    # Version check is the SOURCE OF TRUTH now, not the day-based
    # cooldown below. If we can get a definitive answer:
    #   - behind latest  -> update NOW, bypassing the cooldown entirely
    #     (stops Code Puppy's own startup auto-updater from stalling on
    #     a slow dependency install -- see commit history).
    #   - already current -> skip, full stop. No point re-running the
    #     whole install script every N days just to reinstall the same
    #     version.
    # The day-based cooldown only kicks in below as a fallback for when
    # this comparison is inconclusive (offline, broken venv, API down).
    local installedVersion latestVersion
    installedVersion="$(getInstalledVersion || true)"
    latestVersion="$(getLatestAvailableVersion || true)"

    if [ -n "$installedVersion" ] && [ -n "$latestVersion" ]; then
      if versionIsNewer "$latestVersion" "$installedVersion"; then
        echo -e "${YELLOW}Installed version (${installedVersion}) is behind the latest (${latestVersion}).${NC}"
        echo -e "${YELLOW}Updating now, bypassing the ${UPDATE_INTERVAL_DAYS}-day cooldown, to avoid Code Puppy's own startup auto-updater stalling.${NC}"
        force="true"
      else
        echo -e "${GREEN}Already up to date (installed: ${installedVersion}, latest: ${latestVersion}). Skipping update.${NC}"
        return 0
      fi
    fi
  fi

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
