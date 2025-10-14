#!/bin/zsh
# Script to clean zsh history and add custom commands

echo "[reset_zsh_history] Cleaning history file..."
truncate -s 0 ~/.zsh_history
echo "[reset_zsh_history] History file cleaned."

echo "[reset_zsh_history] Preparing default commands..."
default_commands=(
  'bash envtool.sh clean-cache'
  'bash envtool.sh clean-env'
  'bash envtool.sh code-check'
  'bash envtool.sh execute'
  'bash envtool.sh install dev'
  'bash envtool.sh install prod'
  'bash envtool.sh mutation-check'
  'bash envtool.sh quality-gate'
  'bash envtool.sh reinstall dev'
  'bash envtool.sh reinstall prod'
  'bash envtool.sh run'
  'bash envtool.sh start'
  'bash envtool.sh status'
  'bash envtool.sh test'
  'bash envtool.sh uninstall'
  'bash envtool.sh update-deps'
  'batch-repo-maintenance'
  'caffeinate -d -m -- $HOME/.code-puppy-venv/bin/code-puppy -i'
  'caffeinate -d -m -- zsh -c "source $HOME/Documents/scripts/unset_proxies.sh; gh copilot"'
  'check-maven-java-version && clean-build-artifacts && mvnp spotless:apply && mvnp compile'
  'check-maven-java-version && clean-build-artifacts'
  'check-maven-java-version'
  'clean-build-artifacts'
  'cleanup-maven-wrapper'
  'firebase-emul'
  'force-quit'
  'git-amend'
  'git-ignore-files'
  'git-prune-local'
  'git-sync-all'
  'git-sync-simple'
  'git-view-files-to-ignored'
  'git-view-ignored-files'
  'mac-maint'
  'maven-deps-manager'
  'mvnp clean -U install -DskipTests'
  'mvnp compile'
  'mvnp spotless:apply'
  'mvnp test'
  'mvnp test jacoco:report'
  'unset-proxies'
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