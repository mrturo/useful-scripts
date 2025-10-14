#!/bin/bash
# Maven Wrapper Proxy
#
# This script acts as a proxy for Maven commands, automatically using Maven Wrapper
# when available or creating it when needed.
#
# FUNCTIONALITY:
# 1. Checks if ./mvnw exists in current directory
# 2. If exists: executes ./mvnw with all provided arguments
# 3. If not exists: creates Maven Wrapper using 'mvn wrapper:wrapper'
# 4. After creation: executes the original command with ./mvnw
#
# Usage: mvn_proxy.sh [maven-arguments...]
# Example: mvn_proxy.sh clean install
#          mvn_proxy.sh dependency:tree
#          mvn_proxy.sh -v

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if mvnw exists in current directory
if [ -f "./mvnw" ]; then
    print_info "Maven Wrapper found. Executing: caffeinate -d -m -- ./mvnw $*"
    caffeinate -d -m -- ./mvnw "$@"
else
    print_warn "Maven Wrapper not found in current directory."
    
    # Check if mvn is available
    if ! command -v mvn &> /dev/null; then
        print_error "Maven (mvn) is not installed or not in PATH."
        print_error "Please install Maven first."
        exit 1
    fi
    
    # Check if pom.xml exists
    if [ ! -f "pom.xml" ]; then
        print_error "No pom.xml found in current directory."
        print_error "Maven Wrapper can only be created in a Maven project."
        exit 1
    fi
    
    print_info "Creating Maven Wrapper using check_maven_java_version.sh..."
    
    # Find the check_maven_java_version.sh script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CHECK_SCRIPT="$SCRIPT_DIR/check_maven_java_version.sh"
    
    if [ ! -f "$CHECK_SCRIPT" ]; then
        print_error "check_maven_java_version.sh not found at: $CHECK_SCRIPT"
        print_error "Falling back to simple wrapper creation..."
        if caffeinate -d -m -- mvn wrapper:wrapper; then
            chmod +x mvnw 2>/dev/null || true
            print_info "Maven Wrapper created successfully!"
        else
            print_error "Failed to create Maven Wrapper."
            exit 1
        fi
    else
        # Execute check_maven_java_version.sh with caffeinate
        if caffeinate -d -m -- bash "$CHECK_SCRIPT"; then
            print_info "Maven Wrapper created successfully!"
        else
            print_error "Failed to create Maven Wrapper."
            exit 1
        fi
    fi
    
    # Execute the original command with mvnw
    if [ $# -gt 0 ]; then
        print_info "Executing: caffeinate -d -m -- ./mvnw $*"
        caffeinate -d -m -- ./mvnw "$@"
    else
        print_info "Maven Wrapper is ready. No command to execute."
    fi
fi
