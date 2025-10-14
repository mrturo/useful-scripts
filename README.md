# DEFINICIÓN DE ALIAS
code ~/.zshrc
source ~/.zshrc

# Alias definidos en .zshrc
alias git-sync-all="$HOME/Documents/scripts/git_util.sh git-pull-all"
alias git-sync-simple="$HOME/Documents/scripts/git_util.sh git-pull-simple"
alias git-prune-local="$HOME/Documents/scripts/git_util.sh prune-local"
alias git-amend="$HOME/Documents/scripts/git_util.sh git-amend"
alias git-ignore-files="$HOME/Documents/scripts/git_util.sh ignore-files"
alias git-view-ignored-files="$HOME/Documents/scripts/git_util.sh view-ignored-files"
alias git-view-files-to-ignored="$HOME/Documents/scripts/git_util.sh view-files-to-ignored"
alias update_mac_all="$HOME/Documents/scripts/update_mac_all.sh"
alias mac_maint="$HOME/Documents/scripts/mac_maint.sh --verify --clean-caches=all --reindex-spotlight"
alias repos-clean="$HOME/Documents/scripts/mvn-repos-clean-and-m2-prune.sh /Users/a0a11b7/Documents/reps-walmart /Users/a0a11b7/Documents/reps-personal --deep --audit-m2 --clean-global-caches"