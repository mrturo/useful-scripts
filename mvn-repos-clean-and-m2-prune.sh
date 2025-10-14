#!/usr/bin/env bash
# PURPOSE
#   Traverse Git repositories under multiple BASE_DIRS, report Git status, optionally auto-sync/prune,
#   and (only for Maven modules) run a smart mvn clean and audit which dependencies are USED
#   versus what exists in the local Maven repository (~/.m2 by default).
#   Audit modes:
#   • Default (--audit-m2): Consolidates ALL dependencies and writes CSVs to first BASE_DIR
#   • Separate (--separate-audits): Creates individual CSVs per BASE_DIR, disables M2 purge
#   Additionally, provides smart cleanup for Node.js projects (package.json detected).
#
# KEY FEATURES
#   • Single pass: while discovering Maven modules, we both clean (if needed) and collect used deps.
#   • Smart clean: skip mvn clean when no target/ contents are present (root/submodules).
#   • Node.js support: detects and cleans node_modules, build outputs (dist, build, .next, etc.), 
#     TypeScript output directories, and package manager caches (npm/yarn/pnpm).
#   • Git hygiene for ALL repos: auto-sync on diverged branches and conditional local-branch pruning
#     for Maven, Node.js, and other project types.
#   • Dependency audit (optional):
#       - Collects used GAVs via maven-dependency-plugin:list per scope (one scope at a time),
#         with a fallback to dependency:tree when list yields nothing (common in corporate builds).
#       - Produces BASE_DIR/used_deps.csv and BASE_DIR/unused_deps.csv.
#       - Optionally deletes (purges) unused GAV directories from M2_REPO.
#   • macOS/BSD-safe: sed/awk usage is compatible with the default macOS toolchain.
#   • Post-purge random verification in N Maven modules (mvn -U -DskipTests verify).
#
# USAGE
#   ./mvn-repos-clean-and-m2-prune.sh [BASE_DIR1] [BASE_DIR2] [...] [flags...]
#   
#   Examples:
#     ./mvn-repos-clean-and-m2-prune.sh /path/to/repos --dry-run
#     ./mvn-repos-clean-and-m2-prune.sh ~/projects ~/work/repos --audit-m2 --deep
#     ./mvn-repos-clean-and-m2-prune.sh --report-only  # uses current directory
#
# IMPORTANT FLAGS
#   --dry-run              Do not perform clean or purge; print what would happen.
#   --report-only          Only report Git and discovery; do not run mvn or delete anything.
#   --deep                 Scan all pom.xml files under each repo (not just the root pom).
#   --exclude "pat1,pat2"  Exclude paths containing any of the comma-separated patterns.
#   --changed-only         Process only repos with uncommitted work or commits in the last --since days.
#   --since N              Days threshold for --changed-only (default 30).
#   --only-dirty           For Maven steps, only process repos with pending work.
#   --only-unpushed        For Maven steps, only process repos with commits not pushed.
#   --sync-cmd "CMD"       Shell command used for auto-sync (default: git-pull-all helper).
#   --prune-cmd "CMD"      Shell command used for prune (default: prune-local helper).
#   --audit-m2             Enable dependency audit (writes CSVs and purges M2).
#   --separate-audits      Generate separate CSV files per BASE_DIR (implies --audit-m2).
#   --m2 DIR               Local Maven repo (default: ~/.m2/repository).
#   --scopes "a,b,c"       Scopes to consider for USED deps (default: compile,runtime,test).
#   --post-verify          (Default when --audit-m2) After purge, verify N random Maven modules.
#   --no-post-verify       Disable post-purge random verification.
#   --verify-count N       How many Maven modules to verify randomly (default 2).
#   --clean-global-caches  Clean npm/yarn/pnpm global caches (WARNING: slow next installs).
#
# WARNING: --clean-global-caches risks:
#   • All package managers will re-download everything from registries
#   • First installs after cleanup will be 5-10x slower until cache rebuilds
#   • May fail if packages were unpublished or network connectivity issues
#   • Affects ALL projects on this machine, not just current repositories
#   • Cannot be easily reversed - cache must be rebuilt through usage
#
# EXIT CODE
#   0 on success; 1 if any mvn clean step failed (CSV generation/purge may still succeed).

set -euo pipefail

# -------- Args / Flags ---------------------------------------------------------
# Collect all non-flag arguments as BASE_DIRS
BASE_DIRS=()
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

# M2 Audit
AUDIT_M2=false
SEPARATE_AUDITS=false
M2_REPO="${HOME}/.m2/repository"
DEP_SCOPES="compile,runtime,test"   # compile|runtime|test|provided|system

# Global cache cleanup (new)
CLEAN_GLOBAL_CACHES=false

# Post-purge verification (new)
POST_VERIFY_SET=false      # will be set true automatically when --audit-m2 unless explicitly disabled
VERIFY_COUNT=2

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
    --audit-m2)       AUDIT_M2=true ;;
    --separate-audits) SEPARATE_AUDITS=true ;;
    --m2)             M2_REPO="${2:-"$M2_REPO"}"; shift ;;
    --scopes)         DEP_SCOPES="${2:-"$DEP_SCOPES"}"; shift ;;
    --clean-global-caches) CLEAN_GLOBAL_CACHES=true ;;
    --post-verify)    POST_VERIFY_SET=true ;;
    --no-post-verify) POST_VERIFY_SET=false ;;
    --verify-count)   VERIFY_COUNT="${2:-2}"; shift ;;
    --*) 
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
    *) 
      # Non-flag arguments are treated as BASE_DIRS
      BASE_DIRS+=("$1")
      ;;
  esac
  shift || true
done

# If no directories specified, use current directory
if [[ ${#BASE_DIRS[@]} -eq 0 ]]; then
  BASE_DIRS=(".")
fi

# If separate audits requested, enable audit-m2 automatically
if [[ "$SEPARATE_AUDITS" == true ]]; then
  AUDIT_M2=true
fi

# If audit requested and user didn't explicitly disable, enable post-verify by default
if [[ "$AUDIT_M2" == true && "$POST_VERIFY_SET" == false ]]; then
  POST_VERIFY_SET=true
fi

# Normalize BASE_DIRS to absolute paths and select CSV output directory
NORMALIZED_BASE_DIRS=()
for dir in "${BASE_DIRS[@]}"; do
  if [[ -d "$dir" ]]; then
    NORMALIZED_BASE_DIRS+=("$(cd "$dir" && pwd)")
  else
    echo "Warning: Directory does not exist: $dir" >&2
    NORMALIZED_BASE_DIRS+=("$dir")  # Keep original for error reporting
  fi
done

# Use first directory for CSV output (M2 audit results)
BASE_DIR="${NORMALIZED_BASE_DIRS[0]}"

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

# -------- Git state detection (KEY=VALUE) -------------------------------------
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

# -------- Is there anything to clean? -----------------------------------------
needs_clean() {
  local p="$1"

  if [[ -d "$p/target" ]]; then
    if find "$p/target" -mindepth 1 -not -name ".gitignore" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  fi

  local t
  while IFS= read -r -d '' t; do
    if find "$t" -mindepth 1 -not -name ".gitignore" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done < <(find "$p" -type d -name target -not -path "$p/.git/*" -print0 2>/dev/null || true)

  return 1
}

# -------- Node.js project detection and cleaning ---------------------------
is_nodejs_project() {
  local pdir="$1"
  [[ -f "$pdir/package.json" ]] || [[ -f "$pdir/yarn.lock" ]] || [[ -f "$pdir/pnpm-lock.yaml" ]] || [[ -f "$pdir/package-lock.json" ]]
}

resolve_nodejs_runner() {
  local pdir="$1"
  if [[ -f "$pdir/package.json" ]]; then
    if [[ -f "$pdir/yarn.lock" ]]; then
      if command -v yarn >/dev/null 2>&1; then printf 'yarn\n'; return 0; fi
    elif [[ -f "$pdir/pnpm-lock.yaml" ]]; then
      if command -v pnpm >/dev/null 2>&1; then printf 'pnpm\n'; return 0; fi
    elif [[ -f "$pdir/package-lock.json" ]]; then
      if command -v npm >/dev/null 2>&1; then printf 'npm\n'; return 0; fi
    fi
    # Fallback to npm if available
    if command -v npm >/dev/null 2>&1; then printf 'npm\n'; return 0; fi
  fi
  return 1
}

needs_nodejs_clean() {
  local pdir="$1"
  
  # Check for node_modules
  if [[ -d "$pdir/node_modules" ]]; then
    if find "$pdir/node_modules" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  fi
  
  # Check for common build outputs
  local build_dirs=("dist" "build" ".next" ".nuxt" ".output" "coverage" ".nyc_output")
  for dir in "${build_dirs[@]}"; do
    if [[ -d "$pdir/$dir" ]]; then
      if find "$pdir/$dir" -mindepth 1 -not -name ".gitignore" -print -quit 2>/dev/null | grep -q .; then
        return 0
      fi
    fi
  done
  
  # Check for TypeScript output
  if [[ -f "$pdir/tsconfig.json" ]]; then
    local outdir
    outdir=$(grep -o '"outDir"[[:space:]]*:[[:space:]]*"[^"]*"' "$pdir/tsconfig.json" 2>/dev/null | sed 's/.*"outDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if [[ -n "$outdir" && -d "$pdir/$outdir" ]]; then
      if find "$pdir/$outdir" -mindepth 1 -not -name ".gitignore" -print -quit 2>/dev/null | grep -q .; then
        return 0
      fi
    fi
  fi
  
  return 1
}

clean_nodejs_project() {
  local pdir="$1"
  local runner=""
  local cleaned_items=()
  
  if ! is_nodejs_project "$pdir"; then
    log "SKIP: $pdir - not a Node.js project"
    return 200
  fi

  if ! needs_nodejs_clean "$pdir"; then
    if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
      log "DRY-RUN: ($pdir) nothing to clean → skip Node.js clean"
    else
      log "Info         : ($pdir) nothing to clean → skip Node.js clean"
    fi
    return 0
  fi

  if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
    log "DRY-RUN: ($pdir) would clean Node.js artifacts"
    return 0
  fi

  # Clean node_modules
  if [[ -d "$pdir/node_modules" ]]; then
    rm -rf "$pdir/node_modules" && cleaned_items+=("node_modules")
  fi
  
  # Clean common build directories
  local build_dirs=("dist" "build" ".next" ".nuxt" ".output" "coverage" ".nyc_output")
  for dir in "${build_dirs[@]}"; do
    if [[ -d "$pdir/$dir" ]]; then
      rm -rf "$pdir/$dir" && cleaned_items+=("$dir")
    fi
  done
  
  # Clean TypeScript output directory if specified in tsconfig.json
  if [[ -f "$pdir/tsconfig.json" ]]; then
    local outdir
    outdir=$(grep -o '"outDir"[[:space:]]*:[[:space:]]*"[^"]*"' "$pdir/tsconfig.json" 2>/dev/null | sed 's/.*"outDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if [[ -n "$outdir" && -d "$pdir/$outdir" ]]; then
      rm -rf "$pdir/$outdir" && cleaned_items+=("$outdir (TS output)")
    fi
  fi
  
  # Clean package manager caches per project (unless global cleanup is enabled)
  if [[ "$CLEAN_GLOBAL_CACHES" != true ]]; then
    if runner="$(resolve_nodejs_runner "$pdir")"; then
      case "$runner" in
        npm)
          ( cd "$pdir" && npm cache clean --force >/dev/null 2>&1 ) && cleaned_items+=("npm cache")
          ;;
        yarn)
          ( cd "$pdir" && yarn cache clean >/dev/null 2>&1 ) && cleaned_items+=("yarn cache")
          ;;
        pnpm)
          ( cd "$pdir" && pnpm store prune >/dev/null 2>&1 ) && cleaned_items+=("pnpm store")
          ;;
      esac
    fi
  fi
  
  if [ ${#cleaned_items[@]} -gt 0 ]; then
    log "Node.js clean: cleaned ${cleaned_items[*]}"
  fi
  
  return 0
}

# -------- Global cache cleanup (new) ------------------------------------------
clean_global_caches() {
  if [[ "$CLEAN_GLOBAL_CACHES" != true ]]; then
    return 0
  fi

  log "============================================================"
  log "# Global Cache Cleanup - WARNING: This will slow down next installs"
  log "============================================================"

  if [[ "$DRY_RUN" == true || "$REPORT_ONLY" == true ]]; then
    log "DRY-RUN: would clean global package manager caches"
    return 0
  fi

  local cleaned_caches=()
  local cache_sizes_before=""
  local cache_sizes_after=""

  # Collect cache sizes before cleanup (for reporting)
  if command -v npm >/dev/null 2>&1; then
    cache_sizes_before="$cache_sizes_before npm:$(npm cache verify 2>/dev/null | grep 'Cache size:' | awk '{print $3$4}' || echo 'unknown')"
  fi
  if command -v yarn >/dev/null 2>&1; then
    local yarn_cache_dir
    yarn_cache_dir="$(yarn cache dir 2>/dev/null || echo '')"
    if [[ -n "$yarn_cache_dir" && -d "$yarn_cache_dir" ]]; then
      cache_sizes_before="$cache_sizes_before yarn:$(du -sh "$yarn_cache_dir" 2>/dev/null | awk '{print $1}' || echo 'unknown')"
    fi
  fi

  # Clean npm cache
  if command -v npm >/dev/null 2>&1; then
    log "Global cache : cleaning npm cache..."
    if npm cache clean --force >/dev/null 2>&1; then
      cleaned_caches+=("npm")
      log "Global cache : ✅ npm cache cleaned"
    else
      log "Global cache : ⚠️  npm cache clean failed"
    fi
  else
    log "Global cache : npm not available"
  fi

  # Clean yarn cache
  if command -v yarn >/dev/null 2>&1; then
    log "Global cache : cleaning yarn cache..."
    if yarn cache clean --all >/dev/null 2>&1; then
      cleaned_caches+=("yarn")
      log "Global cache : ✅ yarn cache cleaned"
    else
      log "Global cache : ⚠️  yarn cache clean failed"
    fi
  else
    log "Global cache : yarn not available"
  fi

  # Clean pnpm store
  if command -v pnpm >/dev/null 2>&1; then
    log "Global cache : cleaning pnpm store..."
    if pnpm store prune >/dev/null 2>&1; then
      cleaned_caches+=("pnpm")
      log "Global cache : ✅ pnpm store cleaned"
    else
      log "Global cache : ⚠️  pnpm store clean failed"
    fi
  else
    log "Global cache : pnpm not available"
  fi

  # Report results
  if [[ ${#cleaned_caches[@]} -gt 0 ]]; then
    log "Global cache : cleaned ${cleaned_caches[*]} caches"
    log "Global cache : ⚠️  NOTICE: Next npm/yarn/pnpm installs will be slower"
    log "Global cache : ⚠️  NOTICE: All packages will be re-downloaded from registry"
  else
    log "Global cache : no caches were cleaned"
  fi

  # Optional: Report outdated global packages (informational only)
  if command -v npm >/dev/null 2>&1; then
    log "Global cache : checking for outdated global npm packages..."
    local outdated_globals=0
    # Use timeout to avoid hanging on slow npm outdated command
    local temp_file="${TMPDIR:-/tmp}/npm_outdated_$$"
    if timeout 10 npm outdated -g --depth=0 >"$temp_file" 2>/dev/null; then
      outdated_globals=$(tail -n +2 "$temp_file" 2>/dev/null | wc -l 2>/dev/null | awk '{print $1+0}' 2>/dev/null || echo '0')
    fi
    rm -f "$temp_file"
    
    if [[ "${outdated_globals:-0}" -gt 0 ]]; then
      log "Global cache : ℹ️  Found $outdated_globals outdated global npm packages"
      log "Global cache : ℹ️  Run 'npm outdated -g' to see details"
      log "Global cache : ℹ️  Run 'npm update -g' to update them"
    else
      log "Global cache : ℹ️  No outdated global npm packages found"
    fi
  else
    log "Global cache : npm not available for global package check"
  fi

  log "============================================================"
  return 0
}

# -------- Resolve Maven runner -------------------------------------------------
resolve_maven_runner() {
  local pdir="$1"
  if [[ -x "$pdir/mvnw" ]]; then
    printf '%s\n' "$pdir/mvnw"; return 0
  elif command -v mvn >/dev/null 2>&1; then
    printf '%s\n' "mvn"; return 0
  fi
  return 1
}

# -------- Maven runner (clean) -------------------------------------------------
clean_one_dir() {
  local pdir="$1"
  local runner=""
  if runner="$(resolve_maven_runner "$pdir")"; then :; else
    log "SKIP: $pdir - no mvnw or mvn in PATH"
    return 200
  fi

  if ! needs_clean "$pdir"; then
    if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
      log "DRY-RUN: ($pdir) nothing to clean → skip mvn clean"
    else
      log "Info         : ($pdir) nothing to clean → skip mvn clean"
    fi
    return 0
  fi

  if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
    log "DRY-RUN: ($pdir) would execute: $runner clean"
    return 0
  fi

  ( cd "$pdir" && "$runner" -q clean ) && return 0 || return $?
}

# -------- Robust sync runner (PATH or zsh -ic/-lc) ----------------------------
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
    ( cd "$repodir" && eval "$cmd" ); return $?
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

  if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
    log "DRY-RUN: ($repodir) would execute prune-local (branch $branch)"
    return 0
  fi

  log "Auto-prune   : executing $cmd (branch $branch)"
  ( cd "$repodir" && eval "$cmd" ) && log "Auto-prune OK" || log "WARN: prune-local failed"
}

# -------- Utility: local branches > 1 -----------------------------------------
has_multiple_local_branches() {
  local repodir="$1"
  local count
  count="$(cd "$repodir" && git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | wc -l | awk '{print $1+0}')"
  [ "${count:-0}" -gt 1 ]
}

# -------- Branch divergence (without checkout) --------------------------------
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
      if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
        log "DRY-RUN: ($repodir) other branch requires sync: $b ⇒ $SYNC_CMD"
        return 0
      else
        log "Auto-sync    : other branch requires sync → $b ⇒ $SYNC_CMD"
        if run_git_sync "$repodir"; then
          log "Auto-sync OK : synced for branch $b"
        else
          log "WARN         : $SYNC_CMD failed (other branch $b)"
        fi
        return 0
      fi
    fi
  done <<EOF
$(cd "$repodir" && git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
EOF
  return 1
}

# -------- Git-only processing for non-Maven repos -----------------------------
process_repo_git_only() {
  local repodir="$1"

  local st branch has_up pending_work pending_push ahead behind
  st="$(cd "$repodir" && git_state)"
  branch="$(printf "%s\n" "$st" | awk -F= '/^BRANCH=/{print $2}')"
  has_up="$(printf "%s\n" "$st" | awk -F= '/^HAS_UPSTREAM=/{print $2}')"
  pending_work="$(printf "%s\n" "$st" | awk -F= '/^PENDING_WORK=/{print $2}')"
  pending_push="$(printf "%s\n" "$st" | awk -F= '/^PENDING_PUSH=/{print $2}')"
  ahead="$(printf "%s\n" "$st" | awk -F= '/^AHEAD=/{print $2}')"
  behind="$(printf "%s\n" "$st" | awk -F= '/^BEHIND=/{print $2}')"

  log "Git state    : branch=$branch has_upstream=$has_up pending_work=$pending_work pending_push=$pending_push ahead=$ahead behind=$behind"

  # Auto-sync current branch
  local synced=1
  if [[ "$has_up" == "true" && "$pending_work" == "false" && "$pending_push" == "false" ]] \
     && { [[ "${ahead:-0}" -gt 0 ]] || [[ "${behind:-0}" -gt 0 ]]; }; then
    if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
      log "DRY-RUN: ($repodir) would execute: $SYNC_CMD (current branch $branch)"
      synced=0
    else
      log "Auto-sync    : current branch requires sync ($branch) ⇒ $SYNC_CMD"
      run_git_sync "$repodir" && log "Auto-sync OK : synced (branch $branch)" || log "WARN: $SYNC_CMD failed"
      synced=0
    fi
  fi

  # Auto-sync other branches if not synced by the current one
  if [[ $synced -ne 0 && "$pending_work" == "false" ]]; then
    scan_other_branches_for_sync "$repodir" "$branch" || true
  fi

  # Post-sync prune rules (git-only)
  if [[ "$pending_work" == "false" ]]; then
    if [[ "$branch" == "main" ]]; then
      if has_multiple_local_branches "$repodir"; then
        run_git_prune "$repodir" "$branch"
      else
        log "Info         : only one local branch; prune-local not executed"
      fi
    else
      local last_date now epoch_diff
      last_date="$(cd "$repodir" && git log -1 --format=%ct 2>/dev/null || echo 0)"
      now=$(date +%s)
      epoch_diff=$(( (now - last_date) / 86400 ))
      if [[ "${epoch_diff:-0}" -gt 30 ]]; then
        if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
          log "DRY-RUN: would switch to main and execute prune-local (last commit $epoch_diff days ago)"
        else
          log "Auto-prune   : branch $branch inactive ($epoch_diff days) ⇒ checkout main and prune-local"
          ( cd "$repodir" && git checkout main >/dev/null 2>&1 && eval "$PRUNE_CMD" ) || log "WARN: prune-local/checkout failed"
        fi
      fi
    fi
  fi

  # Node.js project cleanup (if applicable)
  if is_nodejs_project "$repodir"; then
    # Apply same conditional logic as Maven projects for consistency
    if [ "$ONLY_DIRTY" = true ] && [[ "$pending_work" != "true" ]]; then
      log "Node.js skip : only-dirty mode and clean repo"
    elif [ "$ONLY_UNPUSHED" = true ] && [[ "$pending_push" != "true" ]]; then
      log "Node.js skip : only-unpushed mode and no commits to push"
    else
      if clean_nodejs_project "$repodir"; then
        log "Info         : ✅ Node.js Clean OK"
      else
        local rc=$?
        if [[ $rc -eq 200 ]]; then
          log "Info         : ⏭️  Node.js Skip (not a Node.js project)"
        else
          log "Info         : ❌ Node.js Clean FAIL (rc=$rc)"
        fi
      fi
    fi
  fi
}

# -------- M2 audit variables (accumulate during traversal) --------------------
TMP_DEP_OUT="${TMPDIR:-/tmp}/mvn_dep_list_${TS}.txt"
: > "$TMP_DEP_OUT"

# For separate audits: track dependencies per BASE_DIR using files
BASE_DIR_DEPS_MAP="${TMPDIR:-/tmp}/base_dir_deps_map_${TS}.txt"
: > "$BASE_DIR_DEPS_MAP"

# Helper functions for BASE_DIR tracking (bash 3.x compatible)
get_base_dir_deps_file() {
  local base_dir="$1"
  grep "^${base_dir}|" "$BASE_DIR_DEPS_MAP" 2>/dev/null | cut -d'|' -f2
}

set_base_dir_deps_file() {
  local base_dir="$1"
  local deps_file="$2"
  # Remove existing entry and add new one
  grep -v "^${base_dir}|" "$BASE_DIR_DEPS_MAP" > "${BASE_DIR_DEPS_MAP}.tmp" 2>/dev/null || true
  echo "${base_dir}|${deps_file}" >> "${BASE_DIR_DEPS_MAP}.tmp"
  mv "${BASE_DIR_DEPS_MAP}.tmp" "$BASE_DIR_DEPS_MAP"
}

# Track discovered Maven modules (for post-verify random pick)
declare -a MAVEN_MODULES
MAVEN_MODULES=()

# --- Normalizer dependency:list → GAV (group:artifact:version) ----------------
normalize_dep_lines() {
  sed -E \
    -e 's/^[[:space:]]*\[(INFO|WARNING|ERROR)\][[:space:]]*//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
  | awk -F':' '
      function tokok(t){ return (t ~ /^[A-Za-z0-9_.-]+$/) }
      NF==5 { g=$1; a=$2; v=$4; if (tokok(g)&&tokok(a)&&tokok(v)) print g ":" a ":" v; next }
      NF>5 { g=$(NF-4); a=$(NF-3); v=$(NF-1); if (tokok(g)&&tokok(a)&&tokok(v)) print g ":" a ":" v; }
    ' \
  | grep -E '^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$'
}

# --- Normalizer dependency:tree (fallback) → GAV ------------------------------
normalize_tree_lines() {
  sed -E \
    -e 's/^[[:space:]]*\[(INFO|WARNING|ERROR)\][[:space:]]*//' \
    -e 's/^[[:space:]]*[|\\+ -]+//' \
    -e 's/[[:space:]]*\(.+\)//' \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
  | awk -F':' 'NF>=3 { print $1 ":" $2 ":" $3 }' \
  | grep -E '^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$'
}

# --- Collect used deps per module --------------------------------------------
collect_module_deps() {
  local pdir="$1"
  local base_dir_origin="${2:-}"
  local runner=""

  if [ "$AUDIT_M2" != true ]; then
    return 0
  fi
  if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
    log "Deps used    : (DRY/REPORT) skip in $pdir"
    return 0
  fi
  if ! runner="$(resolve_maven_runner "$pdir")"; then
    log "Deps used    : 0 in $pdir (no mvn/mvnw)"
    return 0
  fi

  local raw_scopes="$DEP_SCOPES"
  local scopes_arr
  IFS=',' read -r -a scopes_arr <<< "${raw_scopes}"

  local tmp_mod="${TMPDIR:-/tmp}/_deps_module.$$"
  : > "$tmp_mod"

  (
    cd "$pdir"
    for s in "${scopes_arr[@]}"; do
      s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      case "$s" in
        compile|runtime|test|provided|system)
          if ! "$runner" -q -B \
              org.apache.maven.plugins:maven-dependency-plugin:3.6.1:list \
              -DincludeScope="$s" \
              -DexcludeTypes=pom \
              -DexcludeClassifiers=tests \
              -DoutputAbsoluteArtifactFilename=false \
              -DoutputFile=/dev/stdout 2>/dev/null \
            | normalize_dep_lines >> "$tmp_mod"; then :; fi
          ;;
        "" )
          if ! "$runner" -q -B \
              org.apache.maven.plugins:maven-dependency-plugin:3.6.1:list \
              -DexcludeTypes=pom \
              -DexcludeClassifiers=tests \
              -DoutputAbsoluteArtifactFilename=false \
              -DoutputFile=/dev/stdout 2>/dev/null \
            | normalize_dep_lines >> "$tmp_mod"; then :; fi
          ;;
        * )
          log "WARN         : invalid scope ignored: $s"
          ;;
      esac
    done

    # Fallback: if empty, use dependency:tree per scope
    if [[ ! -s "$tmp_mod" ]]; then
      for s in "${scopes_arr[@]}"; do
        s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        case "$s" in
          compile|runtime|test|provided|system)
            if ! "$runner" -q -B \
                org.apache.maven.plugins:maven-dependency-plugin:3.6.1:tree \
                -Dscope="$s" \
                -DoutputType=text \
                -DoutputFile=/dev/stdout 2>/dev/null \
              | normalize_tree_lines >> "$tmp_mod"; then :; fi
            ;;
        esac
      done
    fi
  )

  local c=0
  if [[ -s "$tmp_mod" ]]; then
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$tmp_mod" \
      | grep -v -E '^[[:space:]]*$' \
      | sort -u -o "$tmp_mod"
    c=$(awk 'END{print NR+0}' "$tmp_mod")
    cat "$tmp_mod" >> "$TMP_DEP_OUT"
    
    # For separate audits, also track by BASE_DIR
    if [[ "$SEPARATE_AUDITS" == true && -n "$base_dir_origin" ]]; then
      local deps_file
      deps_file="$(get_base_dir_deps_file "$base_dir_origin")"
      if [[ -z "$deps_file" ]]; then
        deps_file="${TMPDIR:-/tmp}/deps_$(echo "$base_dir_origin" | sed 's|/|_|g')_${TS}.txt"
        set_base_dir_deps_file "$base_dir_origin" "$deps_file"
        : > "$deps_file"
      fi
      cat "$tmp_mod" >> "$deps_file"
    fi
  fi
  rm -f "$tmp_mod"
  log "Deps used    : $c in $pdir"
}

# -------- Process by path (root repo or module) -------------------------------
process_path() {
  local pdir="$1"; local repodir="$2"; local basedir_origin="${3:-}"; local rc; local synced=1

  # Record Maven module for potential post-verify
  if [[ -f "$pdir/pom.xml" ]]; then
    MAVEN_MODULES+=("$pdir")
  fi

  # Git state
  local st branch has_up pending_work pending_push ahead behind
  st="$(cd "$repodir" && git_state)"
  branch="$(printf "%s\n" "$st" | awk -F= '/^BRANCH=/{print $2}')"
  has_up="$(printf "%s\n" "$st" | awk -F= '/^HAS_UPSTREAM=/{print $2}')"
  pending_work="$(printf "%s\n" "$st" | awk -F= '/^PENDING_WORK=/{print $2}')"
  pending_push="$(printf "%s\n" "$st" | awk -F= '/^PENDING_PUSH=/{print $2}')"
  ahead="$(printf "%s\n" "$st" | awk -F= '/^AHEAD=/{print $2}')"
  behind="$(printf "%s\n" "$st" | awk -F= '/^BEHIND=/{print $2}')"

  log "Git state    : branch=$branch has_upstream=$has_up pending_work=$pending_work pending_push=$pending_push ahead=$ahead behind=$behind"

  # Auto-sync current branch
  if [[ "$has_up" == "true" && "$pending_work" == "false" && "$pending_push" == "false" ]] \
     && { [[ "${ahead:-0}" -gt 0 ]] || [[ "${behind:-0}" -gt 0 ]]; }; then
    if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
      log "DRY-RUN: ($repodir) would execute: $SYNC_CMD (current branch $branch)"
      synced=0
    else
      log "Auto-sync    : current branch requires sync ($branch) ⇒ $SYNC_CMD"
      run_git_sync "$repodir" && log "Auto-sync OK : synced (branch $branch)" || log "WARN: $SYNC_CMD failed"
      synced=0
    fi
  fi

  # Auto-sync other branches if not synced by current one
  if [[ $synced -ne 0 && "$pending_work" == "false" ]]; then
    scan_other_branches_for_sync "$repodir" "$branch" || synced=$?
  fi

  # Post-sync prune rules
  if [[ "$pending_work" == "false" ]]; then
    if [[ "$branch" == "main" ]]; then
      if has_multiple_local_branches "$repodir"; then
        run_git_prune "$repodir" "$branch"
      else
        log "Info         : only one local branch; prune-local not executed"
      fi
    else
      local last_date now epoch_diff
      last_date="$(cd "$repodir" && git log -1 --format=%ct 2>/dev/null || echo 0)"
      now=$(date +%s)
      epoch_diff=$(( (now - last_date) / 86400 ))
      if [[ "${epoch_diff:-0}" -gt 30 ]]; then
        if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
          log "DRY-RUN: would switch to main and execute prune-local (last commit $epoch_diff days ago)"
        else
          log "Auto-prune   : branch $branch inactive ($epoch_diff days) ⇒ checkout main and prune-local"
          ( cd "$repodir" && git checkout main >/dev/null 2>&1 && eval "$PRUNE_CMD" ) || log "WARN: prune-local/checkout failed"
        fi
      fi
    fi
  fi

  # Conditional Maven steps
  if [ "$ONLY_DIRTY" = true ] && [[ "$pending_work" != "true" ]]; then
    SKIP=$((SKIP+1)); SKIP_LIST+=("$pdir (only-dirty and clean repo)")
    collect_module_deps "$pdir" "$basedir_origin"
    return 0
  fi
  if [ "$ONLY_UNPUSHED" = true ] && [[ "$pending_push" != "true" ]]; then
    SKIP=$((SKIP+1)); SKIP_LIST+=("$pdir (only-unpushed and no commits to push)")
    collect_module_deps "$pdir" "$basedir_origin"
    return 0
  fi

  # Maven clean (only if needed)
  if clean_one_dir "$pdir"; then
    OK=$((OK+1)); OK_LIST+=("$pdir")
    if [ "$REPORT_ONLY" = true ]; then
      log "Info         : ✅ Report OK (no clean executed)"
    else
      log "Info         : ✅ Clean OK"
    fi
    rc=0
  else
    rc=$?
    if [[ $rc -eq 200 ]]; then
      SKIP=$((SKIP+1)); SKIP_LIST+=("$pdir (no mvn/mvnw)")
      log "Info         : ⏭️  Skip (no mvn/mvnw)"
      rc=0
    else
      FAIL=$((FAIL+1)); FAIL_LIST+=("$pdir")
      log "Info         : ❌ Clean FAIL (rc=$rc)"
    fi
  fi

  # Dependency capture (same pass)
  collect_module_deps "$pdir" "$basedir_origin"

  return $rc
}

# -------- Header ---------------------------------------------------------------
log "============================================================"
log "# Start - Git hygiene + smart Maven/Node.js clean + inline M2 audit"
if [[ ${#NORMALIZED_BASE_DIRS[@]} -eq 1 ]]; then
  log "Base dir     : ${NORMALIZED_BASE_DIRS[0]}"
else
  log "Base dirs    : ${#NORMALIZED_BASE_DIRS[@]} directories"
  for i in "${!NORMALIZED_BASE_DIRS[@]}"; do
    log "  [$((i+1))]       : ${NORMALIZED_BASE_DIRS[i]}"
  done
fi
log "CSV output   : $BASE_DIR"
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
log "Audit M2     : $AUDIT_M2"
if [ "$AUDIT_M2" = true ]; then
  log "Separate audits: $SEPARATE_AUDITS"
  log "M2 repo      : $M2_REPO"
  log "Scopes       : $DEP_SCOPES"
fi
log "Global caches: $CLEAN_GLOBAL_CACHES"
log "Post-verify  : $POST_VERIFY_SET (count=$VERIFY_COUNT)"
log "Log file     : $LOG_FILE"
log "============================================================"

TOTAL=0; OK=0; FAIL=0; SKIP=0
OK_LIST=(); FAIL_LIST=(); SKIP_LIST=()

SEEN_FILE="${TMPDIR:-/tmp}/mvn_clean_seen_${TS}.lst"
: > "$SEEN_FILE"

# -------- Repository and module discovery (two-pass with progress) ------------
PLAN_FILE="${TMPDIR:-/tmp}/mvn_clean_plan_${TS}.lst"
: > "$PLAN_FILE"

# PASS 1: Build the plan
for current_base_dir in "${NORMALIZED_BASE_DIRS[@]}"; do
  if [[ ! -d "$current_base_dir" ]]; then
    log "WARN         : Base directory does not exist: $current_base_dir"
    continue
  fi
  
  log "Scanning     : $current_base_dir"
  
  while IFS= read -r -d '' gitdir; do
    repo_dir="$(dirname "$gitdir")"

    if exclude_path "$repo_dir"; then
      SKIP=$((SKIP+1)); SKIP_LIST+=("$repo_dir (excluded)")
      continue
    fi

    if [ "$CHANGED_ONLY" = true ] && ! repo_is_active "$repo_dir"; then
      SKIP=$((SKIP+1)); SKIP_LIST+=("$repo_dir (no recent changes/commits)")
      continue
    fi

    # If repo has a root pom and --deep=false, treat as single module
    if [[ -f "$repo_dir/pom.xml" && "$DEEP" = false ]]; then
      printf 'M|%s|%s|%s\n' "$repo_dir" "$repo_dir" "$current_base_dir" >> "$PLAN_FILE"
    else
      found_any=false
      while IFS= read -r -d '' pom; do
        found_any=true
        module_dir="$(dirname "$pom")"
        printf 'M|%s|%s|%s\n' "$module_dir" "$repo_dir" "$current_base_dir" >> "$PLAN_FILE"
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
        printf 'G|%s|%s|%s\n' "$repo_dir" "$repo_dir" "$current_base_dir" >> "$PLAN_FILE"
      fi
    fi
  done < <(find "$current_base_dir" -type d -name ".git" -print0 2>/dev/null || true)
done

# Dedup plan
PLAN_FILE_SORTED="${PLAN_FILE}.sorted"
awk 'BEGIN{FS=OFS="|"} {seen[$0]++} END{for(k in seen) print k}' "$PLAN_FILE" \
  | sort -t'|' -k1,1 -k2,2 -k3,3 -k4,4 > "$PLAN_FILE_SORTED"
mv "$PLAN_FILE_SORTED" "$PLAN_FILE"

TOTAL=$(wc -l < "$PLAN_FILE" | awk '{print $1+0}')
log "Plan         : modules_to_process=$TOTAL"

# PASS 2: Execute with progress
IDX=0
while IFS='|' read -r kind pdir repodir basedir; do
  IDX=$((IDX+1))
  if [[ "$kind" = "M" ]]; then
    log "------------------------------------------------------------"
    log "Progress     : ($IDX/$TOTAL)"
    log "Repo (module): $repodir"
    log "Module dir   : $pdir"
    process_path "$pdir" "$repodir" "$basedir" || true
  else
    log "------------------------------------------------------------"
    log "Progress     : ($IDX/$TOTAL)"
    log "Repo (git-only): $pdir"
    process_repo_git_only "$pdir" || true
  fi
done < "$PLAN_FILE"

# -------- M2 Audit (used vs present) ------------------------------------------
if [ "$AUDIT_M2" = true ]; then
  if [ ! -d "$M2_REPO" ]; then
    log "WARN         : M2 repo does not exist: $M2_REPO - audit skipped"
  else
    USED_SET="${TMPDIR:-/tmp}/used_set_${TS}.lst"
    M2_SET="${TMPDIR:-/tmp}/m2_set_${TS}.lst"

    USED_CSV="${BASE_DIR}/used_deps.csv"
    UNUSED_CSV="${BASE_DIR}/unused_deps.csv"

    log "============================================================"
    log "# Audit M2 - scanning artifacts in M2"
    find "$M2_REPO" -type f \( -name "*.jar" -o -name "*.bundle" -o -name "*.zip" \) 2>/dev/null \
      | grep -vE '(-sources|-javadoc|-tests|-test|-native|-linux|-mac|-win)\.(jar|zip|bundle)$' \
      | awk -v repo="$M2_REPO" '
        {
          file=$0
          gsub("^"repo"/","",file)
          n=split(file, seg, "/")
          if (n < 4) next
          artFile = seg[n]
          verDir  = seg[n-1]
          artId   = seg[n-2]
          group=""
          for (i=1; i<=n-3; i++) {
            group = group (i==1? "" : ".") seg[i]
          }
          prefix = artId "-" verDir
          if (index(artFile, prefix) == 1) {
            print group ":" artId ":" verDir
          }
        }
      ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | sort -u > "$M2_SET"

    if [[ "$SEPARATE_AUDITS" == true ]]; then
      log "# Audit M2 - generating separate CSVs per BASE_DIR"
      
      # Process each BASE_DIR separately
      for base_dir in "${NORMALIZED_BASE_DIRS[@]}"; do
        deps_file="$(get_base_dir_deps_file "$base_dir")"
        if [[ -z "$deps_file" || ! -s "$deps_file" ]]; then
          log "Audit M2     : No dependencies found for $base_dir"
          continue
        fi
        
        base_name="$(basename "$base_dir")"
        used_csv="$base_dir/used_deps_${base_name}.csv"
        unused_csv="$base_dir/unused_deps_${base_name}.csv"
        used_set="${TMPDIR:-/tmp}/used_set_${base_name}_${TS}.lst"
        
        # Process dependencies for this BASE_DIR
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$deps_file" \
          | grep -v -E '^[[:space:]]*$' \
          | sort -u > "$used_set"
        
        total_used_dir=$(awk 'END{print NR+0}' "$used_set")
        log "Audit M2     : $base_dir → $total_used_dir unique dependencies"
        
        # Generate CSV files for this BASE_DIR
        {
          echo "groupId,artifactId,version"
          awk -F':' '{
            g=$1; a=$2; v=$3;
            gsub(/^[ \t]+|[ \t]+$/, "", g);
            gsub(/^[ \t]+|[ \t]+$/, "", a);
            gsub(/^[ \t]+|[ \t]+$/, "", v);
            if (g ~ /^[A-Za-z0-9_.-]+$/ && a ~ /^[A-Za-z0-9_.-]+$/ && v ~ /^[A-Za-z0-9_.-]+$/)
              print g","a","v;
          }' "$used_set"
        } > "$used_csv"
        
        comm -23 "$M2_SET" "$used_set" \
          | awk -F':' 'BEGIN{print "groupId,artifactId,version"}{
            g=$1; a=$2; v=$3;
            gsub(/^[ \t]+|[ \t]+$/, "", g);
            gsub(/^[ \t]+|[ \t]+$/, "", a);
            gsub(/^[ \t]+|[ \t]+$/, "", v);
            if (g ~ /^[A-Za-z0-9_.-]+$/ && a ~ /^[A-Za-z0-9_.-]+$/ && v ~ /^[A-Za-z0-9_.-]+$/)
              print g","a","v;
          }' > "$unused_csv"
        
        log "Audit M2     : $base_dir → $used_csv"  
        log "Audit M2     : $base_dir → $unused_csv"
      done
      
      log "============================================================"
      log "# Audit M2 - M2 purging disabled with --separate-audits"
      log "# Each BASE_DIR has its own unused_deps CSV. Review and purge manually if needed."
      
    else
      log "# Audit M2 - parsing captured dependencies (same traversal)"
    if [ -s "$TMP_DEP_OUT" ]; then
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$TMP_DEP_OUT" \
        | grep -v -E '^[[:space:]]*$' \
        | sort -u > "$USED_SET"
      total_used=$(awk 'END{print NR+0}' "$USED_SET")
      log "Audit M2     : unique used deps = $total_used"
    else
      : > "$USED_SET"
      log "WARN         : no dependencies captured (check logs per module and flags)"
    fi

    log "# Audit M2 - scanning artifacts in M2"
    find "$M2_REPO" -type f \( -name "*.jar" -o -name "*.bundle" -o -name "*.zip" \) 2>/dev/null \
      | grep -vE '(-sources|-javadoc|-tests|-test|-native|-linux|-mac|-win)\.(jar|zip|bundle)$' \
      | awk -v repo="$M2_REPO" '
        {
          file=$0
          gsub("^"repo"/","",file)
          n=split(file, seg, "/")
          if (n < 4) next
          artFile = seg[n]
          verDir  = seg[n-1]
          artId   = seg[n-2]
          group=""
          for (i=1; i<=n-3; i++) {
            group = group (i==1? "" : ".") seg[i]
          }
          prefix = artId "-" verDir
          if (index(artFile, prefix) == 1) {
            print group ":" artId ":" verDir
          }
        }
      ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | sort -u > "$M2_SET"

    log "# Audit M2 - generating CSVs in $BASE_DIR"
    {
      echo "groupId,artifactId,version"
      awk -F':' '{
        g=$1; a=$2; v=$3;
        gsub(/^[ \t]+|[ \t]+$/, "", g);
        gsub(/^[ \t]+|[ \t]+$/, "", a);
        gsub(/^[ \t]+|[ \t]+$/, "", v);
        if (g ~ /^[A-Za-z0-9_.-]+$/ && a ~ /^[A-Za-z0-9_.-]+$/ && v ~ /^[A-Za-z0-9_.-]+$/)
          print g","a","v;
      }' "$USED_SET"
    } > "$USED_CSV"

    comm -23 "$M2_SET" "$USED_SET" \
      | awk -F':' 'BEGIN{print "groupId,artifactId,version"}{
        g=$1; a=$2; v=$3;
        gsub(/^[ \t]+|[ \t]+$/, "", g);
        gsub(/^[ \t]+|[ \t]+$/, "", a);
        gsub(/^[ \t]+|[ \t]+$/, "", v);
        if (g ~ /^[A-Za-z0-9_.-]+$/ && a ~ /^[A-Za-z0-9_.-]+$/ && v ~ /^[A-Za-z0-9_.-]+$/)
          print g","a","v;
      }' > "$UNUSED_CSV"

    log "Audit M2     : OK → $USED_CSV"
    log "Audit M2     : OK → $UNUSED_CSV"

    # -------- PURGE M2_REPO according to unused_deps.csv ----------------------
    log "# Audit M2 - purging unused artifacts in $M2_REPO"

    if [ -s "$UNUSED_CSV" ]; then
      UNUSED_CANDIDATES=$(( $(wc -l < "$UNUSED_CSV") - 1 ))
    else
      UNUSED_CANDIDATES=0
    fi
    log "M2 purge     : candidates=$UNUSED_CANDIDATES"

    DEL_COUNT=0
    FREED_KB=0
    NOT_FOUND=0
    NOT_FOUND_SAMPLES_FILE="${TMPDIR:-/tmp}/m2_purge_missing_${TS}.txt"
    : > "$NOT_FOUND_SAMPLES_FILE"

    if [ "$UNUSED_CANDIDATES" -le 0 ]; then
      log "M2 purge     : no rows in $UNUSED_CSV"
    else
      EXISTING_DIRS_FILE="${TMPDIR:-/tmp}/m2_purge_existing_${TS}.lst"
      : > "$EXISTING_DIRS_FILE"

      set +e
      while IFS=, read -r g a v; do
        [ "$g" = "groupId" ] && continue
        g="${g//[$' \t\r\n']/}"
        a="${a//[$' \t\r\n']/}"
        v="${v//[$' \t\r\n']/}"
        [ -z "$g" ] && continue
        [ -z "$a" ] && continue
        [ -z "$v" ] && continue

        gpath="$(printf '%s' "$g" | tr '.' '/')"
        target="$M2_REPO/$gpath/$a/$v"

        case "$target" in "$M2_REPO"|"$M2_REPO/") continue ;; esac

        if [[ -d "$target" ]]; then
          printf '%s\0' "$target" >> "$EXISTING_DIRS_FILE"
        else
          NOT_FOUND=$((NOT_FOUND+1))
          if [ $(wc -l < "$NOT_FOUND_SAMPLES_FILE") -lt 20 ]; then
            printf '%s,%s,%s -> %s\n' "$g" "$a" "$v" "$target" >> "$NOT_FOUND_SAMPLES_FILE"
          fi
        fi
      done < <(tail -n +2 "$UNUSED_CSV")
      set -e

      # Count existing directories and warn about what will be deleted
      if [ -s "$EXISTING_DIRS_FILE" ]; then
        EXISTING_COUNT=$(tr -cd '\0' < "$EXISTING_DIRS_FILE" | wc -c | awk '{print $1+0}')
      else
        EXISTING_COUNT=0
      fi
      log "M2 purge     : to_remove=$EXISTING_COUNT of $UNUSED_CANDIDATES candidates"

      if [ "$DRY_RUN" = true ] || [ "$REPORT_ONLY" = true ]; then
        log "DRY-RUN: would remove $EXISTING_COUNT directories (no deletion performed)"
      else
        set +e
        while IFS= read -r -d '' dir; do
          sz=$(du -sk "$dir" 2>/dev/null | awk '{print $1+0}')
          rm -rf -- "$dir"
          if [ $? -eq 0 ]; then
            log "M2 purge    : removed $dir (${sz:-0}K)"
            DEL_COUNT=$((DEL_COUNT+1))
            FREED_KB=$((FREED_KB + ${sz:-0}))

            parent="$(dirname "$dir")"
            while [[ "$parent" != "$M2_REPO" ]]; do
              rmdir -- "$parent" 2>/dev/null || break
              parent="$(dirname "$parent")"
            done
          else
            log "WARN         : rm failed on $dir"
          fi
        done < "$EXISTING_DIRS_FILE"
        set -e
      fi

      # Final metrics and examples of not found artifacts
      if [ -f "$NOT_FOUND_SAMPLES_FILE" ] && [ -s "$NOT_FOUND_SAMPLES_FILE" ]; then
        log "M2 purge     : not_found=$NOT_FOUND (sample up to 20 below)"
        while IFS= read -r line; do log "  missing    : $line"; done < "$NOT_FOUND_SAMPLES_FILE"
      else
        log "M2 purge     : not_found=$NOT_FOUND"
      fi

      log "M2 purge     : removed=$DEL_COUNT, to_delete=$UNUSED_CANDIDATES, freed=${FREED_KB}K (~$((FREED_KB/1024)) MB)"
    fi

    # -------- Post-purge random verification ----------------------------------
    post_verify_random_modules() {
      # Only run if enabled and not dry/report
      if [[ "$POST_VERIFY_SET" != true ]]; then
        log "Post-verify  : disabled"
        return 0
      fi
      if [[ "$DRY_RUN" == true || "$REPORT_ONLY" == true ]]; then
        log "Post-verify  : skipped (dry/report mode)"
        return 0
      fi

      # Unique list and filter to those with a Maven runner
      local uniq_file="${TMPDIR:-/tmp}/_mvn_mods_${TS}.lst"
      : > "$uniq_file"
      for m in "${MAVEN_MODULES[@]:-}"; do
        printf '%s\n' "$m"
      done | awk '!seen[$0]++' > "$uniq_file"

      local eligible_file="${TMPDIR:-/tmp}/_mvn_mods_eligible_${TS}.lst"
      : > "$eligible_file"
      while IFS= read -r mod; do
        [[ -z "$mod" ]] && continue
        if [[ -f "$mod/pom.xml" ]]; then
          if [[ -x "$mod/mvnw" || "$(command -v mvn >/dev/null 2>&1; echo $?)" -eq 0 ]]; then
            printf '%s\n' "$mod" >> "$eligible_file"
          fi
        fi
      done < "$uniq_file"

      local avail
      avail=$(wc -l < "$eligible_file" | awk '{print $1+0}')
      if [[ "${avail:-0}" -le 0 ]]; then
        log "Post-verify  : no eligible Maven modules found"
        return 0
      fi

      local n=$VERIFY_COUNT
      if [[ "$n" -gt "$avail" ]]; then n="$avail"; fi

      log "============================================================"
      log "# Post-purge - random verify in $n Maven module(s)"

      # Pick n random lines: prefer shuf; fallback to awk rand()
      local picks_file="${TMPDIR:-/tmp}/_mvn_picks_${TS}.lst"
      if command -v shuf >/dev/null 2>&1; then
        shuf -n "$n" "$eligible_file" > "$picks_file"
      else
        awk -v n="$n" 'BEGIN{srand()} {a[NR]=$0} END{
          if (NR<=n){for(i=1;i<=NR;i++) print a[i]; exit}
          for(i=1;i<=n;i++){
            r=int(rand()*NR)+1
            if(a[r]!=""){print a[r]; a[r]=""} else {i--}
          }
        }' "$eligible_file" > "$picks_file"
      fi

      local v_ok=0 v_fail=0
      while IFS= read -r mod; do
        [[ -z "$mod" ]] && continue
        local runner
        if ! runner="$(resolve_maven_runner "$mod")"; then
          log "Post-verify  : skip (no mvn/mvnw) → $mod"
          continue
        fi
        log "Verify start : $mod ⇒ $runner -U -DskipTests verify"
        if ( cd "$mod" && "$runner" -U -DskipTests -q -B verify ); then
          log "Verify OK    : $mod"
          v_ok=$((v_ok+1))
        else
          log "Verify FAIL  : $mod"
          v_fail=$((v_fail+1))
        fi
      done < "$picks_file"

      log "Post-verify  : done → ok=$v_ok fail=$v_fail (sample size=$n)"
      log "============================================================"
    }

    post_verify_random_modules
    fi  # end of else (not separate-audits)
  fi
fi

# -------- Global Cache Cleanup (if requested) ---------------------------------
clean_global_caches

# -------- Summary --------------------------------------------------------------
log "============================================================"
log "# Summary"
log "Total discovered (Maven modules) : $TOTAL"
log "Success (clean OK)               : $OK"
log "Failed (clean FAIL)              : $FAIL"
log "Skipped (no mvn/mvnw or filters) : $SKIP"

if (( OK > 0 )); then
  log "OK:"; for p in "${OK_LIST[@]}"; do log "  - $p"; done
fi
if (( FAIL > 0 )); then
  log "FAIL:"; for p in "${FAIL_LIST[@]}"; do log "  - $p"; done
fi
if (( SKIP > 0 )); then
  log "SKIP:"; for p in "${SKIP_LIST[@]}"; do log "  - $p"; done
fi

log "============================================================"
log "# End"
log "============================================================"

(( FAIL > 0 )) && exit 1 || exit 0
