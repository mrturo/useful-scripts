#!/bin/bash

# Script: firebase_emul.sh
# Navigates to the project, detects the emulator UI port, and opens it automatically

# Unset proxy variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/unset_proxies.sh" 2>/dev/null || true

PROJECT_DIR="$HOME/projects/firestore-playground"
FIREBASE_JSON="$PROJECT_DIR/firebase.json"
DEFAULT_PORT=4000

# Detect UI port configured in firebase.json (if exists)
if [ -f "$FIREBASE_JSON" ]; then
  # Extract the UI port if configured
  UI_PORT=$(grep -o '"ui"[^{]*{[^}]*}' "$FIREBASE_JSON" | grep -o '"port"[ ]*:[ ]*[0-9]*' | grep -o '[0-9]*')
  if [ -z "$UI_PORT" ]; then
    UI_PORT=$DEFAULT_PORT
  fi
else
  UI_PORT=$DEFAULT_PORT
fi

cd "$PROJECT_DIR" || exit 1
LOG_FILE="/tmp/firebase_emul_$$.log"
caffeinate -s firebase emulators:start 2>&1 | tee "$LOG_FILE" &
EMUL_PID=$!
sleep 5

# Check for errors in the log
if grep -qE 'Could not start|Shutting down emulators|unable to start' "$LOG_FILE"; then
  echo "\n[ERROR] Firebase Emulator failed to start. See log below:"
  cat "$LOG_FILE"
  wait $EMUL_PID
  exit 1
else
  open "http://127.0.0.1:$UI_PORT/"
  wait $EMUL_PID
fi
rm -f "$LOG_FILE"
