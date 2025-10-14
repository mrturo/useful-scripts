#!/bin/bash
# clean_build_artifacts.sh
# Multi-stack cleaner with auto-detection: Java (Maven/Gradle), Node.js/TS and Python.
# Usage:
#   ./clean_build_artifacts.sh                # auto-detect
#   ./clean_build_artifacts.sh --dry-run
#   ./clean_build_artifacts.sh --no-kill
#   ./clean_build_artifacts.sh --stacks=java,node   # override
#
# Detection signals (up to 4 levels):
#   Java: pom.xml, mvn, build.gradle, gradlew
#   Node: package.json, pnpm-lock.yaml, yarn.lock, package-lock.json, turbo.json, tsconfig.json
#   Python: pyproject.toml, requirements*.txt, setup.(cfg|py), Pipfile, poetry.lock, .venv/venv

set -euo pipefail

DRY_RUN=false
KILL_PROCS=true
STACKS_OVERRIDE=""   # empty => auto
SCAN_DEPTH=4         # balance speed/precision

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --no-kill) KILL_PROCS=false ;;
    --stacks=*) STACKS_OVERRIDE="${arg#*=}" ;;
    --help)
      cat <<'EOF'
Universal multi-stack cleaner (auto-detect)

Options:
  --dry-run          Show actions without applying changes
  --no-kill          Don't kill processes that block directories
  --stacks=LIST      Force stacks: java,node,python (comma-separated). Default: auto-detect
  -h, --help         Help
EOF
      exit 0
      ;;
    *)
      echo "Unrecognized option: $arg" >&2
      exit 2
      ;;
  esac
done

# Repo root
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT=$(git rev-parse --show-toplevel)
else
  REPO_ROOT=$(pwd)
fi
cd "$REPO_ROOT"

echo "📦 Repo: $REPO_ROOT"
echo "Flags -> dryRun: $DRY_RUN, killProcs: $KILL_PROCS, stacks(forced): ${STACKS_OVERRIDE:-<auto>}"

# Helpers
run_cmd() {
  local cmd="$*"
  if $DRY_RUN; then
    echo "DRY-RUN $ $cmd"
  else
    eval "$cmd"
  fi
}
safe_rm() {
  local path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    if $DRY_RUN; then
      echo "DRY-RUN rm -rf '$path'"
    else
      rm -rf "$path"
    fi
  fi
}
kill_using_dir() {
  local dir="$1"
  $KILL_PROCS || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  if lsof +D "$dir" >/dev/null 2>&1; then
    echo "Killing processes using $dir..."
    lsof +D "$dir" | awk 'NR>1 {print $2}' | sort -u | xargs -r kill -9 2>/dev/null || true
  fi
}

# -------- Auto-detection of stacks --------
declare -a DETECTED_STACKS=()

detect_java() {
  find "$REPO_ROOT" -maxdepth "$SCAN_DEPTH" \
    \( -name "pom.xml" -o -name "build.gradle" -o -name "build.gradle.kts" -o -name "mvnw" -o -name "gradlew" \) \
    -print -quit | grep -q .
}
detect_node() {
  find "$REPO_ROOT" -maxdepth "$SCAN_DEPTH" \
    \( -name "package.json" -o -name "pnpm-lock.yaml" -o -name "yarn.lock" -o -name "package-lock.json" -o -name "turbo.json" -o -name "tsconfig.json" \) \
    -print -quit | grep -q .
}
detect_python() {
  find "$REPO_ROOT" -maxdepth "$SCAN_DEPTH" \
    \( -name "pyproject.toml" -o -name "requirements*.txt" -o -name "setup.cfg" -o -name "setup.py" -o -name "Pipfile" -o -name "poetry.lock" -o -name ".venv" -o -name "venv" \) \
    -print -quit | grep -q .
}

if [ -n "$STACKS_OVERRIDE" ]; then
  IFS=',' read -r -a DETECTED_STACKS <<< "$STACKS_OVERRIDE"
else
  detect_java && DETECTED_STACKS+=("java")
  detect_node && DETECTED_STACKS+=("node")
  detect_python && DETECTED_STACKS+=("python")
fi

if [ "${#DETECTED_STACKS[@]}" -eq 0 ]; then
  echo "No stack detected. Nothing to clean."
  exit 0
fi

echo "Detected stacks: ${DETECTED_STACKS[*]}"

# -------- Collect targets by stack --------
TMP_LIST=$(mktemp -t clean-targets.XXXXXX)

add_find() {
  local name="$1" type="$2"
  if [ "$type" = "d" ]; then
    find "$REPO_ROOT" -type d -name "$name" -not -path "*/.*" -print >> "$TMP_LIST"
  else
    find "$REPO_ROOT" -type f -name "$name" -not -path "*/.*" -print >> "$TMP_LIST"
  fi
}

for s in "${DETECTED_STACKS[@]}"; do
  case "$s" in
    java)
      add_find "target" d
      add_find ".mvn" d
      add_find ".gradle" d
      add_find "build" d
      add_find ".flattened-pom.xml" f
      ;;
    node)
      add_find "node_modules" d
      add_find "dist" d
      add_find "build" d
      add_find ".next" d
      add_find ".nuxt" d
      add_find ".svelte-kit" d
      add_find "coverage" d
      add_find ".turbo" d
      add_find ".parcel-cache" d
      add_find ".rollupcache" d
      add_find ".webpack-cache" d
      add_find ".cache" d
      add_find "*.tsbuildinfo" f
      add_find "npm-debug.log*" f
      add_find "yarn-error.log*" f
      add_find "pnpm-debug.log*" f
      ;;
    python)
      add_find "__pycache__" d
      add_find ".pytest_cache" d
      add_find ".mypy_cache" d
      add_find ".ruff_cache" d
      add_find ".tox" d
      add_find ".nox" d
      add_find ".ipynb_checkpoints" d
      add_find ".venv" d
      add_find "venv" d
      add_find "build" d
      add_find "dist" d
      add_find "*.egg-info" d
      add_find "*.egg-info" f
      add_find "*.pyc" f
      add_find "*.pyo" f
      add_find ".coverage" f
      ;;
  esac
done

# De-duplicate
sort -u "$TMP_LIST" -o "$TMP_LIST"
TOTAL=$(wc -l < "$TMP_LIST" | tr -d ' ')
echo "Candidate paths: $TOTAL"

# -------- Kill processes (dirs only) --------
if [ "$TOTAL" -gt 0 ]; then
  echo "Terminating processes using candidate paths..."
  while IFS= read -r p; do
    [ -d "$p" ] && kill_using_dir "$p"
  done < "$TMP_LIST"
fi

# -------- Deletion (manual removal first) --------
if [ "$TOTAL" -gt 0 ]; then
  echo "Deleting paths…"
  while IFS= read -r p; do
    echo "Removing $p"
    safe_rm "$p"
  done < "$TMP_LIST"
fi

rm -f "$TMP_LIST"

# -------- Commands by stack (after manual deletion) --------
contains() { local x; for x in "${DETECTED_STACKS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

if contains java; then
  # Kill any running Maven processes to avoid cache issues
  echo "Killing cached Maven processes…"
  if $DRY_RUN; then
    echo "DRY-RUN pkill -f maven"
  else
    if pkill -f maven 2>/dev/null; then
      echo "✓ Maven processes terminated"
    else
      echo "✓ No Maven processes found"
    fi
  fi
  if [ -f "$REPO_ROOT/pom.xml" ]; then
    # Try mvn_proxy.sh wrapper first
    SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
    if [ -f "$SCRIPT_DIR/mvn_proxy.sh" ]; then
      echo "mvn_proxy.sh clean (root, best-effort)…"
      if $DRY_RUN; then
        echo "DRY-RUN $SCRIPT_DIR/mvn_proxy.sh -f '$REPO_ROOT/pom.xml' clean -U -Dmaven.clean.failOnError=false"
      else
        # Retry logic for Maven clean (handles locked files on macOS)
        MAX_RETRIES=3
        RETRY_DELAY=2
        SUCCESS=false
        
        for attempt in $(seq 1 $MAX_RETRIES); do
          if [ $attempt -gt 1 ]; then
            echo "⏳ Retry attempt $attempt/$MAX_RETRIES (waiting ${RETRY_DELAY}s for file locks to release)…"
            sleep $RETRY_DELAY
          fi
          
          if "$SCRIPT_DIR/mvn_proxy.sh" -f "$REPO_ROOT/pom.xml" clean -U -Dmaven.clean.failOnError=false; then
            echo "✓ mvn_proxy.sh clean succeeded"
            SUCCESS=true
            break
          else
            if [ $attempt -lt $MAX_RETRIES ]; then
              echo "⚠️  mvn_proxy.sh clean failed (attempt $attempt/$MAX_RETRIES) - likely file locks"
            fi
          fi
        done
        
        if ! $SUCCESS; then
          echo "✗ mvn_proxy.sh clean failed after $MAX_RETRIES attempts, trying fallback…"
          # Fallback to mvn
          echo "mvn clean (root, best-effort)…"
          for attempt in $(seq 1 $MAX_RETRIES); do
            if [ $attempt -gt 1 ]; then
              echo "⏳ Retry attempt $attempt/$MAX_RETRIES (mvn fallback)…"
              sleep $RETRY_DELAY
            fi
            
            if mvn -f "$REPO_ROOT/pom.xml" clean -U -Dmaven.clean.failOnError=false; then
              echo "✓ mvn clean succeeded"
              break
            fi
          done || true
        fi
      fi
    # If mvn_proxy.sh not available, try mvn with retry
    else
      echo "mvn clean (root, best-effort)…"
      if $DRY_RUN; then
        echo "DRY-RUN mvn -f '$REPO_ROOT/pom.xml' clean -U -Dmaven.clean.failOnError=false"
      else
        MAX_RETRIES=3
        RETRY_DELAY=2
        
        for attempt in $(seq 1 $MAX_RETRIES); do
          if [ $attempt -gt 1 ]; then
            echo "⏳ Retry attempt $attempt/$MAX_RETRIES (waiting ${RETRY_DELAY}s for file locks to release)…"
            sleep $RETRY_DELAY
          fi
          
          if mvn -f "$REPO_ROOT/pom.xml" clean -U -Dmaven.clean.failOnError=false; then
            echo "✓ mvn clean succeeded"
            break
          fi
        done || true
      fi
    fi
  fi
  if [ -f "$REPO_ROOT/gradlew" ]; then
    echo "./gradlew clean (root, best-effort)…"
    $DRY_RUN && echo "DRY-RUN ./gradlew clean" || ./gradlew clean || true
  elif command -v gradle >/dev/null 2>&1 && [ -f "$REPO_ROOT/build.gradle" -o -f "$REPO_ROOT/build.gradle.kts" ]; then
    echo "gradle clean (root, best-effort)…"
    $DRY_RUN && echo "DRY-RUN gradle clean" || gradle clean || true
  fi
fi

if contains node; then
  if command -v pnpm >/dev/null 2>&1 && [ -f "$REPO_ROOT/pnpm-workspace.yaml" ]; then
    echo "pnpm -r run clean (best-effort)…"
    $DRY_RUN && echo "DRY-RUN pnpm -r --silent run clean" || pnpm -r --silent run clean || true
  fi
  if command -v yarn >/dev/null 2>&1 && [ -f "$REPO_ROOT/package.json" ] && grep -q "\"workspaces\"" "$REPO_ROOT/package.json" 2>/dev/null; then
    echo "yarn workspaces foreach run clean (best-effort)…"
    $DRY_RUN && echo "DRY-RUN yarn workspaces foreach -A -v run clean" || yarn workspaces foreach -A -v run clean || true
  fi
  if command -v npm >/dev/null 2>&1 && [ -f "$REPO_ROOT/package.json" ]; then
    echo "npm run clean (root, best-effort)…"
    $DRY_RUN && echo "DRY-RUN npm run -s clean" || npm run -s clean || true
    if grep -q "\"workspaces\"" "$REPO_ROOT/package.json" 2>/dev/null; then
      echo "npm -ws run clean (best-effort)…"
      $DRY_RUN && echo "DRY-RUN npm -ws run -s clean" || npm -ws run -s clean || true
    fi
  fi
fi

# --- Python envtool uninstall attempts ---
if contains python; then
  PYTHON_ENVTOOL_UNINSTALLED=false
  if [ -f "$REPO_ROOT/envtool.sh" ]; then
    echo "Trying: bash envtool.sh uninstall (Python env cleanup)…"
    if $DRY_RUN; then
      echo "DRY-RUN bash envtool.sh uninstall"
      PYTHON_ENVTOOL_UNINSTALLED=true
    else
      bash envtool.sh uninstall && PYTHON_ENVTOOL_UNINSTALLED=true || PYTHON_ENVTOOL_UNINSTALLED=false
    fi
  fi
  if ! $PYTHON_ENVTOOL_UNINSTALLED && [ -f "$REPO_ROOT/env_tool.sh" ]; then
    echo "Trying: bash env_tool.sh uninstall (Python env cleanup)…"
    if $DRY_RUN; then
      echo "DRY-RUN bash env_tool.sh uninstall"
      PYTHON_ENVTOOL_UNINSTALLED=true
    else
      bash env_tool.sh uninstall && PYTHON_ENVTOOL_UNINSTALLED=true || PYTHON_ENVTOOL_UNINSTALLED=false
    fi
  fi
  if ! $PYTHON_ENVTOOL_UNINSTALLED; then
    if command -v pytest >/dev/null 2>&1; then
      echo "pytest --cache-clear (best-effort)…"
      $DRY_RUN && echo "DRY-RUN pytest --cache-clear" || pytest --cache-clear || true
    fi
  fi
fi

echo "✅ Cleanup completed for stacks: ${DETECTED_STACKS[*]}"