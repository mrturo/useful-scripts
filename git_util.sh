#!/bin/bash

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

STASH_MESSAGE="auto-stash-before-pull-script"
stashRef=""

currentBranch=$(git symbolic-ref --short HEAD 2>/dev/null)
localBranches=($(git for-each-ref --format='%(refname:short)' refs/heads/))
branchCount=${#localBranches[@]}

# Ensure inside a git repo
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo -e "${RED}❌ Not a Git repository. Aborting.${NC}"
  exit 1
fi

if [ "$1" == "git-pull-all" ]; then
  #if ! git diff --quiet || ! git diff --cached --quiet; then
  #  echo -e "${YELLOW}💾 Stashing local changes...${NC}"
  #  stashRef=$(git stash create)
  #  if [ -n "$stashRef" ]; then
  #    git stash store -m "$STASH_MESSAGE" "$stashRef"
  #  fi
  #fi
  echo -e "${GREEN}📡 Fetching all remotes...${NC}"
  if ! git fetch --all --prune; then
    echo -e "${RED}❌ Error: Failed to fetch remotes. Check your network or remote URLs.${NC}"
    exit 1
  fi
  if [ -z "$currentBranch" ]; then
    echo -e "${RED}❌ Not on a valid branch (detached HEAD?). Aborting.${NC}"
    exit 1
  fi
  echo -e "${GREEN}🔄 Pulling current branch: ${YELLOW}$currentBranch${NC}"
  if git rev-parse --abbrev-ref --symbolic-full-name @{u} > /dev/null 2>&1; then
    if ! git pull origin "$currentBranch"; then
      echo -e "${RED}❌ Failed to pull branch '$currentBranch'. Resolve any conflicts manually.${NC}"
      exit 1
    fi
  else
    echo -e "${YELLOW}⚠️  Current branch '$currentBranch' has no upstream. Skipping pull.${NC}"
  fi
  if [ "$branchCount" -gt 1 ]; then
    for branch in "${localBranches[@]}"; do
      if [ "$branch" != "$currentBranch" ]; then
        echo -e "${GREEN}➡️  Switching to branch: ${YELLOW}$branch${NC}"
        if ! git checkout "$branch"; then
          echo -e "${RED}❌ Failed to checkout branch '$branch'.${NC}"
          exit 1
        fi
        if git rev-parse --abbrev-ref --symbolic-full-name @{u} > /dev/null 2>&1; then
          echo -e "${GREEN}🔄 Pulling latest changes for branch: ${YELLOW}$branch${NC}"
          if ! git pull origin "$branch"; then
            echo -e "${RED}❌ Failed to pull branch '$branch'.${NC}"
            exit 1
          fi
        else
          echo -e "${YELLOW}⚠️  Branch '$branch' has no upstream. Skipping pull.${NC}"
        fi
      fi
    done
    echo -e "${GREEN}🔁 Returning to original branch: ${YELLOW}$currentBranch${NC}"
    git checkout "$currentBranch"
  fi
  #if git stash list | grep -q "$STASH_MESSAGE"; then
  #  echo -e "${YELLOW}📦 Re-applying stashed changes...${NC}"
  #  if ! git stash apply; then
  #    echo -e "${RED}❌ Conflicts while applying stashed changes. Please resolve manually.${NC}"
  #    echo -e "${YELLOW}🔎 Stash still available with label: '${STASH_MESSAGE}'${NC}"
  #    exit 1
  #  else
  #    git stash drop
  #  fi
  #fi
  echo -e "${GREEN}✅ Pull process completed successfully.${NC}"

elif [ "$1" == "git-pull-simple" ]; then
  echo -e "${GREEN}📡 Fetching all remotes...${NC}"
  if ! git fetch --all --prune; then
    echo -e "${RED}❌ Error: Failed to fetch remotes. Check your network or remote URLs.${NC}"
    exit 1
  fi
  if [ -z "$currentBranch" ]; then
    echo -e "${RED}❌ Not on a valid branch (detached HEAD?). Aborting.${NC}"
    exit 1
  fi
  echo -e "${GREEN}🔄 Pulling current branch: ${YELLOW}$currentBranch${NC}"
  if git rev-parse --abbrev-ref --symbolic-full-name @{u} > /dev/null 2>&1; then
    if ! git pull origin "$currentBranch"; then
      echo -e "${RED}❌ Failed to pull branch '$currentBranch'. Resolve any conflicts manually.${NC}"
      exit 1
    fi
  else
    echo -e "${YELLOW}⚠️  Current branch '$currentBranch' has no upstream. Skipping pull.${NC}"
  fi
  echo -e "${GREEN}✅ Pull completed on branch '${YELLOW}$currentBranch${GREEN}'.${NC}"

elif [ "$1" == "prune-local" ]; then
  if [ "$branchCount" -gt 1 ]; then
    echo -e "${YELLOW}🧹 Cleaning up local branches except '${currentBranch}'...${NC}"
    for branch in "${localBranches[@]}"; do
      if [ "$branch" != "$currentBranch" ]; then
        echo -e "${GREEN}🗑️  Deleting local branch: ${YELLOW}$branch${NC}"
        if ! git branch -D "$branch"; then
          echo -e "${RED}❌ Failed to delete branch '$branch'.${NC}"
        fi
      fi
    done
  else
    echo -e "${GREEN}✅ Nothing to prune. Only one local branch '${currentBranch}' found.${NC}"
  fi

elif [ "$1" == "git-amend" ]; then
  if [ -z "$currentBranch" ]; then
    echo "❌ Could not determine the current branch."
    exit 1
  fi
  if git diff --quiet && git diff --cached --quiet; then
    echo -e "${YELLOW}ℹ️ No pending changes to commit. Nothing to amend.${NC}"
    exit 0
  fi
  read -p "⚠️ Are you sure you want to force-push the amended commit? (Y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo -e "${YELLOW}❌ Aborted by user.${NC}"
    exit 1
  fi
  if ! git add .; then
    echo -e "${RED}❌ Failed to stage files with 'git add'. Check for invalid files or permissions.${NC}"
  exit 1
  fi
  if ! git commit --amend --no-edit; then
    echo -e "${RED}❌ Failed to amend the last commit. Ensure you have a commit to amend.${NC}"
  exit 1
  fi
  if ! git push origin "$currentBranch" --force; then
    echo -e "${RED}❌ Failed to push changes. Verify your remote or permissions.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✅ Amend and force-push completed successfully on branch '${YELLOW}$currentBranch${GREEN}'.${NC}"

elif [ "$1" == "ignore-files" ]; then
  git ls-files -m | grep -E '\.java$|\.sh$' | xargs git update-index --assume-unchanged

elif [ "$1" == "view-ignored-files" ]; then
  git ls-files -v | grep '^[a-z]'

elif [ "$1" == "view-files-to-ignored" ]; then
  git ls-files -m | grep -E '\.java$|\.sh$'

fi
