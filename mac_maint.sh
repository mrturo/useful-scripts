#!/usr/bin/env bash
# macOS Disk First Aid + Cache Cleanup + Spotlight Reindex
# - Verifies / and repairs only if needed (or forced).
# - Cleans caches (user-only by default; optional system-wide with --clean-caches=all).
# - Reindexes Spotlight.
# - Colors/emojis in console; logs without ANSI.
# Usage:
#   chmod +x mac_maint.sh
#   ./mac_maint.sh                      # verify → repair-if-needed
#   ./mac_maint.sh --verify             # verify only
#   ./mac_maint.sh --repair             # force repair
#   ./mac_maint.sh --clean-caches       # clean user caches: ~/Library/Caches/*
#   ./mac_maint.sh --clean-caches=all   # clean user + system caches (uses sudo)  ⚠️
#   ./mac_maint.sh --reindex-spotlight  # sudo mdutil -E /
#   Flags can be combined (e.g., --verify --clean-caches)

set -Eeuo pipefail

# ===== CLI flags =====
FORCE_REPAIR=false
VERIFY_ONLY=false
DO_VERIFY_REPAIR=true
DO_CLEAN_CACHES=false
CLEAN_SCOPE="user"   # user | all
DO_REINDEX_SPOTLIGHT=false

for a in "${@:-}"; do
  case "$a" in
    --repair) FORCE_REPAIR=true ;;
    --verify) VERIFY_ONLY=true ; DO_VERIFY_REPAIR=true ;;
    --clean-caches) DO_CLEAN_CACHES=true ; CLEAN_SCOPE="user" ;;
    --clean-caches=all) DO_CLEAN_CACHES=true ; CLEAN_SCOPE="all" ;;
    --reindex-spotlight) DO_REINDEX_SPOTLIGHT=true ;;
    --help|-h)
      sed -n '1,40p' "$0"; exit 0 ;;
    *)
      # If only specific tasks are passed, we don't force verify/repair by default
      if [[ "$a" == --* ]]; then
        echo "Unknown flag: $a" >&2; exit 2
      fi
      ;;
  esac
done

# If the user requested ONLY specific tasks, don't run verify/repair by default
if $DO_CLEAN_CACHES || $DO_REINDEX_SPOTLIGHT; then
  if ! $VERIFY_ONLY && ! $FORCE_REPAIR && [[ $# -gt 0 ]]; then
    DO_VERIFY_REPAIR=false
  fi
fi

# ===== Colors (console only) =====
BOLD="\033[1m"; RESET="\033[0m"
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"

log_console() { echo -e "$1"; }
log_file()    { echo -e "${1//\\033\[[0-9;]*m/}" >> "$LOG_FILE"; }
log_both()    { log_console "$1"; log_file "$1"; }

info() {  log_both "${BLUE}ℹ️  $*${RESET}"; }
ok()   {  log_both "${GREEN}✅ $*${RESET}"; }
warn() {  log_both "${YELLOW}⚠️  $*${RESET}"; }
err()  {  log_both "${RED}❌ $*${RESET}"; }

# ===== Logging =====
LOG_DIR="$HOME/Library/Logs/sys-maint"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/mac_maint_$(date '+%Y%m%d_%H%M%S').log"

log_both "============================================================"
log_both "# macOS Maintenance — $(date)"
log_both "Log file → $LOG_FILE"
log_both "============================================================"

# ===== Helpers =====
require_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing binary: $1"; exit 127; }
}
keep_sudo_alive() {
  if ! sudo -vn 2>/dev/null; then info "🔒 Requesting admin privileges…"; sudo -v; fi
  while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
}
path_is_safe_glob() {
  # Avoid dangerous rm: don't allow target to be empty or /
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" == /* ]] || return 1
  [[ "$p" != "/" ]] || return 1
  return 0
}

require_bin diskutil
require_bin awk
require_bin grep

# ===== (A) Verify & (conditional) Repair =====
if $DO_VERIFY_REPAIR; then
  ROOT_DEV="$(diskutil info / | awk -F': *' '/Device Identifier/ {print $2}')"
  info "🧭 Root volume device: ${BOLD}/dev/${ROOT_DEV:-unknown}${RESET}"

  log_both "============================================================"
  info "🔎 Step 1: Verifying main volume (/)"
  VERIFY_OUT="$(diskutil verifyVolume / 2>&1 | tee -a "$LOG_FILE" || true)"

  APPEARS_OK=false
  if echo "$VERIFY_OUT" | grep -qiE "appears to be OK|File system check exit code is 0"; then
    APPEARS_OK=true
  fi

  if $APPEARS_OK && ! $FORCE_REPAIR; then
    ok "Verification: volume appears to be OK. No repair needed."
    if $VERIFY_ONLY; then
      log_both "============================================================"
      ok "Completed (verify-only) at $(date)"
      log_both "============================================================"
      # don't exit yet; there may be more flags (clean/reindex)
    fi
  elif $VERIFY_ONLY; then
    warn "Verify-only: issues detected."
  fi

  if ! $VERIFY_ONLY && { ! $APPEARS_OK || $FORCE_REPAIR; }; then
    log_both "============================================================"
    if $FORCE_REPAIR; then
      warn "Forcing repair due to --repair flag."
    else
      warn "Issues detected during verification. Proceeding to repair…"
    fi
    info "🧰 Step 2: Repairing main volume (/)"
    keep_sudo_alive
    REPAIR_OUT="$(sudo diskutil repairVolume / 2>&1 | tee -a "$LOG_FILE" || true)"
    REPAIR_RC=$?

    if [[ $REPAIR_RC -eq 0 ]]; then
      ok "Repair completed successfully."
    else
      if echo "$REPAIR_OUT" | grep -qiE "Unable to unmount volume for repair|error.*-69673"; then
        warn "Could not unmount system volume for repair (code -69673). Run in macOS Recovery."
        cat <<'EOF' | tee -a "$LOG_FILE"
🔁 Recovery Mode steps:
  - Apple Silicon: Shut down → hold power button until “Options” → Continue.
  - Intel: Reboot and hold ⌘R.
  - Use Disk Utility → First Aid, or Terminal: diskutil repairVolume /
EOF
      else
        err "Repair failed with exit code ${REPAIR_RC}. See log: $LOG_FILE"
      fi
    fi
  fi
fi

# ===== (B) Clean Cache & Logs =====
if $DO_CLEAN_CACHES; then
  log_both "============================================================"
  info "🧽 Clean Cache & Logs"

  # 1) User caches (safe, without sudo)
  USER_CACHE_GLOB="$HOME/Library/Caches/*"
  if path_is_safe_glob "$USER_CACHE_GLOB"; then
    info "👤 Cleaning user caches: $USER_CACHE_GLOB"
    # Show estimated size before
    du -sh "$HOME/Library/Caches" 2>/dev/null | awk '{print "   (before) ~"$1}' | tee -a "$LOG_FILE" >/dev/null || true
    rm -rf $HOME/Library/Caches/* 2>>"$LOG_FILE" || true
  else
    err "Unsafe path resolved for user caches. Aborting user cache cleanup."
  fi

  # 2) System caches (optional, requires sudo) — with caution
  if [[ "$CLEAN_SCOPE" == "all" ]]; then
    keep_sudo_alive
    SYS_CACHE_GLOB="/Library/Caches/*"
    if path_is_safe_glob "$SYS_CACHE_GLOB"; then
      warn "System-wide cache cleanup enabled (--clean-caches=all). Proceeding with caution."
      du -sh /Library/Caches 2>/dev/null | awk '{print "   (before) ~"$1}' | tee -a "$LOG_FILE" >/dev/null || true
      sudo rm -rf /Library/Caches/* 2>>"$LOG_FILE" || true
    else
      err "Unsafe path resolved for system caches. Skipping system cache cleanup."
    fi
  fi

  ok "Cache cleanup completed."
fi

# ===== (C) Reindex Spotlight =====
if $DO_REINDEX_SPOTLIGHT; then
  log_both "============================================================"
  info "🔎 Reindexing Spotlight (sudo mdutil -E /)"
  keep_sudo_alive
  if sudo mdutil -E / 2>&1 | tee -a "$LOG_FILE"; then
    ok "Spotlight reindex triggered. Indexing will run in background."
  else
    err "Failed to trigger Spotlight reindex. See log."
  fi
fi

log_both "============================================================"
ok "Finished at $(date)"
log_both "============================================================"