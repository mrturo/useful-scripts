#!/bin/bash
# cleanup_maven_wrapper.sh
# Removes Maven wrapper configuration and reverts changes created by check_maven_java_version.sh
# This includes .mvn directory, mvnw scripts, and .java-version file.
# Works both in git repositories (reverts uncommitted changes) and non-git projects (direct deletion).

set -e
# Show error details if any error occurs
trap 'rc=$?; if [ $rc -ne 0 ]; then echo "[PWD: $(pwd)] Error at line $LINENO. Exit code: $rc"; fi' ERR

echo "[INFO] Starting Maven wrapper cleanup in: $(pwd)"

# Files and directories created by check_maven_java_version.sh
MAVEN_WRAPPER_FILES=(
  ".mvn"
  "mvnw"
  "mvnw.cmd"
  ".java-version"
)

# Check if this is a git repository
IS_GIT_REPO=false
if [ -d ".git" ]; then
  IS_GIT_REPO=true
  echo "[INFO] Git repository detected - will revert uncommitted changes"
else
  echo "[INFO] Not a git repository - will delete files directly"
fi

echo ""

# Track if any files were found
FILES_FOUND=false
FILES_TO_PROCESS=()

if [ "$IS_GIT_REPO" = true ]; then
  # GIT REPOSITORY MODE: Check for uncommitted changes
  echo "[INFO] Checking for uncommitted Maven wrapper files..."
  
  for item in "${MAVEN_WRAPPER_FILES[@]}"; do
    if [ -e "$item" ]; then
      echo "[DEBUG] Checking status of: $item"
      
      # Check if file/directory is tracked by git and has changes
      if git ls-files --error-unmatch "$item" &>/dev/null; then
        # File is tracked - check if it has modifications
        if git diff --name-only | grep -q "^${item}" || \
           git diff --cached --name-only | grep -q "^${item}"; then
          echo "[FOUND] Modified tracked file: $item"
          FILES_FOUND=true
          FILES_TO_PROCESS+=("$item")
        fi
      else
        # Check if file is untracked
        if git ls-files --others --exclude-standard | grep -q "^${item}"; then
          echo "[FOUND] Untracked file/directory: $item"
          FILES_FOUND=true
          FILES_TO_PROCESS+=("$item")
        fi
      fi
    fi
  done
else
  # NON-GIT MODE: Check for existing files
  echo "[INFO] Checking for Maven wrapper files..."
  
  for item in "${MAVEN_WRAPPER_FILES[@]}"; do
    if [ -e "$item" ]; then
      if [ -d "$item" ]; then
        echo "[FOUND] Directory: $item"
      else
        echo "[FOUND] File: $item"
      fi
      FILES_FOUND=true
      FILES_TO_PROCESS+=("$item")
    fi
  done
fi

if [ "$FILES_FOUND" = false ]; then
  echo ""
  echo "[INFO] No Maven wrapper files found."
  exit 0
fi

echo ""
echo "[INFO] Starting cleanup..."

if [ "$IS_GIT_REPO" = true ]; then
  # GIT MODE: Use git commands to revert/remove
  
  # Remove untracked files
  for item in "${MAVEN_WRAPPER_FILES[@]}"; do
    if [ -e "$item" ]; then
      if ! git ls-files --error-unmatch "$item" &>/dev/null; then
        # File is untracked - remove it
        if [ -d "$item" ]; then
          echo "[ACTION] Removing untracked directory: $item"
          rm -rf "$item"
        else
          echo "[ACTION] Removing untracked file: $item"
          rm -f "$item"
        fi
      fi
    fi
  done
  
  # Discard changes to tracked files
  for item in "${MAVEN_WRAPPER_FILES[@]}"; do
    if [ -e "$item" ]; then
      if git ls-files --error-unmatch "$item" &>/dev/null; then
        # File is tracked - check if it has changes
        if git diff --name-only | grep -q "^${item}" || \
           git diff --cached --name-only | grep -q "^${item}"; then
          echo "[ACTION] Discarding changes to tracked file: $item"
          git checkout -- "$item" 2>/dev/null || true
          git reset HEAD "$item" 2>/dev/null || true
        fi
      fi
    fi
  done
  
  echo ""
  echo "[SUCCESS] Maven wrapper cleanup completed."
  echo "[INFO] Summary:"
  git status --short | grep -E "(.mvn|mvnw|\.java-version)" || echo "  No Maven wrapper files remaining in changes."
  
else
  # NON-GIT MODE: Direct deletion
  
  for item in "${FILES_TO_PROCESS[@]}"; do
    if [ -e "$item" ]; then
      if [ -d "$item" ]; then
        echo "[ACTION] Deleting directory: $item"
        rm -rf "$item"
      else
        echo "[ACTION] Deleting file: $item"
        rm -f "$item"
      fi
    fi
  done
  
  echo ""
  echo "[SUCCESS] Maven wrapper cleanup completed."
  echo "[INFO] Deleted files:"
  for item in "${FILES_TO_PROCESS[@]}"; do
    if [ ! -e "$item" ]; then
      echo "  ✓ $item"
    fi
  done
fi
