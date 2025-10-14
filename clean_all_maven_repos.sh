#!/usr/bin/env bash
# clean_all_maven_repos.sh — Bash 3.2 compatible (macOS)
# Limpia proyectos Maven dentro de repos Git, reporta estado Git, auto-sincroniza y hace pruning condicionado.
#
# Novedad: antes de ejecutar `mvn clean` valida si hay algo que limpiar (carpetas `target/` no vacías,
# incluso en submódulos). Si no hay nada, omite el `clean`.

set -euo pipefail

# -------- Args / Flags ---------------------------------------------------------
BASE_DIR="${1:-.}"; shift || true 2>/dev/null || true

DRY_RUN=false
DEEP=false
EXCLUDE_CSV=""
CHANGED_ONLY=false
SINCE_DAYS=30
REPORT_ONLY=false
ONLY_DIRTY=false
ONLY_UNPUSHED=false
SYNC_CMD="$HOME/Documents/scripts/git_util.sh git-pull-all"
PRUNE_CMD="$HOME/Documents/scripts/git_util.sh prune-local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=true ;;
    --deep)           DEEP=true ;;
    --exclude)        EXCLUDE_CSV="${2:-}"; shift ;;
    --changed-only)   CHANGED_ONLY=true ;;
    --since)          SINCE_DAYS="${2:-30}"; shift ;;
    --report-only)    REPORT_ONLY=true ;;
    --only-dirty)     ONLY_DIRTY=true ;;
    --only-unpushed)  ONLY_UNPUSHED=true ;;
    --sync-cmd)       SYNC_CMD="${2:-"$SYNC_CMD"}"; shift ;;
    --prune-cmd)      PRUNE_CMD="${2:-"$PRUNE_CMD"}"; shift ;;
    *) ;;
  esac
  shift || true
done

# -------- Logging --------------------------------------------------------------
LOG_DIR="$HOME/Library/Logs/sys-maint"
mkdir -p "$LOG_DIR"
TS="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="$LOG_DIR/mvn_clean_${TS}.log"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE"; }

command -v find >/dev/null || { echo "find not available"; exit 127; }

IFS=',' read -r -a EX_PATTERNS <<< "${EXCLUDE_CSV}"

exclude_path() {
  local p="$1" i
  for i in "${EX_PATTERNS[@]:-}"; do
    [[ -z "$i" ]] && continue
    if printf "%s" "$p" | grep -F -q "$i"; then return 0; fi
  done
  return 1
}

repo_is_active() {
  local r="$1"
  ( cd "$r" && { [[ -n "$(git status --porcelain 2>/dev/null || true)" ]] \
    || [[ -n "$(git log --since="${SINCE_DAYS}.days" --pretty=oneline 2>/dev/null || true)" ]]; } )
}

# -------- Git state detection (salida KEY=VALUE) -------------------------------
git_state() {
  local branch upstream has_upstream pending_work pending_push ahead behind
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo UNKNOWN)"
  [[ "$branch" == "HEAD" ]] && branch="DETACHED"

  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    pending_work=true
  else
    pending_work=false
  fi

  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    has_upstream=true
    ahead="$(git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null | awk '{print $2+0}' || echo 0)"
    behind="$(git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null | awk '{print $1+0}' || echo 0)"
    if [[ "${ahead:-0}" -gt 0 ]]; then pending_push=true; else pending_push=false; fi
  else
    has_upstream=false
    ahead=0
    behind=0
    pending_push=false
  fi

  echo "BRANCH=$branch"
  echo "HAS_UPSTREAM=$has_upstream"
  echo "PENDING_WORK=$pending_work"
  echo "PENDING_PUSH=$pending_push"
  echo "AHEAD=${ahead:-0}"
  echo "BEHIND=${behind:-0}"
}

# -------- ¿Hay algo que limpiar? ----------------------------------------------
needs_clean() {
  # Devuelve 0 (true) si existe alguna carpeta target/ con contenido (no solo .gitignore)
  # Revisa el target inmediato y, si no encuentra, busca recursivamente en subcarpetas (submódulos).
  local p="$1"

  # 1) Target inmediato
  if [[ -d "$p/target" ]]; then
    if find "$p/target" -mindepth 1 -not -name ".gitignore" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  fi

  # 2) Targets en subdirectorios (evita .git)
  local t
  while IFS= read -r -d '' t; do
    if find "$t" -mindepth 1 -not -name ".gitignore" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done < <(find "$p" -type d -name target -not -path "$p/.git/*" -print0 2>/dev/null || true)

  return 1
}

# -------- Maven runner ---------------------------------------------------------
clean_one_dir() {
  local pdir="$1"
  local runner=""
  if [[ -x "$pdir/mvnw" ]]; then
    runner="$pdir/mvnw"
  elif command -v mvn >/dev/null 2>&1; then
    runner="mvn"
  else
    log "SKIP: $pdir — sin mvnw ni mvn en PATH"
    return 200
  fi

  # Validar si hay algo que limpiar
  if ! needs_clean "$pdir"; then
    if $DRY_RUN || $REPORT_ONLY; then
      log "DRY-RUN: ($pdir) no hay nada que limpiar → omite mvn clean"
    else
      log "Info         : ($pdir) no hay nada que limpiar → omite mvn clean"
    fi
    return 0
  fi

  if $DRY_RUN || $REPORT_ONLY; then
    log "DRY-RUN: ($pdir) ejecutaría: $runner clean"
    return 0
  fi

  ( cd "$pdir" && "$runner" -q clean ) && return 0 || return $?
}

# -------- Sync runner robusto (PATH o zsh -ic/-lc) ----------------------------
run_git_sync() {
  local repodir="$1"
  local cmd="$SYNC_CMD"
  local first
  first="$(bash -lc "set -o posix; set -- $cmd; printf '%s' \"\$1\"")"

  if [[ -n "$first" && -e "$first" ]]; then
    if [[ -x "$first" ]]; then ( cd "$repodir" && eval "$cmd" ); return $?
    else ( cd "$repodir" && bash -lc "$cmd" ); return $?; fi
  fi

  if command -v "$first" >/dev/null 2>&1; then
    ( cd "$repodir" && eval "$cmd" )
    return $?
  fi

  if command -v zsh >/dev/null 2>&1; then
    ( cd "$repodir" && zsh -ic "$cmd" ) && return 0
    ( cd "$repodir" && zsh -lc "$cmd" ) && return 0
  fi

  return 127
}

# -------- Prune runner ---------------------------------------------------------
run_git_prune() {
  local repodir="$1"
  local cmd="$PRUNE_CMD"
  local branch="$2"

  if $DRY_RUN || $REPORT_ONLY; then
    log "DRY-RUN: ($repodir) ejecutaría prune-local (rama $branch)"
    return 0
  fi

  log "Auto-prune   : ejecutando $cmd (rama $branch)"
  ( cd "$repodir" && eval "$cmd" ) && log "Auto-prune OK" || log "WARN: prune-local falló"
}

# -------- Utilidad: ramas locales > 1 -----------------------------------------
has_multiple_local_branches() {
  local repodir="$1"
  local count
  count="$(cd "$repodir" && git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | wc -l | awk '{print $1+0}')"
  [ "${count:-0}" -gt 1 ]
}

# -------- Divergencia por rama (sin checkout) ---------------------------------
branch_needs_sync() {
  local b="$1"; local up a bh
  up="$(git rev-parse --abbrev-ref --symbolic-full-name "${b}@{u}" 2>/dev/null || true)"
  [[ -z "$up" ]] && return 1
  read bh a <<EOF
$(git rev-list --left-right --count "${up}...${b}" 2>/dev/null | awk '{print $1, $2}')
EOF
  [ "${a:-0}" -eq 0 ] && [ "${bh:-0}" -gt 0 ]
}

scan_other_branches_for_sync() {
  local repodir="$1"; local current="$2"; local b
  while IFS= read -r b; do
    [[ "$b" = "$current" ]] && continue
    if branch_needs_sync "$b"; then
      if $DRY_RUN || $REPORT_ONLY; then
        log "DRY-RUN: ($repodir) otra rama requiere sync: $b ⇒ $SYNC_CMD"
        return 0
      else
        log "Auto-sync    : otra rama requiere sync → $b ⇒ $SYNC_CMD"
        if run_git_sync "$repodir"; then
          log "Auto-sync OK : sincronizado por rama $b"
        else
          log "WARN         : $SYNC_CMD falló (otra rama $b)"
        fi
        return 0
      fi
    fi
  done <<EOF
$(cd "$repodir" && git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
EOF
  return 1
}

# -------- Proceso por ruta (repo raíz o módulo) --------------------------------
process_path() {
  local pdir="$1"; local repodir="$2"; local rc; local synced=1

  # Estado Git de la rama actual
  local st branch has_up pending_work pending_push ahead behind
  st="$(cd "$repodir" && git_state)"
  branch="$(printf "%s\n" "$st" | awk -F= '/^BRANCH=/{print $2}')"
  has_up="$(printf "%s\n" "$st" | awk -F= '/^HAS_UPSTREAM=/{print $2}')"
  pending_work="$(printf "%s\n" "$st" | awk -F= '/^PENDING_WORK=/{print $2}')"
  pending_push="$(printf "%s\n" "$st" | awk -F= '/^PENDING_PUSH=/{print $2}')"
  ahead="$(printf "%s\n" "$st" | awk -F= '/^AHEAD=/{print $2}')"
  behind="$(printf "%s\n" "$st" | awk -F= '/^BEHIND=/{print $2}')"

  log "Git state    : branch=$branch has_upstream=$has_up pending_work=$pending_work pending_push=$pending_push ahead=$ahead behind=$behind"

  # Auto-sync rama actual
  if [[ "$has_up" == "true" && "$pending_work" == "false" && "$pending_push" == "false" ]] \
     && { [[ "${ahead:-0}" -gt 0 ]] || [[ "${behind:-0}" -gt 0 ]]; }; then
    if $DRY_RUN || $REPORT_ONLY; then
      log "DRY-RUN: ($repodir) ejecutaría: $SYNC_CMD (rama actual $branch)"
      synced=0
    else
      log "Auto-sync    : rama actual requiere sync ($branch) ⇒ $SYNC_CMD"
      run_git_sync "$repodir" && log "Auto-sync OK : sincronizado (rama $branch)" || log "WARN: $SYNC_CMD falló"
      synced=0
    fi
  fi

  # Auto-sync otras ramas si no se sincronizó por la actual
  if [[ $synced -ne 0 && "$pending_work" == "false" ]]; then
    scan_other_branches_for_sync "$repodir" "$branch" || synced=$?
  fi

  # ---- Post-sync prune rules ----
  if [[ "$pending_work" == "false" ]]; then
    if [[ "$branch" == "main" ]]; then
      if has_multiple_local_branches "$repodir"; then
        run_git_prune "$repodir" "$branch"
      else
        log "Info         : solo hay una rama local; no se ejecuta prune-local"
      fi
    else
      # Último commit > 30 días? (sin validar número de ramas locales)
      local last_date now epoch_diff
      last_date="$(cd "$repodir" && git log -1 --format=%ct 2>/dev/null || echo 0)"
      now=$(date +%s)
      epoch_diff=$(( (now - last_date) / 86400 ))
      if [[ "${epoch_diff:-0}" -gt 30 ]]; then
        if $DRY_RUN || $REPORT_ONLY; then
          log "DRY-RUN: cambiaría a main y ejecutaría prune-local (último commit $epoch_diff días atrás)"
        else
          log "Auto-prune   : rama $branch inactiva ($epoch_diff días) ⇒ checkout main y prune-local"
          ( cd "$repodir" && git checkout main >/dev/null 2>&1 && eval "$PRUNE_CMD" ) || log "WARN: prune-local/checkout falló"
        fi
      fi
    fi
  fi
  # -----------------------------------------------------------

  # Filtros selectivos para ejecutar Maven
  if $ONLY_DIRTY && [[ "$pending_work" != "true" ]]; then
    SKIP=$((SKIP+1)); SKIP_LIST+=("$pdir (only-dirty y repo limpio)")
    return 0
  fi
  if $ONLY_UNPUSHED && [[ "$pending_push" != "true" ]]; then
    SKIP=$((SKIP+1)); SKIP_LIST+=("$pdir (only-unpushed y sin commits por subir)")
    return 0
  fi

  # Maven clean (solo si hay algo que limpiar)
  if clean_one_dir "$pdir"; then
    OK=$((OK+1)); OK_LIST+=("$pdir")
    $REPORT_ONLY && log "✅ Report OK (sin ejecutar clean)" || log "✅ Clean OK"
    rc=0
  else
    rc=$?
    if [[ $rc -eq 200 ]]; then
      SKIP=$((SKIP+1)); SKIP_LIST+=("$pdir (no mvn/mvnw)")
      log "⏭️  Skip (no mvn/mvnw)"
      rc=0
    else
      FAIL=$((FAIL+1)); FAIL_LIST+=("$pdir")
      log "❌ Clean FAIL (rc=$rc)"
    fi
  fi
  return $rc
}

# -------- Header ---------------------------------------------------------------
log "============================================================"
log "# Start — Maven clean with Git state report"
log "Base dir     : $BASE_DIR"
log "Dry run      : $DRY_RUN"
log "Deep         : $DEEP"
log "Report only  : $REPORT_ONLY"
log "Only dirty   : $ONLY_DIRTY"
log "Only unpushed: $ONLY_UNPUSHED"
log "Changed only : $CHANGED_ONLY"
log "Since (days) : $SINCE_DAYS"
log "Exclude pats : ${EXCLUDE_CSV:-<none>}"
log "Sync command : $SYNC_CMD"
log "Prune command: $PRUNE_CMD"
log "Log file     : $LOG_FILE"
log "============================================================"

TOTAL=0; OK=0; FAIL=0; SKIP=0
OK_LIST=(); FAIL_LIST=(); SKIP_LIST=()

SEEN_FILE="${TMPDIR:-/tmp}/mvn_clean_seen_${TS}.lst"
: > "$SEEN_FILE"

# -------- Descubrimiento de repos y módulos -----------------------------------
while IFS= read -r -d '' gitdir; do
  repo_dir="$(dirname "$gitdir")"

  if exclude_path "$repo_dir"; then
    SKIP=$((SKIP+1)); SKIP_LIST+=("$repo_dir (excluido)")
    continue
  fi

  if $CHANGED_ONLY && ! repo_is_active "$repo_dir"; then
    SKIP=$((SKIP+1)); SKIP_LIST+=("$repo_dir (sin cambios/commits recientes)")
    continue
  fi

  if [[ -f "$repo_dir/pom.xml" && "$DEEP" = false ]]; then
    TOTAL=$((TOTAL+1))
    log "------------------------------------------------------------"
    log "Repo (root pom): $repo_dir"
    process_path "$repo_dir" "$repo_dir" || true
    continue
  fi

  found_any=false
  while IFS= read -r -d '' pom; do
    found_any=true
    module_dir="$(dirname "$pom")"
    if grep -Fxq "$module_dir" "$SEEN_FILE" 2>/dev/null; then continue; fi
    echo "$module_dir" >> "$SEEN_FILE" 2>/dev/null || true
    TOTAL=$((TOTAL+1))
    log "------------------------------------------------------------"
    log "Repo (module): $repo_dir"
    log "Module dir   : $module_dir"
    process_path "$module_dir" "$repo_dir" || true
  done < <(
    find "$repo_dir" -type f -name "pom.xml" \
      -not -path "$repo_dir/.git/*" \
      -not -path "*/target/*" \
      -not -path "*/build/*" \
      -not -path "*/.idea/*" \
      -not -path "*/.vscode/*" \
      -not -path "*/node_modules/*" \
      -print0 2>/dev/null || true
  )

  if [[ "$found_any" = false ]]; then
    SKIP=$((SKIP+1))
    SKIP_LIST+=("$repo_dir (sin pom.xml)")
    log "⏭️  Skip: $repo_dir — no se hallaron pom.xml"
  fi
done < <(find "$BASE_DIR" -type d -name ".git" -print0 2>/dev/null || true)

# -------- Summary --------------------------------------------------------------
log "============================================================"
log "# Summary"
log "Total discovered : $TOTAL"
log "Success          : $OK"
log "Failed           : $FAIL"
log "Skipped          : $SKIP"

if (( OK > 0 )); then
  log "OK:"
  for p in "${OK_LIST[@]}"; do log "  - $p"; done
fi
if (( FAIL > 0 )); then
  log "FAIL:"
  for p in "${FAIL_LIST[@]}"; do log "  - $p"; done
fi
if (( SKIP > 0 )); then
  log "SKIP:"
  for p in "${SKIP_LIST[@]}"; do log "  - $p"; done
fi

log "============================================================"
log "# End"
log "============================================================"

(( FAIL > 0 )) && exit 1 || exit 0
