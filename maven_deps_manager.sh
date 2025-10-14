#!/bin/bash
# Maven Dependencies Manager
# 
# This script provides comprehensive Maven dependency management across git repositories:
# 1. Detect Java/Maven projects (repositories containing pom.xml files)
# 2. Scan all pom.xml files in each repository (including subdirectories)
# 3. Extract and list all dependencies with their versions (direct and transitive)
# 4. Extract and list all Maven plugins and their dependencies
# 5. Generate CSV reports of used and unused dependencies (sorted, no duplicates)
# 6. Analyze local .m2 repository to identify unused dependencies
# 7. Compare installed vs used dependencies with detailed statistics
# 8. Clean up unused dependencies from .m2 repository (optional)
#
# Usage: ./maven_deps_manager.sh [OPTIONS] [REPOSITORIES...]
#   --without-transitive: Use fast XML parsing (direct dependencies only)
#   --delete-unused: Clean up unused dependencies from .m2 repository
#   --force: Force execution even if minimum days haven't passed
#   REPOSITORIES: Specific repository paths to scan (optional)

unset http_proxy
unset https_proxy
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

# === CONFIGURE YOUR BASE DIRECTORIES HERE ===
DEFAULT_DIR1="$HOME/Documents/reps-personal"
DEFAULT_DIR2="$HOME/Documents/reps-walmart"

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

# Determine which repositories to scan
SCAN_MODE=""
if [ ${#SPECIFIC_REPOS[@]} -gt 0 ]; then
  echo "🎯 Scanning specific repositories (${#SPECIFIC_REPOS[@]} provided)"
  SCAN_MODE="specific"
else
  echo "📂 Scanning all repositories in configured directories"
  SCAN_MODE="all"
fi
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Output file for the complete report (saved in script directory)
OUTPUT_FILE="$SCRIPT_DIR/.maven_deps_report_used.csv"
UNUSED_OUTPUT_FILE="$SCRIPT_DIR/.maven_deps_report_unused.csv"
LAST_RUN_FILE="$SCRIPT_DIR/.maven_deps_last_run"

# Temporary file for processing dependencies
TEMP_FILE="/tmp/maven_deps_temp_$$.txt"
TEMP_TREE_FILE="/tmp/maven_tree_temp_$$.txt"
TEMP_M2_FILE="/tmp/maven_m2_deps_$$.txt"

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
    mvn dependency:tree -DoutputType=text -B -pl "$relative_path" -am > /tmp/maven_output_$$.txt 2>&1 &
  else
    mvn dependency:tree -DoutputType=text -B > /tmp/maven_output_$$.txt 2>&1 &
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
      rm -f /tmp/maven_output_$$.txt
      extract_dependencies_from_xml "$pom_file"
      cd - > /dev/null 2>&1
      return
    fi
  done
  
  # Get Maven exit code (process already finished)
  local maven_exit=0
  wait $maven_pid 2>/dev/null || maven_exit=$?
  
  # Read the output
  tree_output=$(cat /tmp/maven_output_$$.txt 2>/dev/null || echo "")
  rm -f /tmp/maven_output_$$.txt
  
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
  local dep_count=$(grep -c "<dependency>" "$pom_file" 2>/dev/null | head -1 || echo "0")
  local plugin_count=$(grep -c "<plugin>" "$pom_file" 2>/dev/null | head -1 || echo "0")
  
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
      
      if [[ "$run_anyway" != "yes" ]]; then
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
echo "📋 Report will be saved to: $OUTPUT_FILE"
echo ""

# Capture initial state of .m2 repository (before any Maven operations)
TEMP_M2_BEFORE="/tmp/maven_m2_before_$$.txt"
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

# Initialize temporary file
> "$TEMP_FILE"

# First pass: Count all POM files to show progress
echo "🔍 Counting POM files..."
REPOS_TO_SCAN=()

# Check if we're scanning specific repos or base directories
if [ "$SCAN_MODE" = "specific" ]; then
  # Scan specific repositories provided as arguments
  for REPO_PATH in "${SPECIFIC_REPOS[@]}"; do
    if [ ! -d "$REPO_PATH" ]; then
      echo "⚠️  Repository not found: $REPO_PATH"
      echo ""
      continue
    fi
    
    # Check if it's a git repository
    if [ -d "$REPO_PATH/.git" ]; then
      REPOS_TO_SCAN+=("$REPO_PATH")
    else
      # Maybe it's a directory containing the repo, try to find .git inside
      if find "$REPO_PATH" -maxdepth 1 -type d -name ".git" -print -quit | grep -q ".git"; then
        REPOS_TO_SCAN+=("$REPO_PATH")
      else
        echo "⚠️  Not a git repository: $REPO_PATH"
        echo ""
      fi
    fi
  done
else
  # Scan all repositories in configured base directories
  BASE_DIRS=("$DEFAULT_DIR1" "$DEFAULT_DIR2")
  for BASE_DIR in "${BASE_DIRS[@]}"; do
    if [ ! -d "$BASE_DIR" ]; then
      echo "⚠️  Directory not found: $BASE_DIR"
      echo ""
      continue
    fi
    
    echo "🔍 Scanning directory: $BASE_DIR"

    # Recursively find all git repositories in the directory tree
    while IFS= read -r gitdir; do
      REPO_DIR=$(dirname "$gitdir")
      REPOS_TO_SCAN+=("$REPO_DIR")
    done < <(find "$BASE_DIR" -type d -name ".git")
  done
fi

# Count total POM files
for repo in "${REPOS_TO_SCAN[@]}"; do
  pom_count=$(find "$repo" -name "pom.xml" -type f -not -path "*/target/*" -not -path "*/.git/*" | wc -l)
  if [ $pom_count -gt 0 ]; then
    ((TOTAL_MAVEN_REPOS_TO_PROCESS++))
  fi
  TOTAL_POM_FILES=$((TOTAL_POM_FILES + pom_count))
done

if [ $TOTAL_POM_FILES -eq 0 ]; then
  echo ""
  echo "⚠️  No Maven projects found"
  exit 0
fi

echo "📊 Found $TOTAL_MAVEN_REPOS_TO_PROCESS Maven repositories with $TOTAL_POM_FILES POM file(s) to analyze"
echo ""

# Second pass: Process all repositories
for repo in "${REPOS_TO_SCAN[@]}"; do
  process_repository "$repo"
done

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
  
  # Capture final state of .m2 repository (after analysis)
  TEMP_M2_AFTER="/tmp/maven_m2_after_$$.txt"
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
  TEMP_MAVEN_DOWNLOADED="/tmp/maven_downloaded_$$.txt"
  > "$TEMP_MAVEN_DOWNLOADED"
  
  # Compare before and after - find new or modified files
  echo "🔍 Identifying dependencies downloaded during analysis..."
  DOWNLOADED_COUNT=0
  
  while IFS= read -r after_line; do
    after_time=$(echo "$after_line" | awk '{print $1}')
    after_path=$(echo "$after_line" | cut -d' ' -f2-)
    
    # Check if this file existed before
    before_entry=$(grep -F "$after_path" "$TEMP_M2_BEFORE" || echo "")
    
    if [ -z "$before_entry" ]; then
      # New file - downloaded during analysis
      ((DOWNLOADED_COUNT++))
      
      # Extract dependency info from path
      relative_path="${after_path#$M2_REPO/}"
      version_dir=$(dirname "$relative_path")
      version=$(basename "$version_dir")
      artifact_dir=$(dirname "$version_dir")
      artifact_id=$(basename "$artifact_dir")
      group_path=$(dirname "$artifact_dir")
      group_id=$(echo "$group_path" | tr '/' '.')
      
      if [ -n "$group_id" ] && [ -n "$artifact_id" ] && [ -n "$version" ]; then
        if [[ ! "$version" =~ SNAPSHOT ]] && [[ ! "$version" =~ [\[\(] ]]; then
          echo "$group_id:$artifact_id,$version" >> "$TEMP_MAVEN_DOWNLOADED"
        fi
      fi
    else
      before_time=$(echo "$before_entry" | awk '{print $1}')
      # Check if modified (different timestamp)
      if [ "$after_time" -gt "$before_time" ]; then
        # Modified during analysis
        ((DOWNLOADED_COUNT++))
        
        # Extract dependency info from path
        relative_path="${after_path#$M2_REPO/}"
        version_dir=$(dirname "$relative_path")
        version=$(basename "$version_dir")
        artifact_dir=$(dirname "$version_dir")
        artifact_id=$(basename "$artifact_dir")
        group_path=$(dirname "$artifact_dir")
        group_id=$(echo "$group_path" | tr '/' '.')
        
        if [ -n "$group_id" ] && [ -n "$artifact_id" ] && [ -n "$version" ]; then
          if [[ ! "$version" =~ SNAPSHOT ]] && [[ ! "$version" =~ [\[\(] ]]; then
            echo "$group_id:$artifact_id,$version" >> "$TEMP_MAVEN_DOWNLOADED"
          fi
        fi
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
    # Extract path components
    # Remove the .m2/repository prefix
    relative_path="${jar_file#$M2_REPO/}"
    
    # Get the directory containing the JAR (this is the version directory)
    version_dir=$(dirname "$relative_path")
    version=$(basename "$version_dir")
    
    # Get the artifact directory (parent of version)
    artifact_dir=$(dirname "$version_dir")
    artifact_id=$(basename "$artifact_dir")
    
    # Get the group directory (everything before artifact)
    group_path=$(dirname "$artifact_dir")
    # Convert path to groupId (replace / with .)
    group_id=$(echo "$group_path" | tr '/' '.')
    
    # Validate that this looks like a proper Maven artifact
    if [ -n "$group_id" ] && [ -n "$artifact_id" ] && [ -n "$version" ]; then
      # Skip if version contains maven-metadata or is _remote.repositories
      if [[ ! "$version" =~ maven-metadata ]] && [[ ! "$(basename "$jar_file")" =~ ^_remote\.repositories$ ]]; then
        # Skip SNAPSHOTs and version ranges
        if [[ ! "$version" =~ SNAPSHOT ]] && [[ ! "$version" =~ [\[\(] ]]; then
          echo "$group_id:$artifact_id,$version" >> "$TEMP_M2_FILE"
          ((INSTALLED_COUNT++))
          
          # Show progress every 100 dependencies
          if [ $((INSTALLED_COUNT % 100)) -eq 0 ]; then
            echo "   Processed $INSTALLED_COUNT dependencies..."
          fi
        fi
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
  TEMP_USED_FILE="/tmp/maven_used_deps_$$.txt"
  tail -n +2 "$OUTPUT_FILE" > "$TEMP_USED_FILE"
  
  # Merge declared dependencies with Maven-downloaded dependencies
  # Both are considered "used"
  TEMP_ALL_USED="/tmp/maven_all_used_$$.txt"
  cat "$TEMP_USED_FILE" "$TEMP_MAVEN_DOWNLOADED" | sort -u > "$TEMP_ALL_USED"
  
  TOTAL_USED_WITH_MAVEN=$(wc -l < "$TEMP_ALL_USED" | tr -d ' ')
  
  # Additionally, identify Maven core dependencies that should never be deleted
  # by detecting what Maven itself uses (found in Maven's lib directory)
  TEMP_MAVEN_CORE="/tmp/maven_core_patterns_$$.txt"
  echo "🔍 Detecting Maven core dependencies..."
  
  # Find Maven installation directory
  MAVEN_HOME=""
  if command -v mvn &> /dev/null; then
    MVN_PATH=$(which mvn)
    # Follow symlinks
    if [ -L "$MVN_PATH" ]; then
      MVN_PATH=$(readlink "$MVN_PATH")
    fi
    # Maven home is typically ../.. from bin/mvn
    MAVEN_HOME=$(cd "$(dirname "$MVN_PATH")/.." && pwd)
  fi
  
  # Extract Maven core dependency patterns from Maven's lib directory
  > "$TEMP_MAVEN_CORE"
  if [ -n "$MAVEN_HOME" ] && [ -d "$MAVEN_HOME/lib" ]; then
    # List all JARs in Maven's lib directory and extract groupId:artifactId patterns
    find "$MAVEN_HOME/lib" -name "*.jar" -type f 2>/dev/null | while read -r jar; do
      jar_name=$(basename "$jar" .jar)
      # Extract pattern (remove version numbers)
      # Example: maven-core-3.9.5.jar -> maven-core
      base_name=$(echo "$jar_name" | sed -E 's/-[0-9]+(\.[0-9]+)*(-[a-zA-Z0-9]+)?$//')
      
      # Common Maven groupIds
      echo "org.apache.maven:$base_name" >> "$TEMP_MAVEN_CORE"
      echo "org.apache.maven.plugins:$base_name" >> "$TEMP_MAVEN_CORE"
      echo "org.codehaus.plexus:$base_name" >> "$TEMP_MAVEN_CORE"
      echo "org.sonatype.plexus:$base_name" >> "$TEMP_MAVEN_CORE"
      echo "org.sonatype.sisu:$base_name" >> "$TEMP_MAVEN_CORE"
      echo "org.eclipse.sisu:$base_name" >> "$TEMP_MAVEN_CORE"
    done
    
    # Add common Maven infrastructure patterns
    cat >> "$TEMP_MAVEN_CORE" <<'EOF'
org.apache.maven:maven-
org.apache.maven.plugins:maven-
org.apache.maven.plugin-tools:maven-
org.apache.maven.resolver:maven-resolver-
org.apache.maven.shared:maven-
org.codehaus.plexus:plexus-
org.sonatype.plexus:plexus-
org.sonatype.sisu:sisu-
org.eclipse.sisu:org.eclipse.sisu.
com.google.inject:guice
javax.inject:javax.inject
aopalliance:aopalliance
org.slf4j:slf4j-
EOF
    
    sort -u "$TEMP_MAVEN_CORE" -o "$TEMP_MAVEN_CORE"
    MAVEN_CORE_PATTERNS=$(wc -l < "$TEMP_MAVEN_CORE" | tr -d ' ')
    echo "✓ Detected $MAVEN_CORE_PATTERNS Maven core dependency patterns"
  else
    # Fallback to minimal core patterns if Maven home not found
    cat > "$TEMP_MAVEN_CORE" <<'EOF'
org.apache.maven:maven-
org.apache.maven.plugins:maven-
org.codehaus.plexus:plexus-
org.sonatype.plexus:plexus-
org.sonatype.sisu:sisu-
org.eclipse.sisu:org.eclipse.sisu.
com.google.inject:guice
javax.inject:javax.inject
aopalliance:aopalliance
EOF
    MAVEN_CORE_PATTERNS=$(wc -l < "$TEMP_MAVEN_CORE" | tr -d ' ')
    echo "⚠️  Maven home not found, using $MAVEN_CORE_PATTERNS minimal core patterns"
  fi
  echo ""
  
  echo "📊 Total 'used' dependencies (declared + Maven-downloaded): $TOTAL_USED_WITH_MAVEN"
  echo ""
  
  # Calculate dependencies that are both used and installed (do this BEFORE creating unused report)
  TEMP_INTERSECTION="/tmp/maven_intersection_$$.txt"
  comm -12 <(sort "$TEMP_ALL_USED") <(sort "$TEMP_M2_FILE") > "$TEMP_INTERSECTION"
  INSTALLED_AND_USED=$(wc -l < "$TEMP_INTERSECTION")
  rm -f "$TEMP_INTERSECTION"
  
  # Find dependencies that are installed but not used
  # Exclude both: not in used list AND not matching Maven core patterns
  {
    echo "Dependency,Version"
    comm -23 <(sort "$TEMP_M2_FILE") <(sort "$TEMP_ALL_USED") | \
      while IFS=',' read -r dep ver; do
        # Check if this dependency matches any Maven core pattern
        is_core=false
        while IFS= read -r pattern; do
          if [[ "$dep" == $pattern* ]]; then
            is_core=true
            break
          fi
        done < "$TEMP_MAVEN_CORE"
        
        # Check if it's a Maven plugin (if configured to exclude them)
        is_plugin=false
        if [ "$EXCLUDE_MAVEN_PLUGINS" = true ]; then
          if [[ "$dep" =~ -plugin$ ]] || [[ "$dep" =~ -maven-plugin$ ]]; then
            is_plugin=true
          fi
        fi
        
        # Only include if it's not a core dependency and not a plugin
        if [ "$is_core" = false ] && [ "$is_plugin" = false ]; then
          echo "$dep,$ver"
        fi
      done
  } > "$UNUSED_OUTPUT_FILE"
  
  # If KEEP_LATEST_VERSION is enabled, filter out the latest version of each artifact
  if [ "$KEEP_LATEST_VERSION" = true ]; then
    TEMP_FILTERED="/tmp/maven_filtered_$$.txt"
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
        
        # Convert groupId to path (replace . with /)
        group_path=$(echo "$group_id" | tr '.' '/')
        
        # Construct path to the specific version directory
        dep_path="$M2_REPO/$group_path/$artifact_id/$version"
        
        if [ -d "$dep_path" ]; then
          # Get size in bytes (works on macOS)
          dep_size=$(du -sk "$dep_path" 2>/dev/null | cut -f1)
          if [ -n "$dep_size" ]; then
            TOTAL_SIZE_BYTES=$((TOTAL_SIZE_BYTES + dep_size))
            ((DEPS_WITH_SIZE++))
          fi
        fi
      fi
    done < "$UNUSED_OUTPUT_FILE"
    
    # Convert KB to human-readable format
    if [ $TOTAL_SIZE_BYTES -ge 1048576 ]; then
      # Convert to GB
      TOTAL_SIZE_DISPLAY=$(awk "BEGIN {printf \"%.2f GB\", $TOTAL_SIZE_BYTES/1048576}")
    elif [ $TOTAL_SIZE_BYTES -ge 1024 ]; then
      # Convert to MB
      TOTAL_SIZE_DISPLAY=$(awk "BEGIN {printf \"%.2f MB\", $TOTAL_SIZE_BYTES/1024}")
    else
      # Show in KB
      TOTAL_SIZE_DISPLAY="${TOTAL_SIZE_BYTES} KB"
    fi
    
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
    
    if [[ "$confirmation" == "yes" ]]; then
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
        
        # Extract groupId and artifactId
        if [[ "$dependency" =~ ^([^:]+):(.+)$ ]]; then
          group_id="${BASH_REMATCH[1]}"
          artifact_id="${BASH_REMATCH[2]}"
          
          # Convert groupId to path (replace . with /)
          group_path=$(echo "$group_id" | tr '.' '/')
          
          # Construct path to the specific version directory
          dep_path="$M2_REPO/$group_path/$artifact_id/$version"
          
          if [ -d "$dep_path" ]; then
            # Delete the version directory
            if rm -rf "$dep_path" 2>/dev/null; then
              ((DELETED_COUNT++))
              
              # Show progress every 100 deletions
              if [ $((DELETED_COUNT % 100)) -eq 0 ]; then
                echo "   ✓ Deleted $DELETED_COUNT dependencies..."
              fi
              
              # Check if artifact directory is now empty, delete it too
              artifact_path="$M2_REPO/$group_path/$artifact_id"
              if [ -d "$artifact_path" ] && [ -z "$(ls -A "$artifact_path" 2>/dev/null)" ]; then
                rm -rf "$artifact_path" 2>/dev/null || true
              fi
              
              # Check if group directory is now empty, delete it too
              if [ -d "$M2_REPO/$group_path" ] && [ -z "$(ls -A "$M2_REPO/$group_path" 2>/dev/null)" ]; then
                rm -rf "$M2_REPO/$group_path" 2>/dev/null || true
              fi
            else
              ((FAILED_COUNT++))
            fi
          fi
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
        REMAINING_COUNT=0
        
        while IFS=',' read -r dependency version; do
          # Skip header
          if [[ "$dependency" == "Dependency" ]]; then
            continue
          fi
          
          if [[ "$dependency" =~ ^([^:]+):(.+)$ ]]; then
            group_id="${BASH_REMATCH[1]}"
            artifact_id="${BASH_REMATCH[2]}"
            group_path=$(echo "$group_id" | tr '.' '/')
            dep_path="$M2_REPO/$group_path/$artifact_id/$version"
            
            if [ -d "$dep_path" ]; then
              ((REMAINING_COUNT++))
            fi
          fi
        done < "$UNUSED_OUTPUT_FILE"
        
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
          
          if [[ "$dependency" =~ ^([^:]+):(.+)$ ]]; then
            group_id="${BASH_REMATCH[1]}"
            artifact_id="${BASH_REMATCH[2]}"
            group_path=$(echo "$group_id" | tr '.' '/')
            dep_path="$M2_REPO/$group_path/$artifact_id/$version"
            
            if [ -d "$dep_path" ]; then
              if rm -rf "$dep_path" 2>/dev/null; then
                ((ATTEMPT_DELETED++))
                
                # Show progress every 100 deletions
                if [ $((ATTEMPT_DELETED % 100)) -eq 0 ]; then
                  echo "   ✓ Deleted $ATTEMPT_DELETED dependencies in this pass..."
                fi
                
                # Clean up empty parent directories
                artifact_path="$M2_REPO/$group_path/$artifact_id"
                if [ -d "$artifact_path" ] && [ -z "$(ls -A "$artifact_path" 2>/dev/null)" ]; then
                  rm -rf "$artifact_path" 2>/dev/null || true
                fi
                
                if [ -d "$M2_REPO/$group_path" ] && [ -z "$(ls -A "$M2_REPO/$group_path" 2>/dev/null)" ]; then
                  rm -rf "$M2_REPO/$group_path" 2>/dev/null || true
                fi
              else
                ((ATTEMPT_FAILED++))
              fi
            fi
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
    else
      echo "❌ Deletion cancelled by user"
      echo ""
    fi
    fi
  fi
fi

# Update last run timestamp
date +%s > "$LAST_RUN_FILE"

# Clean up temporary files
rm -f "$TEMP_FILE" "$TEMP_TREE_FILE" "$TEMP_M2_FILE"
