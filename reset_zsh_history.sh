#!/bin/zsh
# Script to clean zsh history and add custom commands

echo "[reset_zsh_history] Cleaning history file..."
truncate -s 0 ~/.zsh_history
echo "[reset_zsh_history] History file cleaned."

echo "[reset_zsh_history] Preparing default commands..."
default_commands=(
  'check-maven-java-version'
  'clean-build-artifacts'
  'mvn spotless:apply'
  'mvn compile'
  'check-maven-java-version && clean-build-artifacts && mvn spotless:apply && mvn compile'
  'mvn clean install -DskipTests'
  'mvn test'
  'update-mac-all'
  'force-quit'
  'git-amend'
  'git-ignore-files'
  'git-prune-local'
  'git-sync-all'
  'git-sync-simple'
  'git-view-files-to-ignored'
  'git-view-ignored-files'
  'batch-repo-maintenance'
  'clean-build-artifacts'
  'maven-deps-manager'
)

# Write commands directly to ~/.zsh_history in zsh format
echo "[reset_zsh_history] Adding commands to history file..."
for cmd in "${default_commands[@]}"; do
  # Write in extended history format: : <epoch>:0;<command>
  echo ": $(date +%s):0;$cmd" >> ~/.zsh_history
done
echo "[reset_zsh_history] Commands added to history file."

echo "[reset_zsh_history] zsh history cleaned and commands added."