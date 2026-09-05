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
UPDATE_INTERVAL_DAYS=7
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
  echo -e "${GREEN}Fecha de ultima actualizacion guardada: ${YELLOW}${nowTs##*|}${NC}"
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
        echo -e "${YELLOW}Ya se actualizo hace menos de ${UPDATE_INTERVAL_DAYS} dias.${NC}"
        echo -e "${YELLOW}Faltan aprox. ${remainingDays} dia(s) para la proxima actualizacion permitida.${NC}"
        echo -e "${YELLOW}Usa './ai-code-puppy.sh force-update-code-puppy' para forzarla igualmente.${NC}"
        return 0
      fi
    fi
  fi

  echo -e "${GREEN}Desactivando proxies (unset-proxies)...${NC}"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/unset_proxies.sh" 2>/dev/null || true

  echo -e "${GREEN}Actualizando Code Puppy...${NC}"
  if curl -skSL https://puppy.walmart.com/api/releases/setup_v2 | bash; then
    echo -e "${GREEN}Actualizacion completada exitosamente.${NC}"
    recordSuccessfulUpdate
  else
    echo -e "${RED}La actualizacion fallo. No se guardo la fecha de ultima actualizacion.${NC}"
    return 1
  fi
}

# --- Commands ----------------------------------------------------------------

case "${1:-start}" in
  start)
    echo -e "${GREEN}Verificando actualizacion de Code Puppy antes de iniciar...${NC}"
    # Best-effort: se ignora cualquier bloqueo (7 dias) o fallo de la actualizacion,
    # el agente debe iniciar siempre.
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
    echo -e "${RED}Comando desconocido: ${YELLOW}${1}${NC}"
    echo -e "${YELLOW}Uso:${NC} ./ai-code-puppy.sh [start|update-code-puppy|force-update-code-puppy]"
    exit 1
    ;;
esac
