#!/usr/bin/env bash
# macOS All-in-One Updater — hardened for repeatable runs
# Comments in English + emojis; ANSI colors only in console (log stays plain).
# Updates: macOS (softwareupdate) 🧩, App Store (mas) 🛒 (safe fallback),
# Homebrew 🍺, Java/jenv shims 🔧, IntelliJ plugins 🧠, VS Code extensions 🧩,
# plus developer toolchains with safe guards (Node/npm, RubyGems, Python).
#
# Usage:
#   chmod +x update_mac_all.sh
#   ./update_mac_all.sh [--no-os] [--no-mas] [--no-brew] [--no-restart] [--auto-restart] \
#                       [--dry-run] [--yes] [--ide] [--no-ide]
#
# Flags:
#   --no-os         Skip macOS updates (softwareupdate)
#   --no-mas        Skip App Store updates (mas)
#   --no-brew       Skip Homebrew updates
#   --no-restart    Never auto-restart
#   --auto-restart  Auto-restart if required (prompts for a keypress)
#   --dry-run       Print commands without executing
#   --yes           Assume “yes” for safe confirmations (non-interactive)
#   --ide           Force updating IntelliJ plugins & VS Code extensions
#   --no-ide        Skip IDE updates
#
# Optional requirements:
#   - mas (brew install mas)
#   - IntelliJ CLI launcher `idea` (Tools → Create Command-line Launcher)
#   - VS Code CLI `code` (Command Palette → “Shell Command: Install 'code' command in PATH”)

set -euo pipefail

# ==========================
# 🎨 Console colors (ANSI) — console only; log remains plain
# ==========================
if [[ -t 1 ]]; then
  C_RESET="\033[0m"
  C_DIM="\033[2m"
  C_BOLD="\033[1m"
  C_INFO="\033[1;36m"     # cyan
  C_OK="\033[1;32m"       # green
  C_WARN="\033[1;33m"     # yellow
  C_ERR="\033[1;31m"      # red
  C_CMD="\033[0;35m"      # magenta
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_CMD=""
fi

# ==========================
# 🔧 Config & logging
# ==========================
NO_OS=false
NO_MAS=false
NO_BREW=false
NO_RESTART=false
AUTO_RESTART=false
DRY_RUN=false
ASSUME_YES=false
FORCE_IDE=""  # "yes" | "no" | ""

LOG_DIR="${HOME}/Library/Logs/sys-maint"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/update_mac_all_$(date +%Y%m%d_%H%M%S).log"

RESTART_REQUIRED=false

# Console + log helpers (ANSI only to console)
log_console() { printf "%b%s%b\n" "${C_DIM}" "$*" "${C_RESET}"; }
log_file()    { printf '%s\n' "$*" >> "${LOG_FILE}"; }
log_both()    { log_console "$*"; log_file "$*"; }

log() { log_both "$(date +'%F %T') $*"; }
section() {
  local banner="============================================================"
  printf "%b\n# %s\n%b\n" "${banner}" "$*" "${banner}" >> "${LOG_FILE}"
  printf "%b\n%b# %s%b\n%b\n" "${C_DIM}${banner}${C_RESET}" "${C_INFO}" "$*" "${C_RESET}" "${C_DIM}${banner}${C_RESET}"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }
die() { log "$(printf '%bERROR:%b %s' "${C_ERR}" "${C_RESET}" "$*")"; exit 1; }

usage() {
  sed -n '1,140p' "$0" | sed -n '1,100p'
}

confirm() {
  local prompt="${1:-Continue?} [y/N]: "
  if $ASSUME_YES; then log "AUTO-YES: ${prompt}"; return 0; fi
  read -r -p "$(printf '%b%s%b' "${C_WARN}" "${prompt}" "${C_RESET}")" ans || true
  [[ "${ans:-}" =~ ^[Yy](es)?$ ]]
}

run() {
  local cmd="$*"
  printf "%b$ %s%b\n" "${C_CMD}" "${cmd}" "${C_RESET}"
  printf '$ %s\n' "${cmd}" >> "${LOG_FILE}"
  if $DRY_RUN; then return 0; fi
  bash -lc "$cmd" 2>&1 | tee -a "${LOG_FILE}"
}

# ==========================
# 🧭 Flags
# ==========================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-os)        NO_OS=true; shift ;;
    --no-mas)       NO_MAS=true; shift ;;
    --no-brew)      NO_BREW=true; shift ;;
    --no-restart)   NO_RESTART=true; shift ;;
    --auto-restart) AUTO_RESTART=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --yes)          ASSUME_YES=true; shift ;;
    --ide)          FORCE_IDE="yes"; shift ;;
    --no-ide)       FORCE_IDE="no"; shift ;;
    --help|-h)      usage; exit 0 ;;
    *)              die "Unknown flag: $1" ;;
  esac
done

# ==========================
# 🛫 Preflight
# ==========================
[[ "$(uname -s)" == "Darwin" ]] || die "This script is macOS-only."
START_TIME="$(date +'%F %T')"
section "Start"
log "Log file → ${LOG_FILE}"
log "Flags → no-os=${NO_OS} no-mas=${NO_MAS} no-brew=${NO_BREW} no-restart=${NO_RESTART} auto-restart=${AUTO_RESTART} dry-run=${DRY_RUN} yes=${ASSUME_YES} ide=${FORCE_IDE:-auto}"

# ==========================
# 🧰 Functions
# ==========================
unset_http_proxies() {
  local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/unset_proxies.sh" 2>/dev/null || { log "Failed to unset proxies"; return 1; }
}

ensure_xcode_clt() {
  section "Xcode Command Line Tools ⚙️"
  if xcode-select -p >/dev/null 2>&1; then
    log "CLT present ✅"
  else
    log "Installing CLT… ⏳"
    run "xcode-select --install || true"
    log "If a GUI dialog appears, finish the installation and rerun this script."
  fi
}

update_macos() {
  $NO_OS && { log "Skipped: softwareupdate (--no-os)"; return; }
  section "macOS Updates (softwareupdate) 🧩"
  if ! has_cmd softwareupdate; then log "softwareupdate not available"; return; fi
  run "softwareupdate -l || true"

  # Install all recommended updates; detect if restart is required.
  local out_file; out_file="$(mktemp)"
  if $DRY_RUN; then
    log "DRY-RUN: softwareupdate -ia --verbose"
  else
    set +e
    softwareupdate -ia --verbose 2>&1 | tee -a "${LOG_FILE}" | tee "${out_file}"
    local rc=$?
    set -e
    if grep -qi "restart" "${out_file}"; then
      RESTART_REQUIRED=true
      log "Restart required by softwareupdate 🔁"
    fi
    rm -f "${out_file}"
    if (( rc != 0 )); then
      log "softwareupdate exited with code ${rc} (continuing)."
    fi
  fi
}

update_app_store() {
  $NO_MAS && { log "Skipped: App Store (mas) (--no-mas)"; return; }
  section "App Store Updates (mas) 🛒"
  if ! has_cmd mas; then
    log "mas not found. Install with: brew install mas"
    return
  fi

  # Sonoma+ often breaks 'mas account' and interactive signin in headless mode.
  if ! mas account >/dev/null 2>&1; then
    log "Skipping mas: not logged in or unsupported on this macOS version."
    log "Recommendation: open App Store, ensure you're signed in, and update GUI apps there."
    return
  fi

  run "mas outdated || true"
  run "mas upgrade || true"
}

brew_update_upgrade() {
  $NO_BREW && { log "Skipped: Homebrew (--no-brew)"; return; }
  section "Homebrew 🍺 — update/upgrade/cleanup/doctor"
  if ! has_cmd brew; then die "Homebrew is not installed."; fi

  # Keep Homebrew quiet & predictable in scripts.
  export HOMEBREW_NO_ANALYTICS=1
  export HOMEBREW_NO_INSTALL_CLEANUP=1
  export HOMEBREW_NO_AUTO_UPDATE=1

  run "brew update || true"
  run "brew upgrade || true"
  run "brew upgrade --cask --greedy || true"
  run "brew cleanup -s || true"
  run "brew doctor || true"
}

fix_path_priority() {
  section "Ensuring Homebrew precedes /usr/bin in PATH 🧭"
  # Only append if missing; keeps idempotency.
  if ! grep -q '/opt/homebrew/bin' "${HOME}/.zshrc" 2>/dev/null; then
    echo 'export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"' >> "${HOME}/.zshrc"
    log "Added Homebrew bin/sbin to ~/.zshrc"
  else
    log "PATH already includes /opt/homebrew/bin"
  fi
}

repair_jenv_and_mvn_shims() {
  section "Post-Brew: jenv/mvn shims hardening 🔧"
  if has_cmd jenv; then
    # Remove stale lock to avoid shim deadlocks after upgrades. ✅
    if [[ -f "${HOME}/.jenv/shims/.jenv-shim" ]]; then
      run "rm -f \"${HOME}/.jenv/shims/.jenv-shim\""
    fi
    run "jenv rehash || true"

    # Quick inspection (helps when troubleshooting broken shims). 🔍
    if [[ -f "${HOME}/.jenv/shims/mvn" ]]; then
      log "First lines of mvn shim:"
      if $DRY_RUN; then
        log "(dry-run) sed -n '1,30p' \"${HOME}/.jenv/shims/mvn\""
      else
        sed -n '1,30p' "${HOME}/.jenv/shims/mvn" >> "${LOG_FILE}" || true
      fi
    fi

    # Sanity checks — ensures JAVA_HOME/JDKs are visible and Maven resolves. 🧪
    run "command -v mvn || true"
    run "/usr/libexec/java_home -V || true"
    run "mvn -v || true"
    run "java -version || true"
  else
    log "jenv not installed; nothing to repair."
  fi
}

# IntelliJ plugins via CLI: `idea installPlugins <IDs>` or macOS `open -na "...app" --args installPlugins <IDs>`
update_intellij_plugins() {
  section "IntelliJ IDEA Plugins 🧠"
  # 👉 Edit this list to your stack. Plugin IDs are shown in JetBrains Marketplace (Plugin ID).
  local IDEA_PLUGIN_IDS=(
    tanvd.grazi                 # Grazie Lite
    org.mapstruct.intellij      # MapStruct Support
    com.intellij.plugins.lombok # Lombok
    # maven.helper              # Maven Helper (uncomment if you use it)
    # org.jetbrains.kotlin      # Kotlin (if needed)
  )

  # Close running IDEs to avoid plugin dir locks. 🧹
  if has_cmd osascript; then
    run "osascript -e 'tell application \"IntelliJ IDEA\" to quit' || true"
    run "osascript -e 'tell application \"IntelliJ IDEA CE\" to quit' || true"
    run "osascript -e 'tell application \"IntelliJ IDEA Ultimate\" to quit' || true"
  fi

  if has_cmd idea; then
    run "idea installPlugins ${IDEA_PLUGIN_IDS[*]}"
  else
    # Detect which IntelliJ IDEA is installed
    local APP_NAME=""
    if [[ -d "/Applications/IntelliJ IDEA Ultimate.app" ]]; then
      APP_NAME="IntelliJ IDEA Ultimate.app"
    elif [[ -d "/Applications/IntelliJ IDEA CE.app" ]]; then
      APP_NAME="IntelliJ IDEA CE.app"
    elif [[ -d "/Applications/IntelliJ IDEA.app" ]]; then
      APP_NAME="IntelliJ IDEA.app"
    fi

    if [[ -n "${APP_NAME}" ]]; then
      run "open -na \"/Applications/${APP_NAME}\" --args installPlugins ${IDEA_PLUGIN_IDS[*]}"
    else
      log "IntelliJ IDEA not found in /Applications. Skipping plugin updates."
      log "Install 'idea' CLI (Tools → Create Command-line Launcher) or ensure IntelliJ is in /Applications."
    fi
  fi

  log "Adjust IDEA_PLUGIN_IDS to add/remove plugins as needed."
}

update_vscode_extensions() {
  section "VS Code Extensions 🧩"
  if has_cmd code; then
    # Since VS Code 1.86 — updates every installed extension. ✅
    run "code --update-extensions || true"

    # To enforce a baseline, uncomment and edit:
    # local VSCODE_EXT_IDS=(ms-python.python vscjava.vscode-java-pack redhat.java eamodio.gitlens)
    # for ext in \"${VSCODE_EXT_IDS[@]}\"; do run "code --install-extension \"$ext\" --force"; done
  else
    log "VS Code CLI 'code' not found. Use Command Palette → 'Shell Command: Install \"code\" command in PATH'."
  fi
}

maybe_update_ides() {
  local do_it=""
  if [[ -n "${FORCE_IDE}" ]]; then
    do_it="${FORCE_IDE}"
  else
    confirm "Update IDE plugins/extensions now?" && do_it="yes" || do_it="no"
  fi

  if [[ "${do_it}" == "yes" ]]; then
    update_intellij_plugins
    update_vscode_extensions
  else
    log "IDE updates skipped."
  fi
}

# --- Safe Node/npm update (avoid global perms in /usr/local) ---
update_npm_global() {
  section "Node.js global packages (safe mode) 🌐"
  if has_cmd npm; then
    local prefix
    prefix=$(npm config get prefix 2>/dev/null || echo "")
    if [[ "$prefix" == "/usr/local" || "$prefix" == /usr/local/* ]]; then
      log "Skipping npm global update: insufficient permissions (prefix=$prefix)."
      log "Recommendation: manage Node via nvm or Homebrew (node/corepack) to avoid /usr/local."
    else
      run "npm -g update || true"
      run "npm -g list --depth=0 || true"
    fi
  else
    log "npm not found."
  fi
}

# --- Safe Ruby update (avoid system Ruby in /Library/Ruby) ---
update_ruby_safe() {
  section "RubyGems safe update 💎"
  if has_cmd gem; then
    if gem env home | grep -q "/Library/Ruby"; then
      log "System Ruby detected → skipping gem updates (read-only)."
      log "Recommendation: use rbenv/rtx/ruby-install for isolated Ruby versions."
      return
    fi
    run "gem update --system || true"
    run "gem update || true"
  else
    log "gem not found."
  fi
}

# --- Python: basic pip self-update but avoid system paths noise ---
update_python_tools() {
  section "Python tools (pip self-update) 🐍"
  if has_cmd python3; then
    run "python3 -m pip install --upgrade pip || true"
  else
    log "python3 not found."
  fi
}

# --- Developer toolchains orchestrator ---
dev_tools_updates() {
  section "Developer Toolchains (optional) 🧰"
  update_npm_global
  update_ruby_safe
  update_python_tools
  if has_cmd pipx; then
    run "pipx upgrade-all || true"
  fi
}

# --- Legacy Intel files under /usr/local: warn to keep idempotence ---
cleanup_legacy_usr_local() {
  section "Checking legacy /usr/local (Intel) files 🧹"
  local warned=false
  if [[ -d /usr/local/lib ]] && ls /usr/local/lib/libwep_* >/dev/null 2>&1; then
    log "Detected legacy dylibs in /usr/local/lib: libwep_* (likely Intel leftovers)."
    warned=true
  fi
  if [[ -d /usr/local/include/python3.9 ]]; then
    log "Detected old Python 3.9 headers in /usr/local/include/python3.9."
    warned=true
  fi
  if [[ -f /usr/local/lib/libpython3.9.a ]]; then
    log "Detected old static lib: /usr/local/lib/libpython3.9.a."
    warned=true
  fi
  if [[ -d /usr/local/lib/pkgconfig ]] && ls /usr/local/lib/pkgconfig/python-3.9* >/dev/null 2>&1; then
    log "Detected old pkgconfig files for Python 3.9 in /usr/local/lib/pkgconfig."
    warned=true
  fi
  if [[ "$warned" != true ]]; then
    log "No obvious Intel leftovers detected."
  else
    log "Recommendation: review and remove these Intel-era files if you no longer need them."
  fi
}

post_checks() {
  section "Post-Checks ✅"
  run "/usr/libexec/java_home -V || true"
  run "mvn -v || true"
  run "java -version || true"
  if has_cmd code; then run "code --version || true"; fi
}

summary_report() {
  section "Summary 🧾"
  log "macOS: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
  log "Brew:  $(brew --version 2>/dev/null | head -n1 || echo 'none')"
  log "Java:  $(java -version 2>&1 | head -n1 || echo 'none')"
  log "Node:  $(node -v 2>/dev/null || echo 'none')"
  log "npm:   $(npm -v 2>/dev/null || echo 'none')"
  log "Python: $(python3 --version 2>/dev/null || echo 'none')"
  log "Ruby:  $(ruby --version 2>/dev/null || echo 'none')"
}

# ==========================
# 🚀 Execution
# ==========================
unset_http_proxies
ensure_xcode_clt
update_macos
update_app_store
brew_update_upgrade
fix_path_priority                 # keep Homebrew tools ahead of /usr/bin
repair_jenv_and_mvn_shims         # avoid stale jenv/mvn shims after brew updates
maybe_update_ides
dev_tools_updates
cleanup_legacy_usr_local          # warn-only, keeps runs safe & idempotent
post_checks
summary_report

# ==========================
# 🧷 Finish & restart
# ==========================
section "Done 🎯"
END_TIME="$(date +'%F %T')"
log "Start: ${START_TIME}"
log "End:   ${END_TIME}"

if $RESTART_REQUIRED; then
  log "System restart is required."
  if $AUTO_RESTART && ! $DRY_RUN && ! $NO_RESTART; then
    printf "%bPress any key to restart now, or Ctrl+C to abort…%b " "${C_WARN}" "${C_RESET}"
    # shellcheck disable=SC2162
    read -n 1 -s _
    printf "\nRestarting… 🔁\n"
    if has_cmd osascript; then
      osascript -e 'tell application "System Events" to restart'
    else
      sudo shutdown -r now
    fi
  else
    log "Auto-restart not executed. Please restart when convenient."
  fi
else
  log "No restart required."
fi