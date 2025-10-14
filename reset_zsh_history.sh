#!/bin/zsh
# Script to clean zsh history and add custom commands

echo "[reset_zsh_history] Cleaning history file..."
truncate -s 0 ~/.zsh_history
echo "[reset_zsh_history] History file cleaned."

echo "[reset_zsh_history] Preparing default commands..."
default_commands=(
  '$HOME/.code-puppy-venv/bin/code-puppy -i'
  'batch-repo-maintenance'
  'check-maven-java-version && clean-build-artifacts && mvnp spotless:apply && mvnp compile'
  'check-maven-java-version'
  'clean-build-artifacts'
  'clean-build-artifacts'
  'cleanup-maven-wrapper'
  'code-puppy -i'
  'force-quit'
  'git-amend'
  'git-ignore-files'
  'git-prune-local'
  'git-sync-all'
  'git-sync-simple'
  'git-view-files-to-ignored'
  'git-view-ignored-files'
  'maven-deps-manager'
  'mvnp clean -U install -DskipTests'
  'mvnp compile'
  'mvnp spotless:apply'
  'mvnp test'
  'update-mac-all'
)

# Write commands directly to ~/.zsh_history in zsh format
echo "[reset_zsh_history] Adding commands to history file..."
for cmd in "${default_commands[@]}"; do
  # Write in extended history format: : <epoch>:0;<command>
  echo ": $(date +%s):0;$cmd" >> ~/.zsh_history
done
echo "[reset_zsh_history] Commands added to history file."

echo "[reset_zsh_history] zsh history cleaned and commands added."