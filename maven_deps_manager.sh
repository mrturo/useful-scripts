#!/bin/bash
# Maven Dependencies Manager
#
# This script provides comprehensive Maven dependency management across git repositories:
#
# CORE FUNCTIONALITY:
# 1. Detect Java/Maven projects (repositories containing pom.xml files)
# 2. Scan all pom.xml files in each repository (including subdirectories)
# 3. Extract dependencies using two methods:
#    - Maven dependency:tree (complete with transitive dependencies)
#    - XML parsing with xmllint (fast, direct dependencies only)
# 4. Extract and list all Maven plugins and their dependencies
# 5. Generate CSV reports of used and unused dependencies (sorted, no duplicates)
# 6. Track Maven downloads during analysis (to avoid deleting necessary artifacts)
# 7. Analyze local .m2 repository to identify unused dependencies
# 8. Compare installed vs used dependencies with detailed statistics
# 9. Identify and protect Maven core dependencies (auto-detected from Maven installation)
# 10. Clean up unused dependencies from .m2 repository with multiple safety strategies
#
# MODULAR DESIGN:
# - extract_dependency_from_path(): Parse dependency info from file paths
# - is_valid_repository(): Validate git repositories
# - add_repository_if_new(): Prevent duplicate repository scanning
# - clean_empty_dirs(): Recursively clean empty directories after deletion
# - get_dir_size_kb() & format_size(): Calculate and format disk space
# - delete_dependency(): Safely delete dependencies with cleanup
# - count_remaining_deps(): Track deletion progress
#
# SAFETY FEATURES:
# - Keep latest version of each artifact (configurable)
# - Exclude Maven plugins from deletion (configurable)
# - Protect Maven core dependencies (auto-detected)
# - Multiple deletion passes for thorough cleanup
# - Execution frequency control to prevent unnecessary runs
# - Report caching to avoid redundant scans
#
# OPTIMIZATION:
# - Repository scanning prioritization (most POMs first)
# - Multi-module Maven project detection
# - Parallel repository discovery
# - Cached report reuse within configurable time window
# - Progress tracking and reporting
#
# Usage: ./maven_deps_manager.sh [OPTIONS] [REPOSITORIES...]
#   --without-transitive: Use fast XML parsing (direct dependencies only)
#   --delete-unused: Clean up unused dependencies from .m2 repository
#   --force: Force execution even if minimum days haven't passed
#   REPOSITORIES: Specific repository paths to scan (optional)

# Unset proxy variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/unset_proxies.sh" 2>/dev/null || true
set -euo pipefail

# Function to display help
show_help() {
  cat << EOF
Maven Dependencies Scanner
==========================

This script scans git repositories to extract and list all Maven dependencies.

USAGE:
  ./maven_deps_manager.sh [OPTIONS] [REPOSITORIES...]

OPTIONS:
  --without-transitive Include only direct dependencies using XML parsing (faster but incomplete)
  --delete-unused     Delete unused dependencies from .m2 repository (requires confirmation)
  --force             Force execution even if minimum days haven't passed
  --help              Show this help message

ARGUMENTS:
  REPOSITORIES        Optional: Specific repository paths to scan (absolute paths)
                      If not provided, scans all configured default directories

EXAMPLES:
  # Scan all configured repositories (default - includes transitive dependencies)
  ./maven_deps_manager.sh

  # Scan all configured repositories without transitive dependencies (fast mode)
  ./maven_deps_manager.sh --without-transitive

  # Scan and delete unused dependencies (with confirmation)
  ./maven_deps_manager.sh --delete-unused

  # Scan specific repository
  ./maven_deps_manager.sh /path/to/my-project

  # Scan multiple repositories without transitive dependencies
  ./maven_deps_manager.sh --without-transitive /path/to/project1 /path/to/project2

CONFIGURATION:
  Edit the script to configure default directories:
    - DEFAULT_DIR1: First base directory to scan
    - DEFAULT_DIR2: Second base directory to scan
 
  Deletion safety settings (recommended to keep enabled):
    - KEEP_LATEST_VERSION: Keep newest version of each artifact (default: true)
    - EXCLUDE_MAVEN_PLUGINS: Never delete Maven plugins (default: true)

OUTPUT:
  CSV report saved to: $HOME/Documents/scripts/.maven_deps_report_used.csv
  Format: Dependency,Version (alphabetically sorted, no duplicates)

EOF
  exit 0
}

# === UTILITY FUNCTIONS ===

# Extract dependency information from Maven path
# Args: $1 = jar file path, $2 = M2_REPO path
# Output: group_id:artifact_id,version
extract_dependency_from_path() {
  local jar_file="$1"
  local m2_repo="$2"
  local relative_path="${jar_file#$m2_repo/}"
 
  local version_dir=$(dirname "$relative_path")
  local version=$(basename "$version_dir")
  local artifact_dir=$(dirname "$version_dir")
  local artifact_id=$(basename "$artifact_dir")
  local group_path=$(dirname "$artifact_dir")
  local group_id=$(echo "$group_path" | tr '/' '.')
 
  if [ -n "$group_id" ] && [ -n "$artifact_id" ] && [ -n "$version" ]; then
    if [[ ! "$version" =~ maven-metadata ]] && [[ ! "$(basename "$jar_file")" =~ ^_remote\.repositories$ ]]; then
      if [[ ! "$version" =~ SNAPSHOT ]] && [[ ! "$version" =~ [\[\(] ]]; then
        echo "$group_id:$artifact_id,$version"
        return 0
      fi
    fi
  fi
  return 1
}

# Check if a repository is valid (exists and is a git repo)
# Args: $1 = repository path
# Returns: 0 if valid, 1 otherwise
is_valid_repository() {
  local repo_path="$1"
  [ -d "$repo_path" ] && [ -d "$repo_path/.git" ]
}

# Add repository to list if not already present
# Args: $1 = repository path, $2 = array name (passed by reference)
add_repository_if_new() {
  local repo_path="$1"
  local array_name="$2"
 
  # Use eval to access array by name (compatible with older bash/zsh)
  # Check if array has elements to avoid unbound variable error
  local array_size
  array_size=$(eval "echo \${#${array_name}[@]}")
 
  if [ "$array_size" -gt 0 ]; then
    eval "local existing_repos=(\"\${${array_name}[@]}\")"
   
    for existing in "${existing_repos[@]}"; do
      if [ "$existing" = "$repo_path" ]; then
        return 1  # Already exists
      fi
    done
  fi
 
  eval "${array_name}+=('$repo_path')"
  return 0  # Added
}

# Clean up empty parent directories
# Args: $1 = directory path, $2 = stop path (don't delete this or parents)
clean_empty_dirs() {
  local dir_path="$1"
  local stop_path="$2"
 
  while [ "$dir_path" != "$stop_path" ] && [ -d "$dir_path" ]; do
    if [ -z "$(ls -A "$dir_path" 2>/dev/null)" ]; then
      rm -rf "$dir_path" 2>/dev/null || break
      dir_path=$(dirname "$dir_path")
    else
      break
    fi
  done
}

# Calculate size of a directory in KB
# Args: $1 = directory path
# Output: size in KB
get_dir_size_kb() {
  local dir_path="$1"
  if [ -d "$dir_path" ]; then
    du -sk "$dir_path" 2>/dev/null | cut -f1
  else
    echo "0"
  fi
}

# Convert KB to human-readable format
# Args: $1 = size in KB
# Output: formatted size string
format_size() {
  local size_kb="$1"
  if [ $size_kb -ge 1048576 ]; then
    awk "BEGIN {printf \"%.2f GB\", $size_kb/1048576}"
  elif [ $size_kb -ge 1024 ]; then
    awk "BEGIN {printf \"%.2f MB\", $size_kb/1024}"
  else
    echo "${size_kb} KB"
  fi
}

# Delete a dependency from .m2 repository
# Args: $1 = dependency (groupId:artifactId), $2 = version, $3 = M2_REPO path
# Returns: 0 if deleted, 1 otherwise
delete_dependency() {
  local dependency="$1"
  local version="$2"
  local m2_repo="$3"
 
  if [[ "$dependency" =~ ^([^:]+):(.+)$ ]]; then
    local group_id="${BASH_REMATCH[1]}"
    local artifact_id="${BASH_REMATCH[2]}"
    local group_path=$(echo "$group_id" | tr '.' '/')
    local dep_path="$m2_repo/$group_path/$artifact_id/$version"
   
    if [ -d "$dep_path" ]; then
      if rm -rf "$dep_path" 2>/dev/null; then
        # Clean up empty parent directories
        local artifact_path="$m2_repo/$group_path/$artifact_id"
        clean_empty_dirs "$artifact_path" "$m2_repo"
        clean_empty_dirs "$m2_repo/$group_path" "$m2_repo"
        return 0
      fi
    fi
  fi
  return 1
}

# Count dependencies remaining in file that still exist in .m2
# Args: $1 = CSV file path, $2 = M2_REPO path
# Output: count of remaining dependencies
count_remaining_deps() {
  local csv_file="$1"
  local m2_repo="$2"
  local count=0
 
  while IFS=',' read -r dependency version; do
    [ "$dependency" = "Dependency" ] && continue
   
    if [[ "$dependency" =~ ^([^:]+):(.+)$ ]]; then
      local group_id="${BASH_REMATCH[1]}"
      local artifact_id="${BASH_REMATCH[2]}"
      local group_path=$(echo "$group_id" | tr '.' '/')
      local dep_path="$m2_repo/$group_path/$artifact_id/$version"
     
      [ -d "$dep_path" ] && ((count++))
    fi
  done < "$csv_file"
 
  echo "$count"
}

# === CONFIGURE YOUR BASE DIRECTORIES AND SPECIFIC REPOS HERE ===
DEFAULT_DIR1="$HOME/Documents/reps-personal"
DEFAULT_DIR2="$HOME/Documents/reps-walmart"
BASE_DIRS=("$DEFAULT_DIR1" "$DEFAULT_DIR2")

# Specific repositories to scan (direct paths to individual repos)
REPO1="$HOME/Documents/scripts"
SPECIFIC_REPOS_CONFIG=("$REPO1")

# === CONFIGURE DELETION ATTEMPTS ===
# Maximum number of deletion attempts when using --delete-unused
MAX_DELETION_ATTEMPTS=3

# === CONFIGURE DELETION STRATEGY ===
# Control what gets deleted to avoid removing dependencies still in use
# KEEP_LATEST_VERSION: Keep the most recent version of each artifact (true/false)
# This prevents deleting old versions that might still be used by unscanned projects
KEEP_LATEST_VERSION=true

# EXCLUDE_MAVEN_PLUGINS: Never delete Maven plugins (true/false)
# Plugins are often used globally and not always visible in dependency trees
EXCLUDE_MAVEN_PLUGINS=true

# === CONFIGURE EXECUTION FREQUENCY ===
# Minimum days between executions (0 to disable check)
MIN_DAYS_BETWEEN_RUNS=7

# === CONFIGURE REPORT CACHE ===
# Maximum age in days for cached used dependencies report (0 to always scan)
# If report is newer than this, skip repository scanning and reuse it
MAX_REPORT_AGE_DAYS=1

# Parse command line arguments
USE_MAVEN=true
SPECIFIC_REPOS=()
DELETE_UNUSED=false
FORCE_RUN=false

for arg in "$@"; do
  if [[ "$arg" == "--help" ]] || [[ "$arg" == "-h" ]]; then
    show_help
  elif [[ "$arg" == "--without-transitive" ]]; then
    USE_MAVEN=false
  elif [[ "$arg" == "--delete-unused" ]]; then
    DELETE_UNUSED=true
  elif [[ "$arg" == "--force" ]]; then
    FORCE_RUN=true
  elif [[ -d "$arg" ]] || [[ -d "$arg/.git" ]]; then
    # It's a directory path (repository)
    SPECIFIC_REPOS+=("$arg")
  else
    echo "⚠️  Warning: '$arg' is not a valid directory, skipping"
  fi
done

if [ "$USE_MAVEN" = true ]; then
  echo "⚙️  Mode: Including transitive dependencies (complete analysis)"
  echo "💡 Tip: Use --without-transitive for faster direct-only scanning"
else
  echo "⚙️  Mode: Direct dependencies only (fast but incomplete)"
fi

# Build complete list of repositories to scan
REPOS_TO_SCAN=()

# Priority 1: Command line arguments
if [ ${#SPECIFIC_REPOS[@]} -gt 0 ]; then
  echo "🎯 Adding specific repositories from command line (${#SPECIFIC_REPOS[@]} provided)..."
  for REPO_PATH in "${SPECIFIC_REPOS[@]}"; do
    if ! is_valid_repository "$REPO_PATH"; then
      if [ ! -d "$REPO_PATH" ]; then
        echo "   ⚠️  Repository not found: $REPO_PATH"
      else
        echo "   ⚠️  Not a git repository: $REPO_PATH"
      fi
      continue
    fi
   
    REPOS_TO_SCAN+=("$REPO_PATH")
    echo "   ✓ Added: $(basename "$REPO_PATH")"
  done
  echo ""
fi

# Priority 2: Configured specific repositories
if [ ${#SPECIFIC_REPOS_CONFIG[@]} -gt 0 ]; then
  echo "📦 Adding configured specific repositories (${#SPECIFIC_REPOS_CONFIG[@]} configured)..."
  for REPO_PATH in "${SPECIFIC_REPOS_CONFIG[@]}"; do
    if ! is_valid_repository "$REPO_PATH"; then
      if [ ! -d "$REPO_PATH" ]; then
        echo "   ⚠️  Repository not found: $REPO_PATH"
      else
        echo "   ⚠️  Not a git repository: $REPO_PATH"
      fi
      continue
    fi
   
    if add_repository_if_new "$REPO_PATH" REPOS_TO_SCAN; then
      echo "   ✓ Added: $(basename "$REPO_PATH")"
    else
      echo "   ⏭️  Already added: $(basename "$REPO_PATH")"
    fi
  done
  echo ""
fi

# Priority 3: Base directories (scan unless only specific repos from CLI were provided)
if [ ${#SPECIFIC_REPOS[@]} -eq 0 ]; then
  echo "📂 Scanning base directories for all repositories..."
  for BASE_DIR in "${BASE_DIRS[@]}"; do
    if [ ! -d "$BASE_DIR" ]; then
      echo "   ⚠️  Directory not found: $BASE_DIR"
      continue
    fi
   
    echo "   🔍 Scanning: $BASE_DIR"
   
    # Recursively find all git repositories in the directory tree
    repo_count=0
    while IFS= read -r gitdir; do
      REPO_DIR=$(dirname "$gitdir")
     
      if add_repository_if_new "$REPO_DIR" REPOS_TO_SCAN; then
        ((repo_count++))
      fi
    done < <(find "$BASE_DIR" -type d -name ".git")
   
    echo "   ✓ Found $repo_count repositories in $(basename "$BASE_DIR")"
  done
  echo ""
fi

# Summary of repositories to scan

# Si no hay repositorios para escanear, continuar con la limpieza de .m2 igualmente
if [ ${#REPOS_TO_SCAN[@]} -eq 0 ]; then
  echo "⚠️  No repositories to scan. Will proceed to clean .m2 repository anyway."
  # Crear archivos temporales vacíos para simular que no hay dependencias usadas
  > "$OUTPUT_FILE"
  echo "Dependency,Version" > "$OUTPUT_FILE"
  SKIP_REPO_SCAN=true
fi

echo "📊 Total repositories to scan: ${#REPOS_TO_SCAN[@]}"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create local tmp directory if it doesn't exist
TMP_DIR="$SCRIPT_DIR/tmp"
mkdir -p "$TMP_DIR"

# Output file for the complete report (saved in script directory)
OUTPUT_FILE="$SCRIPT_DIR/.maven_deps_report_used.csv"
UNUSED_OUTPUT_FILE="$SCRIPT_DIR/.maven_deps_report_unused.csv"
LAST_RUN_FILE="$SCRIPT_DIR/.maven_deps_last_run"

# Temporary file for processing dependencies
TEMP_FILE="$TMP_DIR/maven_deps_temp_$$.txt"
TEMP_TREE_FILE="$TMP_DIR/maven_tree_temp_$$.txt"
TEMP_M2_FILE="$TMP_DIR/maven_m2_deps_$$.txt"

# Counters
TOTAL_REPOS=0
MAVEN_REPOS=0
TOTAL_POM_FILES=0
TOTAL_DEPENDENCIES=0
TOTAL_TRANSITIVE=0
CURRENT_POM=0
CURRENT_MAVEN_REPO=0
TOTAL_MAVEN_REPOS_TO_PROCESS=0

# Function to extract dependencies using Maven dependency:tree
extract_dependencies_with_maven() {
  local pom_file="$1"
  local pom_dir="$(dirname "$pom_file")"
 
  ((CURRENT_POM++))
  local progress_percent=$((CURRENT_POM * 100 / TOTAL_POM_FILES))
  echo "  📄 [$CURRENT_POM/$TOTAL_POM_FILES - ${progress_percent}%] Analyzing: $(basename "$pom_dir")/$(basename "$pom_file")"
 
  # Check if Maven is available
  if ! command -v mvn &> /dev/null; then
    echo "    ⚠️  Maven not found. Using XML parsing."
    extract_dependencies_from_xml "$pom_file"
    return $?
  fi
 
  # Check if we should use Maven
  if [ "$USE_MAVEN" = false ]; then
    extract_dependencies_from_xml "$pom_file"
    return $?
  fi
 
  # Check if this POM has a parent and try to find the root project
  local exec_dir="$pom_dir"
  local relative_path=""
  local use_reactor=false
 
  if grep -q "<parent>" "$pom_file" 2>/dev/null; then
    # This is a module, try to find the parent POM
    local parent_dir="$pom_dir"
    while [ "$parent_dir" != "/" ] && [ "$parent_dir" != "$HOME" ]; do
      parent_dir="$(dirname "$parent_dir")"
      if [ -f "$parent_dir/pom.xml" ] && grep -q "<packaging>pom</packaging>" "$parent_dir/pom.xml" 2>/dev/null; then
        # Found parent with packaging=pom, check if this module is declared in parent
        local module_name="$(basename "$pom_dir")"
        if grep -q "<module>$module_name</module>" "$parent_dir/pom.xml" 2>/dev/null; then
          # Module is declared in parent, use it as execution directory
          exec_dir="$parent_dir"
          relative_path="${pom_dir#$parent_dir/}"
          use_reactor=true
          echo "    ℹ️  Multi-module project detected, using parent POM"
          break
        fi
      fi
      # Stop if we've left the git repository
      if [ ! -d "$parent_dir/.git" ]; then
        break
      fi
    done
  fi
 
  # Run Maven dependency:tree to get all dependencies (direct and transitive)
  cd "$exec_dir"
 
  echo "    ⏳ Running Maven analysis (may take 30-60 seconds)..."
 
  # Run Maven (without timeout as it's not available on macOS by default)
  # Maven will resolve and download dependencies
  # Use a background job with wait to allow for monitoring
  local tree_output
  local maven_pid
 
  # Start Maven in background and capture PID
  # If we have a relative path (module), specify it with -pl flag
  if [ "$use_reactor" = true ] && [ -n "$relative_path" ]; then
    mvnp dependency:tree -DoutputType=text -B -pl "$relative_path" -am > "$TMP_DIR/maven_output_$$.txt" 2>&1 &
  else
    mvnp dependency:tree -DoutputType=text -B > "$TMP_DIR/maven_output_$$.txt" 2>&1 &
  fi
  maven_pid=$!
 
  # Wait for Maven with a timeout using a loop (max 60 seconds)
  local counter=0
  local max_wait=60
  while kill -0 $maven_pid 2>/dev/null; do
    sleep 1
    ((counter++))
    if [ $counter -eq 30 ]; then
      echo "    ⏱️  Still working (30s)..."
    elif [ $counter -eq 60 ]; then
      echo "    ⏱️  Still working (60s)..."
    elif [ $counter -eq 90 ]; then
      echo "    ⏱️  Still working (90s)..."
    elif [ $counter -ge $max_wait ]; then
      echo "    ⏱️  Timeout after ${max_wait}s, killing Maven and using XML parsing"
      # Kill the process group to ensure all child processes are terminated
      pkill -TERM -P $maven_pid 2>/dev/null || true
      sleep 1
      kill -9 $maven_pid 2>/dev/null || true
      pkill -9 -P $maven_pid 2>/dev/null || true
      wait $maven_pid 2>/dev/null || true
      rm -f "$TMP_DIR/maven_output_$$.txt"
      extract_dependencies_from_xml "$pom_file"
      cd - > /dev/null 2>&1
      return
    fi
  done
 
  # Get Maven exit code (process already finished)
  local maven_exit=0
  wait $maven_pid 2>/dev/null || maven_exit=$?
 
  # Read the output
  tree_output=$(cat "$TMP_DIR/maven_output_$$.txt" 2>/dev/null || echo "")
  rm -f "$TMP_DIR/maven_output_$$.txt"
 
  # Check for BUILD FAILURE
  if echo "$tree_output" | grep -q "BUILD FAILURE"; then
    echo "    ⚠️  Maven BUILD FAILURE detected, using XML parsing"
    extract_dependencies_from_xml "$pom_file"
    cd - > /dev/null 2>&1
    return
  fi
 
  # Check if Maven exited with error
  if [ $maven_exit -ne 0 ]; then
    echo "    ⚠️  Maven exited with error (code: $maven_exit), using XML parsing"
    extract_dependencies_from_xml "$pom_file"
    cd - > /dev/null 2>&1
    return
  fi
 
  # Check if we got valid output
  local dep_count=$(echo "$tree_output" | grep -cE "^\[INFO\] [\|+\\\ -]+.*:.*:.*:.*" 2>/dev/null | head -1 || echo "0")
 
  if [ "$dep_count" -gt 0 ] 2>/dev/null; then
    echo "$tree_output" | grep -E "^\[INFO\] [\|+\\\ -]+.*:.*:.*:.*" | \
      sed 's/\[INFO\] //g' | \
      sed 's/^[[:space:]]*//g' | \
      sed 's/[|+\\-]//g' | \
      sed 's/^[[:space:]]*//g' | \
      while IFS= read -r line; do
        if [[ "$line" =~ ^([^:]+):([^:]+):[^:]+:([^:]+) ]]; then
          local group="${BASH_REMATCH[1]}"
          local artifact="${BASH_REMATCH[2]}"
          local version="${BASH_REMATCH[3]}"
         
          if [ -n "$group" ] && [ -n "$artifact" ] && [ -n "$version" ] && [[ ! "$version" =~ ^\$ ]] && [[ ! "$version" =~ \( ]]; then
            echo "$group:$artifact,$version" >> "$TEMP_FILE"
          fi
        fi
      done
    echo "    ✓ Found $dep_count dependencies (including transitive)"
  else
    echo "    ℹ️  No dependencies declared in this POM, using XML parsing as fallback"
    extract_dependencies_from_xml "$pom_file"
  fi
 
  cd - > /dev/null 2>&1
}

# Function to extract dependencies from XML (fallback method)
extract_dependencies_from_xml() {
  local pom_file="$1"
 
  # Check if xmllint is available
  if ! command -v xmllint &> /dev/null; then
    echo "    ⚠️  Warning: xmllint not found. Skipping this POM."
    return 1
  fi
 
  # Check if file is readable and valid XML
  if [ ! -r "$pom_file" ]; then
    echo "    ⚠️  Warning: Cannot read file"
    return 1
  fi
 
  # Validate XML first
  if ! xmllint --noout "$pom_file" 2>/dev/null; then
    echo "    ⚠️  Warning: Invalid XML format"
    return 1
  fi
 
  # Count dependencies and plugins using grep
  local dep_count=$(grep -c "<dependency>" "$pom_file" 2>/dev/null | head -1 | tr -d ' \n' || echo "0")
  local plugin_count=$(grep -c "<plugin>" "$pom_file" 2>/dev/null | head -1 | tr -d ' \n' || echo "0")
 
  # Ensure we have valid integers
  [[ ! "$dep_count" =~ ^[0-9]+$ ]] && dep_count=0
  [[ ! "$plugin_count" =~ ^[0-9]+$ ]] && plugin_count=0
 
  if [ "$dep_count" -eq 0 ] && [ "$plugin_count" -eq 0 ] 2>/dev/null; then
    echo "    ℹ️  No dependencies or plugins found in this POM file"
    return 0
  fi
 
  # Parse dependencies and plugins line by line
  local in_dependency=false
  local in_plugin=false
  local group_id=""
  local artifact_id=""
  local version=""
  local dep_mgmt_depth=0
  local plugin_mgmt_depth=0
  local build_depth=0
 
  while IFS= read -r line; do
    # Track if we're inside dependencyManagement section
    if [[ "$line" =~ \<dependencyManagement\> ]]; then
      ((dep_mgmt_depth++))
    elif [[ "$line" =~ \</dependencyManagement\> ]]; then
      ((dep_mgmt_depth--))
    fi
   
    # Track if we're inside pluginManagement section
    if [[ "$line" =~ \<pluginManagement\> ]]; then
      ((plugin_mgmt_depth++))
    elif [[ "$line" =~ \</pluginManagement\> ]]; then
      ((plugin_mgmt_depth--))
    fi
   
    # Track if we're inside build section (for plugins)
    if [[ "$line" =~ \<build\> ]]; then
      ((build_depth++))
    elif [[ "$line" =~ \</build\> ]]; then
      ((build_depth--))
    fi
   
    # Process regular dependencies (outside dependencyManagement)
    if [ $dep_mgmt_depth -eq 0 ]; then
      if [[ "$line" =~ \<dependency\> ]]; then
        in_dependency=true
        group_id=""
        artifact_id=""
        version=""
      elif [ "$in_dependency" = true ]; then
        if [[ "$line" =~ \<groupId\>([^<]+)\</groupId\> ]]; then
          group_id="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \<artifactId\>([^<]+)\</artifactId\> ]]; then
          artifact_id="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \<version\>([^<]+)\</version\> ]]; then
          version="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \</dependency\> ]]; then
          if [ -n "$group_id" ] && [ -n "$artifact_id" ] && [ -n "$version" ]; then
            # Only add if version is not a variable (doesn't start with $)
            if [[ ! "$version" =~ ^\$ ]]; then
              echo "$group_id:$artifact_id,$version" >> "$TEMP_FILE"
            fi
          fi
          in_dependency=false
        fi
      fi
    fi
   
    # Process plugins (outside pluginManagement but inside build)
    if [ $plugin_mgmt_depth -eq 0 ] && [ $build_depth -gt 0 ]; then
      if [[ "$line" =~ \<plugin\> ]]; then
        in_plugin=true
        group_id=""
        artifact_id=""
        version=""
      elif [ "$in_plugin" = true ]; then
        if [[ "$line" =~ \<groupId\>([^<]+)\</groupId\> ]]; then
          group_id="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \<artifactId\>([^<]+)\</artifactId\> ]]; then
          artifact_id="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \<version\>([^<]+)\</version\> ]]; then
          version="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ \</plugin\> ]]; then
          if [ -n "$group_id" ] && [ -n "$artifact_id" ] && [ -n "$version" ]; then
            # Only add if version is not a variable
            if [[ ! "$version" =~ ^\$ ]]; then
              echo "$group_id:$artifact_id,$version" >> "$TEMP_FILE"
            fi
          fi
          in_plugin=false
        fi
      fi
    fi
  done < "$pom_file"
 
  echo "    ✓ Dependencies and plugins extracted from XML (direct only)"
}

# Function to process a single repository
process_repository() {
  local repo_dir="$1"
 
  ((TOTAL_REPOS++))
 
  # Find all pom.xml files in the repository
  local pom_files=()
  while IFS= read -r -d '' pom_file; do
    pom_files+=("$pom_file")
  done < <(find "$repo_dir" -name "pom.xml" -type f -not -path "*/target/*" -not -path "*/.git/*" -print0)
 
  # Check if this is a Maven repository
  if [ ${#pom_files[@]} -eq 0 ]; then
    return 0
  fi
 
  ((MAVEN_REPOS++))
  ((CURRENT_MAVEN_REPO++))
 
  echo "═══════════════════════════════════════════════════"
  echo "📦 [$CURRENT_MAVEN_REPO/$TOTAL_MAVEN_REPOS_TO_PROCESS] Maven Repository: $(basename "$repo_dir")"
  echo "   Found ${#pom_files[@]} POM file(s)"
  echo "═══════════════════════════════════════════════════"
 
  # Process each pom.xml file
  for pom_file in "${pom_files[@]}"; do
    extract_dependencies_with_maven "$pom_file"
  done
 
  # Clean up any build artifacts created during dependency:tree analysis
  # This prevents accumulation of target/ directories when batch_repo_maintenance.sh
  # has been run before this script
  if [ -x "$SCRIPT_DIR/clean_build_artifacts.sh" ]; then
    echo "  🧹 Cleaning up build artifacts from repository..."
    cd "$repo_dir"
    "$SCRIPT_DIR/clean_build_artifacts.sh" > /dev/null 2>&1
    cd - > /dev/null 2>&1
  fi
 
  echo ""
}

# Check if minimum days have passed since last run
if [ $MIN_DAYS_BETWEEN_RUNS -gt 0 ] && [ "$FORCE_RUN" = false ]; then
  if [ -f "$LAST_RUN_FILE" ]; then
    LAST_RUN_TIMESTAMP=$(cat "$LAST_RUN_FILE")
    CURRENT_TIMESTAMP=$(date +%s)
    DAYS_DIFF=$(( (CURRENT_TIMESTAMP - LAST_RUN_TIMESTAMP) / 86400 ))
   
    if [ $DAYS_DIFF -lt $MIN_DAYS_BETWEEN_RUNS ]; then
      DAYS_REMAINING=$((MIN_DAYS_BETWEEN_RUNS - DAYS_DIFF))
      LAST_RUN_DATE=$(date -r "$LAST_RUN_TIMESTAMP" "+%Y-%m-%d %H:%M:%S")
     
      echo "⏱️  Last execution: $LAST_RUN_DATE ($DAYS_DIFF days ago)"
      echo "⚠️  Minimum interval: $MIN_DAYS_BETWEEN_RUNS days"
      echo "📅 Next recommended run: in $DAYS_REMAINING day(s)"
      echo ""
      echo "💡 This check prevents unnecessary executions of this slow process."
      echo ""
     
      # Interactive mode: ask user if they want to continue anyway
      read -p "❓ Do you want to run the scan anyway? (yes/NO):" run_anyway
      echo ""

      run_anyway_lc=$(echo "$run_anyway" | tr '[:upper:]' '[:lower:]')
      if [[ "$run_anyway_lc" != "yes" && "$run_anyway_lc" != "y" ]]; then
        echo "✋ Execution cancelled. Use --force to skip this check in the future."
        exit 0
      fi
     
      echo "▶️  Proceeding with scan as requested..."
      echo ""
    fi
  fi
fi

# Main execution
echo "🚀 Starting Maven Dependencies Scanner"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Clean up Maven wrapper files before scanning
CLEANUP_SCRIPT="$(dirname "$0")/cleanup_maven_wrapper.sh"
if [ -f "$CLEANUP_SCRIPT" ]; then
  echo "🧹 Running Maven wrapper cleanup before scanning..."
  # Run cleanup in each repository to be scanned
  for REPO_PATH in "${REPOS_TO_SCAN[@]}"; do
    if [ -d "$REPO_PATH/.git" ]; then
      echo "   Checking: $(basename "$REPO_PATH")"
      (cd "$REPO_PATH" && echo "y" | "$CLEANUP_SCRIPT" 2>/dev/null) || true
    fi
  done
  echo "✓ Cleanup completed"
  echo ""
fi

echo "📋 Report will be saved to: $OUTPUT_FILE"
echo ""

# Check if we can reuse existing report
SKIP_REPO_SCAN=false
if [ -f "$OUTPUT_FILE" ] && [ $MAX_REPORT_AGE_DAYS -gt 0 ]; then
  REPORT_AGE_SECONDS=$(($(date +%s) - $(stat -f %m "$OUTPUT_FILE" 2>/dev/null || echo 0)))
  REPORT_AGE_DAYS=$((REPORT_AGE_SECONDS / 86400))
 
  if [ $REPORT_AGE_DAYS -lt $MAX_REPORT_AGE_DAYS ]; then
    SKIP_REPO_SCAN=true
    echo "📦 Found recent dependency report (${REPORT_AGE_DAYS} day(s) old)"
    echo "✓ Skipping repository scan, reusing existing report"
    echo ""
   
    # Load existing report summary
    TOTAL_DEPENDENCIES=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))
    echo "📊 Cached report contains $TOTAL_DEPENDENCIES unique dependencies"
    echo ""
  fi
fi

# Only capture .m2 state BEFORE if we're actually going to scan repos
if [ "$SKIP_REPO_SCAN" = false ]; then
  # Capture initial state of .m2 repository (before any Maven operations)
  TEMP_M2_BEFORE="$TMP_DIR/maven_m2_before_$$.txt"
  echo "📸 Capturing .m2 repository state before analysis..."
  M2_REPO="$HOME/.m2/repository"

  if [ -d "$M2_REPO" ]; then
    # Create a snapshot of all JARs with their modification times
    find "$M2_REPO" -type f -name "*.jar" \
      -not -name "*-sources.jar" \
      -not -name "*-javadoc.jar" \
      -not -name "*-tests.jar" \
      -not -path "*/maven-metadata*" \
      -exec stat -f "%m %N" {} \; 2>/dev/null > "$TEMP_M2_BEFORE"
   
    INITIAL_JAR_COUNT=$(wc -l < "$TEMP_M2_BEFORE" | tr -d ' ')
    echo "✓ Captured $INITIAL_JAR_COUNT JARs in .m2 repository"
    echo ""
  else
    > "$TEMP_M2_BEFORE"
    echo "⚠️  .m2 repository not found yet"
    echo ""
  fi
else
  # Not scanning repos, so no need for before snapshot
  TEMP_M2_BEFORE="$TMP_DIR/maven_m2_before_$$.txt"
  > "$TEMP_M2_BEFORE"
fi

# Initialize temporary file
> "$TEMP_FILE"

# Only scan repositories if not using cached report
if [ "$SKIP_REPO_SCAN" = false ]; then
  # Count total POM files in all repositories to scan
  echo "🔍 Counting POM files in ${#REPOS_TO_SCAN[@]} repositories..."
 
  # Create temporary file to store repo paths with their POM counts
  TEMP_REPO_COUNTS="$TMP_DIR/maven_repo_counts_$$.txt"
  > "$TEMP_REPO_COUNTS"
 
  for repo in "${REPOS_TO_SCAN[@]}"; do
    pom_count=$(find "$repo" -name "pom.xml" -type f -not -path "*/target/*" -not -path "*/.git/*" | wc -l)
    if [ $pom_count -gt 0 ]; then
      ((TOTAL_MAVEN_REPOS_TO_PROCESS++))
      # Store repo path with count (format: count|repo_path)
      echo "$pom_count|$repo" >> "$TEMP_REPO_COUNTS"
    fi
    TOTAL_POM_FILES=$((TOTAL_POM_FILES + pom_count))
  done

  if [ $TOTAL_POM_FILES -eq 0 ]; then
    echo ""
    echo "ℹ️  No Maven projects found. Proceeding with .m2 cleanup only."
    rm -f "$TEMP_REPO_COUNTS"
    # No exit, continuar con el flujo normal
  fi

  echo "📊 Found $TOTAL_MAVEN_REPOS_TO_PROCESS Maven repositories with $TOTAL_POM_FILES POM file(s) to analyze"
  echo ""
 

  # Sort repositories by POM count (descending) and create ordered array
  SORTED_REPOS=()
  if [ $TOTAL_MAVEN_REPOS_TO_PROCESS -gt 0 ]; then
    while IFS='|' read -r count repo_path; do
      SORTED_REPOS+=("$repo_path")
    done < <(sort -t'|' -k1 -rn "$TEMP_REPO_COUNTS")

    echo "📋 Processing order (repositories with most POMs first):"
    position=1
    while IFS='|' read -r count repo_path; do
      echo "   $position. $(basename "$repo_path") - $count POM file(s)"
      ((position++))
    done < <(sort -t'|' -k1 -rn "$TEMP_REPO_COUNTS")
    echo ""

    # Second pass: Process all repositories in sorted order
    for repo in "${SORTED_REPOS[@]}"; do
      process_repository "$repo"
    done
  fi

  # Clean up temp file
  rm -f "$TEMP_REPO_COUNTS"

  # Generate final CSV report
  echo "🔄 Processing dependencies (sorting and removing duplicates)..."

  # Sort dependencies alphabetically and remove duplicates
  # Also count unique dependencies
  {
    echo "Dependency,Version"
    sort -u "$TEMP_FILE"
  } > "$OUTPUT_FILE"

  TOTAL_DEPENDENCIES=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))

  # Display summary to console
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🏁 Scan completed!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "📊 Summary:"
  echo "   • Total repositories scanned: $TOTAL_REPOS"
  echo "   • Maven repositories found: $MAVEN_REPOS"
  echo "   • Total POM files analyzed: $TOTAL_POM_FILES"
  echo "   • Unique dependencies found: $TOTAL_DEPENDENCIES"
  echo ""
  echo "📄 CSV report saved to:"
  echo "   $OUTPUT_FILE"
  echo ""
  echo "💡 Tip: You can view the report with:"
  echo "   cat $OUTPUT_FILE"
  echo "   or"
  echo "   open $OUTPUT_FILE"
  echo ""
fi

# Analyze .m2 directory for unused dependencies
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Analyzing local Maven repository for unused dependencies..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

M2_REPO="$HOME/.m2/repository"

if [ ! -d "$M2_REPO" ]; then
  echo "⚠️  Maven local repository not found at: $M2_REPO"
  echo "   Skipping unused dependencies analysis."
  echo ""
  rm -f "$TEMP_M2_BEFORE"
else
  echo "📂 Scanning Maven repository: $M2_REPO"
  echo ""
 
  # Only capture .m2 state AFTER and compare if we scanned repos
  # If we skipped repo scan, we don't need before/after comparison
  if [ "$SKIP_REPO_SCAN" = false ]; then
    # Capture final state of .m2 repository (after analysis)
    TEMP_M2_AFTER="$TMP_DIR/maven_m2_after_$$.txt"
    echo "📸 Capturing .m2 repository state after analysis..."
    find "$M2_REPO" -type f -name "*.jar" \
      -not -name "*-sources.jar" \
      -not -name "*-javadoc.jar" \
      -not -name "*-tests.jar" \
      -not -path "*/maven-metadata*" \
      -exec stat -f "%m %N" {} \; 2>/dev/null > "$TEMP_M2_AFTER"
   
    FINAL_JAR_COUNT=$(wc -l < "$TEMP_M2_AFTER" | tr -d ' ')
    echo "✓ Found $FINAL_JAR_COUNT JARs in .m2 repository"
    echo ""
   
    # Identify newly downloaded or modified dependencies (Maven downloaded these during analysis)
    TEMP_MAVEN_DOWNLOADED="$TMP_DIR/maven_downloaded_$$.txt"
    > "$TEMP_MAVEN_DOWNLOADED"
   
    # Compare before and after - find new or modified files
    echo "🔍 Identifying dependencies downloaded during analysis..."
    DOWNLOADED_COUNT=0
   
    while IFS= read -r after_line; do
      after_time=$(echo "$after_line" | awk '{print $1}')
      after_path=$(echo "$after_line" | cut -d' ' -f2-)
     
      # Check if this file existed before
      before_entry=$(grep -F "$after_path" "$TEMP_M2_BEFORE" || echo "")
     
      should_add=false
      if [ -z "$before_entry" ]; then
        # New file - downloaded during analysis
        should_add=true
      else
        before_time=$(echo "$before_entry" | awk '{print $1}')
        # Check if modified (different timestamp)
        if [ "$after_time" -gt "$before_time" ]; then
          should_add=true
        fi
      fi
     
      if [ "$should_add" = true ]; then
        ((DOWNLOADED_COUNT++))
        if dep_info=$(extract_dependency_from_path "$after_path" "$M2_REPO"); then
          echo "$dep_info" >> "$TEMP_MAVEN_DOWNLOADED"
        fi
      fi
    done < "$TEMP_M2_AFTER"
   
    # Deduplicate
    sort -u "$TEMP_MAVEN_DOWNLOADED" -o "$TEMP_MAVEN_DOWNLOADED"
    UNIQUE_DOWNLOADED=$(wc -l < "$TEMP_MAVEN_DOWNLOADED" | tr -d ' ')
   
    echo "✓ Maven downloaded/updated $DOWNLOADED_COUNT JARs during analysis"
    echo "✓ Unique dependencies downloaded: $UNIQUE_DOWNLOADED"
    echo ""
    echo "💡 These dependencies will be marked as 'used' (needed by Maven for builds)"
    echo ""
  else
    # No repo scan, so no downloads to track
    TEMP_MAVEN_DOWNLOADED="$TMP_DIR/maven_downloaded_$$.txt"
    > "$TEMP_MAVEN_DOWNLOADED"
    UNIQUE_DOWNLOADED=0
    TEMP_M2_AFTER="$TMP_DIR/maven_m2_after_$$.txt"
    > "$TEMP_M2_AFTER"
    echo "✓ Using cached report, no new downloads to track"
    echo ""
  fi
 
  # Initialize temporary file for .m2 dependencies
  > "$TEMP_M2_FILE"
 
  # Scan .m2/repository directory structure
  # Maven repo structure: groupId/artifactId/version/artifactId-version.jar
  # We need to extract groupId, artifactId, and version from directory structure
 
  echo "🔄 Extracting all installed dependencies from .m2 repository..."
  echo "   (This may take a few minutes for large repositories)"
  echo ""
 
  INSTALLED_COUNT=0
 
  # Find all JAR files in .m2 repository (excluding sources and javadoc)
  while IFS= read -r jar_file; do
    if dep_info=$(extract_dependency_from_path "$jar_file" "$M2_REPO"); then
      echo "$dep_info" >> "$TEMP_M2_FILE"
      ((INSTALLED_COUNT++))
     
      # Show progress every 100 dependencies
      if [ $((INSTALLED_COUNT % 100)) -eq 0 ]; then
        echo "   Processed $INSTALLED_COUNT dependencies..."
      fi
    fi
  done < <(find "$M2_REPO" -type f -name "*.jar" \
    -not -name "*-sources.jar" \
    -not -name "*-javadoc.jar" \
    -not -name "*-tests.jar" \
    -not -path "*/maven-metadata*" 2>/dev/null)
 
  echo ""
 
  # Sort and deduplicate .m2 dependencies
  sort -u "$TEMP_M2_FILE" -o "$TEMP_M2_FILE"
 
  # Count actual unique dependencies after deduplication
  UNIQUE_INSTALLED_COUNT=$(wc -l < "$TEMP_M2_FILE")
 
  echo "✓ Found $INSTALLED_COUNT JAR files in .m2 repository"
  echo "✓ Unique dependencies after deduplication: $UNIQUE_INSTALLED_COUNT"
  echo ""
 
  # Compare with used dependencies to find unused ones
  echo "🔄 Comparing installed vs used dependencies..."
  echo ""
 
  # Create a temporary file with used dependencies (skip header)
  TEMP_USED_FILE="$TMP_DIR/maven_used_deps_$$.txt"
  tail -n +2 "$OUTPUT_FILE" > "$TEMP_USED_FILE"
 
  # Merge declared dependencies with Maven-downloaded dependencies
  # Both are considered "used"
  TEMP_ALL_USED="$TMP_DIR/maven_all_used_$$.txt"
  cat "$TEMP_USED_FILE" "$TEMP_MAVEN_DOWNLOADED" | sort -u > "$TEMP_ALL_USED"
 
  TOTAL_USED_WITH_MAVEN=$(wc -l < "$TEMP_ALL_USED" | tr -d ' ')
 

# Definir patrones core/plugins Maven a proteger SIEMPRE
TEMP_MAVEN_CORE="$TMP_DIR/maven_core_patterns_$$.txt"
cat > "$TEMP_MAVEN_CORE" <<'EOF'
org.apache.maven:
org.codehaus.plexus:
org.sonatype.plexus:
org.eclipse.aether:
org.apache.maven.plugins:
org.codehaus.mojo:
org.sonatype.sisu:
org.eclipse.sisu:
EOF
MAVEN_CORE_PATTERNS=$(wc -l < "$TEMP_MAVEN_CORE" | tr -d ' ')
echo "✓ Using strict Maven core/plugin protection patterns ($MAVEN_CORE_PATTERNS)"
echo ""
 
  echo "📊 Total 'used' dependencies (declared + Maven-downloaded): $TOTAL_USED_WITH_MAVEN"
  echo ""
 
  # Calculate dependencies that are both used and installed (do this BEFORE creating unused report)
  TEMP_INTERSECTION="$TMP_DIR/maven_intersection_$$.txt"
  comm -12 <(sort "$TEMP_ALL_USED") <(sort "$TEMP_M2_FILE") > "$TEMP_INTERSECTION"
  INSTALLED_AND_USED=$(wc -l < "$TEMP_INTERSECTION")
  rm -f "$TEMP_INTERSECTION"
 

# Encontrar dependencias instaladas pero no usadas, excluyendo core/plugins Maven
{
  echo "Dependency,Version"
  comm -23 <(sort "$TEMP_M2_FILE") <(sort "$TEMP_ALL_USED") | \
    while IFS=',' read -r dep ver; do
      is_core=false
      while IFS= read -r pattern; do
        if [[ "$dep" == $pattern* ]]; then
          is_core=true
          break
        fi
      done < "$TEMP_MAVEN_CORE"

      # Si es core/plugin Maven, solo eliminar versiones antiguas (no la más nueva ni las usadas)
      if [ "$is_core" = true ]; then
        # Buscar todas las versiones instaladas de este artefacto
        artifact_versions=( $(grep "^$dep," "$TEMP_M2_FILE" | cut -d',' -f2 | sort -V) )
        if [ ${#artifact_versions[@]} -eq 0 ]; then
          continue
        fi
        # Obtener el último elemento del array de forma portable (bash 3.x compatible)
        latest_version=""
        if [ ${#artifact_versions[@]} -gt 0 ]; then
          last_idx=$((${#artifact_versions[@]} - 1))
          latest_version="${artifact_versions[$last_idx]}"
        fi
        if [ -z "$latest_version" ]; then
          continue
        fi
        # Si la versión actual es la más nueva, o está en la lista de usadas, no borrar
        if [ "$ver" = "$latest_version" ]; then
          continue
        fi
        if grep -q "^$dep,$ver$" "$TEMP_ALL_USED"; then
          continue
        fi
        # Si no es la más nueva ni usada, se puede borrar
        echo "$dep,$ver"
        continue
      fi

      # Para el resto, aplicar lógica normal
      is_plugin=false
      if [ "$EXCLUDE_MAVEN_PLUGINS" = true ]; then
        if [[ "$dep" =~ -plugin$ ]] || [[ "$dep" =~ -maven-plugin$ ]]; then
          is_plugin=true
        fi
      fi
      if [ "$is_plugin" = false ]; then
        echo "$dep,$ver"
      fi
    done
} > "$UNUSED_OUTPUT_FILE"
 
  # If KEEP_LATEST_VERSION is enabled, filter out the latest version of each artifact
  if [ "$KEEP_LATEST_VERSION" = true ]; then
    TEMP_FILTERED="$TMP_DIR/maven_filtered_$$.txt"
    echo "🔍 Filtering to keep latest version of each artifact..."
   
    # Group by artifact (without version) and keep all except the latest
    {
      echo "Dependency,Version"
      tail -n +2 "$UNUSED_OUTPUT_FILE" | \
        awk -F',' '{
          artifact=$1
          version=$2
          # Store all versions for this artifact
          if (artifact in versions) {
            versions[artifact] = versions[artifact] "," version
          } else {
            versions[artifact] = version
          }
          # Store dependency for later
          deps[artifact "," version] = $0
        }
        END {
          for (artifact in versions) {
            # Split versions
            split(versions[artifact], ver_array, ",")
           
            # Simple version comparison: keep the last one lexicographically
            # This is not perfect but works for most cases
            latest = ver_array[1]
            for (i = 2; i <= length(ver_array); i++) {
              if (ver_array[i] > latest) {
                latest = ver_array[i]
              }
            }
           
            # Print all versions except the latest
            for (i = 1; i <= length(ver_array); i++) {
              if (ver_array[i] != latest) {
                print deps[artifact "," ver_array[i]]
              }
            }
          }
        }'
    } > "$TEMP_FILTERED"
   
    # Replace original with filtered
    mv "$TEMP_FILTERED" "$UNUSED_OUTPUT_FILE"
    echo "✓ Kept latest version of each artifact"
    echo ""
  fi
 
  # Clean up temp files
  rm -f "$TEMP_USED_FILE" "$TEMP_ALL_USED" "$TEMP_MAVEN_DOWNLOADED" "$TEMP_M2_BEFORE" "$TEMP_M2_AFTER" "$TEMP_MAVEN_CORE"
 
  # Count unused dependencies AFTER all filtering
  UNUSED_COUNT=$(( $(wc -l < "$UNUSED_OUTPUT_FILE") - 1 ))
 
  echo "✓ Found $UNUSED_COUNT unused dependencies in .m2"
  echo ""
 
  if [ "$KEEP_LATEST_VERSION" = true ]; then
    echo "   ℹ️  Latest version of each artifact is kept (safe mode enabled)"
  fi
  if [ "$EXCLUDE_MAVEN_PLUGINS" = true ]; then
    echo "   ℹ️  Maven plugins are excluded from deletion (safe mode enabled)"
  fi
  echo ""
 
  echo "📊 Comparison Summary:"
  echo "   • Dependencies installed in .m2: $UNIQUE_INSTALLED_COUNT"
  echo "   • Dependencies declared in projects: $TOTAL_DEPENDENCIES"
  echo "   • Dependencies downloaded by Maven during scan: $UNIQUE_DOWNLOADED"
  echo "   • Maven core dependencies (auto-excluded): $MAVEN_CORE_PATTERNS patterns"
  echo "   • Total dependencies considered 'used': $TOTAL_USED_WITH_MAVEN"
  echo "   • Dependencies both used and installed: $INSTALLED_AND_USED"
  echo "   • Dependencies installed but not used: $UNUSED_COUNT"
  echo "   • Dependencies used but not in .m2: $(($TOTAL_USED_WITH_MAVEN - $INSTALLED_AND_USED))"
  echo ""
  echo "   💡 Protection strategy:"
  echo "      ✓ Dependencies declared in pom.xml files"
  echo "      ✓ Dependencies downloaded during this scan (plugins, etc.)"
  echo "      ✓ Maven core infrastructure (detected from Maven installation)"
  if [ "$EXCLUDE_MAVEN_PLUGINS" = true ]; then
    echo "      ✓ All Maven plugins (never deleted)"
  fi
  if [ "$KEEP_LATEST_VERSION" = true ]; then
    echo "      ✓ Latest version of each artifact (only old versions deleted)"
  fi
  echo ""
  echo "📄 Unused dependencies report saved to:"
  echo "   $UNUSED_OUTPUT_FILE"
  echo ""
  echo "💡 Tip: You can review unused dependencies with:"
  echo "   cat $UNUSED_OUTPUT_FILE"
  echo "   or"
  echo "   open $UNUSED_OUTPUT_FILE"
  echo ""
  echo "⚠️  Note: Some 'unused' dependencies may be:"
  echo "   • Transitive dependencies downloaded by Maven"
  echo "   • Dependencies from projects not included in this scan"
  echo "   • Build plugins or their dependencies"
  echo "   Review carefully before deleting!"
  echo ""
 
  # Delete unused dependencies if requested
  if [ "$DELETE_UNUSED" = true ]; then
    # Skip deletion if there are no unused dependencies
    if [ "$UNUSED_COUNT" -eq 0 ]; then
      echo "✅ No unused dependencies to delete. Your .m2 repository is clean!"
      echo ""
    else
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "🗑️  DELETE UNUSED DEPENDENCIES"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      echo "⚠️  WARNING: You are about to delete unused dependencies from .m2 repository"
      echo ""
     
      # Calculate total size to be deleted
      echo "🔄 Calculating size of dependencies to delete..."
      TOTAL_SIZE_BYTES=0
      DEPS_WITH_SIZE=0
   
    while IFS=',' read -r dependency version; do
      # Skip header
      if [[ "$dependency" == "Dependency" ]]; then
        continue
      fi
     
      # Extract groupId and artifactId
      if [[ "$dependency" =~ ^([^:]+):(.+)$ ]]; then
        group_id="${BASH_REMATCH[1]}"
        artifact_id="${BASH_REMATCH[2]}"
        group_path=$(echo "$group_id" | tr '.' '/')
        dep_path="$M2_REPO/$group_path/$artifact_id/$version"
       
        if [ -d "$dep_path" ]; then
          dep_size=$(get_dir_size_kb "$dep_path")
          if [ "$dep_size" != "0" ]; then
            TOTAL_SIZE_BYTES=$((TOTAL_SIZE_BYTES + dep_size))
            ((DEPS_WITH_SIZE++))
          fi
        fi
      fi
    done < "$UNUSED_OUTPUT_FILE"
   
    TOTAL_SIZE_DISPLAY=$(format_size $TOTAL_SIZE_BYTES)
   
    M2_CURRENT_SIZE=$(du -sh ~/.m2/repository 2>/dev/null | cut -f1)
   
    echo ""
    echo "📊 Summary:"
    echo "   • Total dependencies to delete: $UNUSED_COUNT"
    echo "   • Estimated space to free: ~$TOTAL_SIZE_DISPLAY"
    echo "   • Current .m2 repository size: $M2_CURRENT_SIZE"
    echo "   • List available in: $UNUSED_OUTPUT_FILE"
    echo ""
    echo "⚠️  CAUTION: This action will:"
    echo "   • Delete JAR files and their directories from ~/.m2/repository"
    echo "   • Free up approximately $TOTAL_SIZE_DISPLAY of disk space"
    echo "   • Dependencies will be re-downloaded if needed in future builds"
    echo ""
   
    # Ask for confirmation
    read -p "❓ Do you want to proceed with deletion? (yes/NO): " confirmation
    echo ""
   
    confirmation_lc=$(echo "$confirmation" | tr '[:upper:]' '[:lower:]')
    if [[ "$confirmation_lc" == "yes" || "$confirmation_lc" == "y" ]]; then
      echo "🔄 Starting deletion process..."
      echo ""
     
      DELETED_COUNT=0
      FAILED_COUNT=0
     
      # Read each unused dependency and delete it
      while IFS=',' read -r dependency version; do
        # Skip header
        if [[ "$dependency" == "Dependency" ]]; then
          continue
        fi
       
        if delete_dependency "$dependency" "$version" "$M2_REPO"; then
          ((DELETED_COUNT++))
         
          # Show progress every 100 deletions
          if [ $((DELETED_COUNT % 100)) -eq 0 ]; then
            echo "   ✓ Deleted $DELETED_COUNT dependencies..."
          fi
        else
          ((FAILED_COUNT++))
        fi
      done < "$UNUSED_OUTPUT_FILE"
     
      echo ""
      echo "✅ Deletion pass 1/$MAX_DELETION_ATTEMPTS completed!"
      echo ""
      echo "📊 Pass 1 results:"
      echo "   • Successfully deleted: $DELETED_COUNT dependencies"
      if [ $FAILED_COUNT -gt 0 ]; then
        echo "   • Failed to delete: $FAILED_COUNT dependencies"
      fi
      echo ""
     
      # Track total deletions across all attempts
      TOTAL_DELETED=$DELETED_COUNT
      TOTAL_FAILED=$FAILED_COUNT
     
      # Retry deletion for remaining dependencies up to MAX_DELETION_ATTEMPTS
      for attempt in $(seq 2 $MAX_DELETION_ATTEMPTS); do
        echo "🔍 Verifying if there are remaining dependencies to clean up..."
        REMAINING_COUNT=$(count_remaining_deps "$UNUSED_OUTPUT_FILE" "$M2_REPO")
       
        # If nothing remains, stop trying
        if [ $REMAINING_COUNT -eq 0 ]; then
          echo "✅ All unused dependencies successfully removed!"
          echo ""
          break
        fi
       
        echo "⚠️  Found $REMAINING_COUNT dependencies still present in .m2"
        echo ""
        echo "🔄 Starting cleanup pass $attempt/$MAX_DELETION_ATTEMPTS..."
        echo ""
       
        ATTEMPT_DELETED=0
        ATTEMPT_FAILED=0
       
        while IFS=',' read -r dependency version; do
          # Skip header
          if [[ "$dependency" == "Dependency" ]]; then
            continue
          fi
         
          if delete_dependency "$dependency" "$version" "$M2_REPO"; then
            ((ATTEMPT_DELETED++))
           
            # Show progress every 100 deletions
            if [ $((ATTEMPT_DELETED % 100)) -eq 0 ]; then
              echo "   ✓ Deleted $ATTEMPT_DELETED dependencies in this pass..."
            fi
          else
            ((ATTEMPT_FAILED++))
          fi
        done < "$UNUSED_OUTPUT_FILE"
       
        echo ""
        echo "✅ Cleanup pass $attempt/$MAX_DELETION_ATTEMPTS completed!"
        echo ""
        echo "📊 Pass $attempt results:"
        echo "   • Successfully deleted: $ATTEMPT_DELETED dependencies"
        if [ $ATTEMPT_FAILED -gt 0 ]; then
          echo "   • Failed to delete: $ATTEMPT_FAILED dependencies"
        fi
        echo ""
       
        # Update totals
        TOTAL_DELETED=$((TOTAL_DELETED + ATTEMPT_DELETED))
        TOTAL_FAILED=$((TOTAL_FAILED + ATTEMPT_FAILED))
      done
     
      # Final summary
      if [ $MAX_DELETION_ATTEMPTS -gt 1 ]; then
        echo "📊 Total deletion summary:"
        echo "   • Total deleted across all passes: $TOTAL_DELETED dependencies"
        if [ $TOTAL_FAILED -gt 0 ]; then
          echo "   • Total failed: $TOTAL_FAILED dependencies"
        fi
        echo ""
      fi
     
      echo "💾 Disk space freed: Check with 'du -sh ~/.m2/repository'"
      echo ""

      # Run mvn dependency:go-offline on all Maven repositories
      if [ ${#REPOS_TO_SCAN[@]} -gt 0 ]; then
        # Filter to get only Maven repositories (those with pom.xml files)
        MAVEN_REPOS_LIST=()
        for repo in "${REPOS_TO_SCAN[@]}"; do
          if [ -f "$repo/pom.xml" ]; then
            MAVEN_REPOS_LIST+=("$repo")
          fi
        done

        if [ ${#MAVEN_REPOS_LIST[@]} -gt 0 ]; then
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "🚀 Running mvn dependency:go-offline on all Maven repositories..."
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo ""

          declare -a FAILED_REPOS

          for repo in "${MAVEN_REPOS_LIST[@]}"; do
            echo "📦 Repository: $(basename "$repo")"
            echo "📂 Path: $repo"
            echo ""
            cd "$repo"
            if [ -x "$SCRIPT_DIR/check_maven_java_version.sh" ]; then
              echo "🔎 Running check-maven-java-version to sync Java version..."
              "$SCRIPT_DIR/check_maven_java_version.sh" || true
            else
              echo "⚠️  Warning: check_maven_java_version.sh not found or not executable"
            fi
            if [ -x "$SCRIPT_DIR/clean_build_artifacts.sh" ]; then
              echo "🧹 Running clean-build-artifacts to clean build artifacts..."
              "$SCRIPT_DIR/clean_build_artifacts.sh" || true
            else
              echo "⚠️  Warning: clean_build_artifacts.sh not found or not executable"
            fi
            echo ""
            echo "⬇️  Downloading Maven dependencies (mvn dependency:go-offline)..."
            if mvnp dependency:go-offline; then
              echo ""
              echo "✅ Maven dependencies downloaded successfully!"
              echo ""
            else
              MVN_EXIT_CODE=$?
              echo ""
              echo "⚠️  Maven dependency download failed (exit code: $MVN_EXIT_CODE)"
              echo ""
              FAILED_REPOS+=("$repo")
            fi
            echo ""
            cd - > /dev/null 2>&1
          done

          if [ ${#FAILED_REPOS[@]} -gt 0 ]; then
            echo "❌ Maven dependency download failed in the following repositories:"
            for failed in "${FAILED_REPOS[@]}"; do
              echo "   - $failed"
            done
            echo ""
          else
            echo "🎉 Maven dependency download completed successfully in all repositories!"
            echo ""
          fi
        else
          echo "ℹ️  No Maven repositories with root pom.xml found for mvn dependency:go-offline"
          echo ""
        fi
      fi

      # Update last run timestamp (set to 00:00 of today)
      date -v0H -v0M -v0S +%s > "$LAST_RUN_FILE"

      # Clean up temporary files
      rm -f "$TEMP_FILE" "$TEMP_TREE_FILE" "$TEMP_M2_FILE"
    else
      echo "❌ Deletion cancelled by user"
      echo ""
    fi
    fi
  fi
fi

# Final cleanup: Remove tmp directory
if [ -d "$TMP_DIR" ]; then
  echo "🧹 Cleaning up temporary files..."
  if rm -rf "$TMP_DIR" 2>/dev/null; then
    echo "✓ Temporary directory removed: $TMP_DIR"
  else
    echo "⚠️  Warning: Could not remove temporary directory: $TMP_DIR"
  fi
  echo ""
fi

# Eliminar posibles líneas sueltas o typos residuales