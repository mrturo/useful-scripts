#!/bin/bash
# Git utility functions for common repository operations
# Provides functions to manage git branches, stash changes, pull updates, and clean repositories
# Usage: Source this file or call specific functions directly

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

STASH_MESSAGE="auto-stash-before-pull-script"
stashRef=""

# --- Helpers ---------------------------------------------------------------

# Unset common environment variables for HTTP/HTTPS proxies (both lower and upper case)
unset_http_proxies() {
  echo "Network proxy: unset HTTP(S) 🌐"
  local vars=(http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY)
  for v in "${vars[@]}"; do
    if [[ -n "${!v-}" ]]; then
      echo "Unsetting ${v} → ${!v}"
      unset "${v}"
    else
      echo "${v} not set"
    fi
  done
}

# isGitRepo: ensure we are inside a git repo
isGitRepo() {
  git rev-parse --is-inside-work-tree > /dev/null 2>&1
}

# hasUncommittedChanges: returns 0 if there are pending changes (unstaged or staged)
hasUncommittedChanges() {
  # Any output in porcelain means pending work
  [ -n "$(git status --porcelain 2>/dev/null)" ]
}

# branchHasUpstream BRANCH: returns 0 if branch has upstream
branchHasUpstream() {
  local br="$1"
  git rev-parse --abbrev-ref --symbolic-full-name "${br}@{u}" >/dev/null 2>&1
}

# branchAheadOfUpstream BRANCH: returns 0 if BRANCH has local commits not pushed
branchAheadOfUpstream() {
  local br="$1"
  if ! branchHasUpstream "$br"; then
    return 2  # No upstream configured
  fi
  # rev-list: left is upstream-only, right is branch-only
  local counts
  counts=$(git rev-list --left-right --count "${br}@{u}...${br}" 2>/dev/null) || return 1
  # Format: "<behind> <ahead>"
  local behind ahead
  behind=$(echo "$counts" | awk '{print $1}')
  ahead=$(echo "$counts"  | awk '{print $2}')
  [ "${ahead:-0}" -gt 0 ]
}

# preflightCurrentBranch: block if dirty or ahead (not pushed)
preflightCurrentBranch() {
  local br="$1"
  # 1) Working tree/staging must be clean
  if hasUncommittedChanges; then
    echo -e "${RED}❌ There are uncommitted changes in the working directory or staging area. Aborting.${NC}"
    echo -e "${YELLOW}ℹ️  Suggestion: check 'git status', commit or stash your changes, then try again.${NC}"
    return 1
  fi
  # 2) No unpushed local commits
  if branchAheadOfUpstream "$br"; then
    echo -e "${RED}❌ Branch '${YELLOW}$br${RED}' has local commits that haven't been pushed yet. Aborting.${NC}"
    echo -e "${YELLOW}ℹ️  Suggestion: 'git push origin ${br}' and try again.${NC}"
    return 1
  elif [ $? -eq 2 ]; then
    echo -e "${RED}❌ Branch '${YELLOW}$br${RED}' has no upstream configured. Aborting.${NC}"
    echo -e "${YELLOW}ℹ️  Configure upstream: 'git push -u origin ${br}'.${NC}"
    return 1
  fi
  return 0
}

# preflightAllBranches: for git-pull-all, ensure no branch is ahead
preflightAllBranches() {
  local branches=("$@")
  local aheadList=()
  local noUpstreamList=()
  for br in "${branches[@]}"; do
    if branchAheadOfUpstream "$br"; then
      aheadList+=("$br")
    elif [ $? -eq 2 ]; then
      noUpstreamList+=("$br")
    fi
  done

  if [ ${#aheadList[@]} -gt 0 ] || [ ${#noUpstreamList[@]} -gt 0 ]; then
    [ ${#aheadList[@]} -gt 0 ] && \
      echo -e "${RED}❌ These branches have unpushed local commits:${NC} ${YELLOW}${aheadList[*]}${NC}"
    [ ${#noUpstreamList[@]} -gt 0 ] && \
      echo -e "${RED}❌ These branches have no upstream configured:${NC} ${YELLOW}${noUpstreamList[*]}${NC}"
    echo -e "${YELLOW}ℹ️  Fix with 'git push -u origin <branch>' or push pending commits and try again.${NC}"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------

currentBranch=$(git symbolic-ref --short HEAD 2>/dev/null)
localBranches=($(git for-each-ref --format='%(refname:short)' refs/heads/))
branchCount=${#localBranches[@]}

# Ensure inside a git repo
if ! isGitRepo; then
  echo -e "${RED}❌ Not a Git repository. Aborting.${NC}"
  exit 1
fi

unset_http_proxies

# Commands ------------------------------------------------------------------
if [ "$1" == "git-pull-all" ]; then
  # Preflight: current branch must be clean and not ahead
  if ! preflightCurrentBranch "$currentBranch"; then
    exit 1
  fi
  # Preflight: ensure no local branch is ahead or missing upstream
  if ! preflightAllBranches "${localBranches[@]}"; then
    exit 1
  fi

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
    if ! git pull --ff-only origin "$currentBranch"; then
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
          if ! git pull --ff-only origin "$branch"; then
            echo -e "${RED}❌ Failed to pull branch '$branch'.${NC}"
            exit 1
          fi
        else
          echo -e "${YELLOW}⚠️  Branch '$branch' has no upstream. Skipping pull.${NC}"
        fi
      fi
    done
    echo -e "${GREEN}🔁 Returning to original branch: ${YELLOW}$currentBranch${NC}"
    git checkout "$currentBranch" >/dev/null 2>&1
  fi
  echo -e "${GREEN}✅ Pull process completed successfully.${NC}"
elif [ "$1" == "git-merge" ]; then
  # Check that the target branch is provided
  if [ -z "$2" ]; then
    echo -e "${RED}❌ You must specify the branch to merge. Usage: ./git_util.sh git-merge <branch>${NC}"
    exit 1
  fi

  targetBranch="$2"
  echo -e "${GREEN}🔀 You are currently on branch:${NC} ${YELLOW}$currentBranch${NC}"
  echo -e "${GREEN}🔀 You will merge changes from branch:${NC} ${YELLOW}$targetBranch${NC}"

  # Validate that the branches are different
  if [ "$currentBranch" == "$targetBranch" ]; then
    echo -e "${RED}❌ The current branch and the branch to merge must be different. Aborting.${NC}"
    exit 1
  fi

  # Preflight: working tree must be clean
  if hasUncommittedChanges; then
    echo -e "${RED}❌ There are uncommitted changes in the working directory or staging area. Aborting merge.${NC}"
    echo -e "${YELLOW}ℹ️  Suggestion: commit or stash your changes, then try again.${NC}"
    exit 1
  fi

  # Check if target branch exists locally or remotely
  if git show-ref --verify --quiet refs/heads/"$targetBranch"; then
    echo -e "${GREEN}✅ Target branch exists locally: ${YELLOW}$targetBranch${NC}"
  elif git ls-remote --exit-code --heads origin "$targetBranch" >/dev/null 2>&1; then
    echo -e "${YELLOW}⬇️  Target branch not found locally. Checking out from remote...${NC}"
    if ! git fetch origin "$targetBranch":"$targetBranch"; then
      echo -e "${RED}❌ Failed to fetch branch '$targetBranch' from remote.${NC}"
      exit 1
    fi
  else
    echo -e "${RED}❌ Target branch '$targetBranch' does not exist locally or on remote. Aborting.${NC}"
    exit 1
  fi

  # Merge target branch into current branch
  echo -e "${GREEN}🔀 Merging branch '${YELLOW}$targetBranch${GREEN}' into '${YELLOW}$currentBranch${GREEN}'...${NC}"
  if git merge --no-ff "$targetBranch"; then
    echo -e "${GREEN}✅ Merge completed successfully.${NC}"
  else
    echo -e "${RED}❌ Merge failed. Please resolve conflicts and commit manually.${NC}"
    exit 1
  fi
elif [ "$1" == "git-pull-simple" ]; then
  # Preflight: current branch must be clean and not ahead
  if ! preflightCurrentBranch "$currentBranch"; then
    exit 1
  fi

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
    if ! git pull --ff-only origin "$currentBranch"; then
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
    echo -e "${YELLOW}ℹ️  No pending changes to commit. Nothing to amend.${NC}"
    exit 0
  fi
  read -p "⚠️  Are you sure you want to force-push the amended commit? (Y/N): " confirm
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