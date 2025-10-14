# Useful Scripts

Collection of useful scripts for macOS system maintenance, Git repository management, and development.

## Available Scripts

### System Maintenance
- **`force_quit.sh`** - Force quit applications
- **`free_port.sh`** - Free an occupied port
- **`mac_maint.sh`** - General macOS system maintenance (cache cleaning, Spotlight reindexing)
- **`update_mac_all.sh`** - Complete system update (Homebrew, packages, etc.)
- **`reset_zsh_history.sh`** - Cleans your zsh command history and repopulates it with a custom set of useful commands.
- **`unset_proxies.sh`** - Unsets HTTP(S) proxy environment variables (http_proxy, https_proxy, all_proxy, no_proxy, etc.)

### Git & Repositories
- **`git_util.sh`** - Git utilities (amend, ignore, prune, sync, merge, etc.)

#### Notable Commands in `git_util.sh`

- `git-amend` – Amend the last commit and force-push to remote.
- `git-ignore-files` – Mark .java and .sh files as "assume unchanged" in git index.
- `git-prune-local` – Delete all local branches except the current one.
- `git-sync-all` – Pull all branches from remote, ensuring no uncommitted or unpushed changes.
- `git-sync-simple` – Pull only the current branch from remote.
- `git-merge <branch>` – Merge the specified branch into the current branch. If the branch does not exist locally, it will be checked out from remote and merged. Simple conflicts will be resolved automatically; for complex conflicts, manual resolution may be required.

### Development
- **`batch_repo_maintenance.sh`** - Batch maintenance for multiple repositories
- **`clean_build_artifacts.sh`** - Clean build artifacts generated during software development
- **`check_maven_java_version.sh`** - Checks and syncs Java version between Maven pom.xml and .java-version file, and generates/updates Maven wrapper
- **`cleanup_maven_wrapper.sh`** - Removes Maven wrapper configuration (mvnw, .mvn/, .java-version) and reverts uncommitted changes created by check_maven_java_version.sh
- **`firebase_emul.sh`** - Starts the Firebase emulator and opens the UI, automatically detecting the port
- **`mvn_proxy.sh`** - Maven Wrapper proxy that automatically uses ./mvnw when available or creates it when needed
- **`maven_deps_manager.sh`** - Comprehensive Maven dependencies management:
  - **Automatically runs cleanup_maven_wrapper.sh** at the start to remove uncommitted Maven wrapper files
  - Scans git repositories for Maven projects (pom.xml files)
  - Extracts dependencies using Maven dependency:tree (transitive) or XML parsing (direct)
  - Generates CSV reports of used and unused dependencies
  - Analyzes local .m2 repository and identifies unused artifacts
  - Safely cleans up unused dependencies with multiple protection strategies
  - Tracks Maven downloads and protects core infrastructure
  - Supports report caching and execution frequency control
  - Modular design with reusable utility functions

## Alias Configuration

To make these scripts easier to use, it's recommended to configure aliases in your `~/.zshrc` file.

### How to Edit .zshrc

```bash
# Open the configuration file
code ~/.zshrc

# After saving changes, reload the configuration
source ~/.zshrc
```

### Recommended Aliases

Add the following lines to your `~/.zshrc` file:

```bash
# System Maintenance
alias force-quit="$HOME/Documents/scripts/force_quit.sh"
alias mac-maint="$HOME/Documents/scripts/mac_maint.sh --verify --clean-caches=all --reindex-spotlight"
alias update-mac-all="$HOME/Documents/scripts/update_mac_all.sh"
alias reset-zsh-history="$HOME/Documents/scripts/reset_zsh_history.sh"
alias unset-proxies="source $HOME/Documents/scripts/unset_proxies.sh"

# Git & Repositories
alias git-amend="$HOME/Documents/scripts/git_util.sh git-amend"
alias git-ignore-files="$HOME/Documents/scripts/git_util.sh ignore-files"
alias git-prune-local="$HOME/Documents/scripts/git_util.sh prune-local"
alias git-sync-all="$HOME/Documents/scripts/git_util.sh git-pull-all"
alias git-sync-simple="$HOME/Documents/scripts/git_util.sh git-pull-simple"
alias git-merge="$HOME/Documents/scripts/git_util.sh git-merge"
alias git-view-files-to-ignored="$HOME/Documents/scripts/git_util.sh view-files-to-ignored"
alias git-view-ignored-files="$HOME/Documents/scripts/git_util.sh view-ignored-files"

# Development
alias batch-repo-maintenance="$HOME/Documents/scripts/batch_repo_maintenance.sh"
alias clean-build-artifacts="$HOME/Documents/scripts/clean_build_artifacts.sh"
alias check-maven-java-version="$HOME/Documents/scripts/check_maven_java_version.sh"
alias cleanup-maven-wrapper="$HOME/Documents/scripts/cleanup_maven_wrapper.sh"
alias firebase-emul="$HOME/Documents/scripts/firebase_emul.sh"
alias mvnp="$HOME/Documents/scripts/mvn_proxy.sh"
alias maven-deps-manager="$HOME/Documents/scripts/maven_deps_manager.sh --delete-unused"
```

## Usage

Once the aliases are configured, you can execute the scripts by simply typing the alias name in your terminal:

```bash
# Examples
mac-maint             # Run system maintenance
git-sync-all          # Sync all repositories
maven-deps-manager    # Manage Maven dependencies
```