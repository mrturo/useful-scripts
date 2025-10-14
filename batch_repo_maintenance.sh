#!/bin/bash
# Batch repository maintenance script
#
# This script performs comprehensive maintenance on all git repositories within configured directories:
# 1. Cleans build artifacts using clean_build_artifacts.sh
# 2. Updates all branches with git-pull-all
# 3. Analyzes last commit age (if >30 days, switches to main/master before pruning)
# 4. Prunes local branches that no longer exist on remote
# 5. Reports any failures at the end
#
# Usage: ./batch_repo_maintenance.sh
# Dependencies: clean_build_artifacts.sh, git_util.sh

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create local tmp directory if it doesn't exist
TMP_DIR="$SCRIPT_DIR/tmp"
mkdir -p "$TMP_DIR"

# Unset proxy variables
source "$SCRIPT_DIR/unset_proxies.sh" 2>/dev/null || true
set -euo pipefail

# === CONFIGURE YOUR BASE DIRECTORIES AND SPECIFIC REPOS HERE ===
DIR1="$HOME/Documents/reps-personal"
DIR2="$HOME/Documents/reps-walmart"

# Base directories containing git repositories to maintain (will scan recursively)
BASE_DIRS=("$DIR1" "$DIR2")

# Specific repositories to maintain (direct paths to individual repos)
# Example: SPECIFIC_REPOS=("$HOME/Documents/my-project" "$HOME/Code/another-repo")
REPO1="$HOME/Documents/scripts"
SPECIFIC_REPOS=("$REPO1")

# Track failures for final report
FAILED_GIT_PULL_NETWORK=()
FAILED_GIT_PULL_OTHER=()

# Function to process a single repository
process_repo() {
  local REPO_DIR="$1"

  set +e

  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "⚠️  Not a git repository: $REPO_DIR (skipping)"
    set -e
    return
  fi

  echo "🧹 Processing repo: $REPO_DIR"

  # Navigate to repository root
  cd "$REPO_DIR"

  CLEAN_SUCCESS=true
  GIT_PULL_SUCCESS=true
  GIT_PULL_ERROR_OUTPUT=""
  SKIP_REASON=""

  # Step 1: Check Maven/Java version compatibility
  "$SCRIPT_DIR/check_maven_java_version.sh" || true

  # Step 2: Clean build artifacts (node_modules, target, build directories, etc.)
  if ! "$SCRIPT_DIR/clean_build_artifacts.sh"; then
    CLEAN_SUCCESS=false
    SKIP_REASON="Build artifact cleanup failed"
  fi

  # Step 3: Clean up Maven wrapper files
  echo "y" | "$SCRIPT_DIR/cleanup_maven_wrapper.sh" 2>/dev/null || true

  # Step 4: Update all branches from remote
  GIT_PULL_ERROR_OUTPUT=$("$SCRIPT_DIR/git_util.sh" git-pull-all 2>&1) || GIT_PULL_SUCCESS=false

  if [ "$GIT_PULL_SUCCESS" = false ]; then
    # Check if it's a network error
    if echo "$GIT_PULL_ERROR_OUTPUT" | grep -q "Failed to fetch remotes. Check your network or remote URLs"; then
      echo "$REPO_DIR" >> "$TMP_DIR/batch_repo_maintenance_git_pull_network_failures.tmp"
      SKIP_REASON="Network error fetching remotes"
    elif echo "$GIT_PULL_ERROR_OUTPUT" | grep -q "uncommitted changes"; then
      # Check if the only uncommitted file is .java-version
      UNCOMMITTED_FILES=$(git status --porcelain | awk '{print $2}')
      if [ "$UNCOMMITTED_FILES" = ".java-version" ]; then
        echo "🗑️  Only .java-version is uncommitted. Deleting and retrying..."
        rm -f .java-version
        # Retry git-pull-all after deleting .java-version
        GIT_PULL_ERROR_OUTPUT=$("$SCRIPT_DIR/git_util.sh" git-pull-all 2>&1)
        if [ $? -eq 0 ]; then
          GIT_PULL_SUCCESS=true
          SKIP_REASON=""
        else
          GIT_PULL_SUCCESS=false
          echo "$REPO_DIR****Uncommitted changes in working directory (after .java-version removal)" >> "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp"
          SKIP_REASON="Uncommitted changes in working directory (after .java-version removal)"
        fi
      else
        echo "$REPO_DIR****Uncommitted changes in working directory" >> "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp"
        GIT_PULL_SUCCESS=false
        SKIP_REASON="Uncommitted changes in working directory"
      fi
    elif echo "$GIT_PULL_ERROR_OUTPUT" | grep -q "unpushed local commits"; then
      echo "$REPO_DIR****Unpushed local commits" >> "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp"
      SKIP_REASON="Unpushed local commits"
    elif echo "$GIT_PULL_ERROR_OUTPUT" | grep -q "no upstream configured"; then
      echo "$REPO_DIR****No upstream configured" >> "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp"
      SKIP_REASON="No upstream configured"
    else
      echo "$REPO_DIR****Unknown git error" >> "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp"
      SKIP_REASON="Unknown git error"
    fi
  else
    # Step 5: Analyze commit age and prune stale branches
    CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

    if [ -n "$CURRENT_BRANCH" ]; then
      # Check if already on main or master branch
      if [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
        # Check if current branch was deleted from remote
        UPSTREAM_BRANCH=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "")

        if [ -n "$UPSTREAM_BRANCH" ]; then
          # Branch has/had a remote tracking branch
          REMOTE_NAME=$(echo "$UPSTREAM_BRANCH" | cut -d'/' -f1)
          REMOTE_BRANCH=$(echo "$UPSTREAM_BRANCH" | cut -d'/' -f2-)

          # Check if the remote branch still exists
          if ! git ls-remote --heads "$REMOTE_NAME" "$REMOTE_BRANCH" | grep -q "$REMOTE_BRANCH"; then
            echo "🗑️  Current branch '$CURRENT_BRANCH' was deleted from remote. Switching to main/master..."
            if git show-ref --verify --quiet refs/heads/main; then
              git checkout main >/dev/null 2>&1
            elif git show-ref --verify --quiet refs/heads/master; then
              git checkout master >/dev/null 2>&1
            fi
          else
            # Remote branch still exists, check commit age
            LAST_COMMIT_DATE=$(git log -1 --format=%ct 2>/dev/null || echo "0")
            CURRENT_DATE=$(date +%s)
            DAYS_DIFF=$(( (CURRENT_DATE - LAST_COMMIT_DATE) / 86400 ))

            # If repository is inactive (>30 days), switch to main/master before pruning
            if [ "$DAYS_DIFF" -gt 30 ]; then
              echo "⏰ Last commit is $DAYS_DIFF days old. Switching to main before pruning..."
              if git show-ref --verify --quiet refs/heads/main; then
                git checkout main >/dev/null 2>&1
              elif git show-ref --verify --quiet refs/heads/master; then
                git checkout master >/dev/null 2>&1
              fi
            else
              echo "📅 Last commit is $DAYS_DIFF days old. Pruning from current branch..."
            fi
          fi
        else
          # No upstream branch configured - it's a local-only branch that was never pushed
          echo "🏠 Branch '$CURRENT_BRANCH' is local-only (never pushed). Keeping current branch..."
        fi
      else
        echo "📍 Already on $CURRENT_BRANCH branch. Proceeding with pruning..."
      fi

      # Step 6: Remove local branches that no longer exist on remote
      "$SCRIPT_DIR/git_util.sh" prune-local
    fi
  fi

  if [ "$CLEAN_SUCCESS" = true ] && [ "$GIT_PULL_SUCCESS" = true ]; then
    echo "✅ Done: $REPO_DIR"
  else
    echo "⚠️  Skipped (with issues): $REPO_DIR"
    if [ -n "$SKIP_REASON" ]; then
      echo "   Reason: $SKIP_REASON"
    fi
  fi
  echo "-------------------------------"

  set -e
}

# Process specific repositories first
if [ ${#SPECIFIC_REPOS[@]} -gt 0 ]; then
  echo "📦 Processing specific repositories..."
  for REPO_DIR in "${SPECIFIC_REPOS[@]}"; do
    process_repo "$REPO_DIR"
  done
fi

# Then scan and process base directories
for BASE_DIR in "${BASE_DIRS[@]}"; do
  echo "🔍 Scanning: $BASE_DIR"

  # Recursively find all git repositories in the directory tree
  find "$BASE_DIR" -type d -name ".git" | while read -r gitdir; do
    REPO_DIR=$(dirname "$gitdir")
    process_repo "$REPO_DIR"
  done
done

echo ""
echo "🏁 All repositories processed."
echo ""

# Final report: display repositories where git-pull-all failed
NETWORK_FAILURES_EXIST=false
OTHER_FAILURES_EXIST=false

if [ -f "$TMP_DIR/batch_repo_maintenance_git_pull_network_failures.tmp" ]; then
  NETWORK_FAILURES_EXIST=true
fi

if [ -f "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp" ]; then
  OTHER_FAILURES_EXIST=true
fi

if [ "$NETWORK_FAILURES_EXIST" = true ] || [ "$OTHER_FAILURES_EXIST" = true ]; then
  echo "================================================"
  echo "❌ Repositories that failed on git-pull-all:"
  echo "================================================"
 
  if [ "$NETWORK_FAILURES_EXIST" = true ]; then
    echo ""
    echo "🌐 Network/Remote errors (Failed to fetch remotes):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat "$TMP_DIR/batch_repo_maintenance_git_pull_network_failures.tmp"
    echo ""
    echo "💡 Suggestion: Check if you are connected to a VPN that might be blocking access to these repositories."
    echo ""
    rm "$TMP_DIR/batch_repo_maintenance_git_pull_network_failures.tmp"
  fi
 
  if [ "$OTHER_FAILURES_EXIST" = true ]; then
    if [ "$NETWORK_FAILURES_EXIST" = true ]; then
      echo ""
      echo "⚠️  Other errors:"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
    while IFS='****' read -r repo reason; do
      echo "$repo"
      if [ -n "$reason" ]; then
        echo "   → $reason"
      fi
    done < "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp"
    echo ""
    rm "$TMP_DIR/batch_repo_maintenance_git_pull_other_failures.tmp"
  fi
else
  echo "✅ All repositories were successfully updated with git-pull-all"
  echo ""
fi