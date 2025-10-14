#!/bin/bash
# check_maven_java_version.sh
# Checks the Java version in pom.xml (Maven) and syncs it with the .java-version file at the repository root.
# Also detects Maven version from pom.xml and generates/updates Maven wrapper with that version.

set -e
# Show error details if any error occurs
trap 'rc=$?; if [ $rc -ne 0 ]; then echo "[PWD: $(pwd)] Error at line $LINENO. Exit code: $rc"; fi' ERR

POM_FILE="pom.xml"
JAVA_VERSION_FILE=".java-version"

# --- Java/Maven project validation ---
if [ ! -f "$POM_FILE" ]; then
  echo "[ERROR] No pom.xml found. This is not a Java/Maven project. Exiting."
  exit 0
fi
if ! grep -q '<project' "$POM_FILE" || ! grep -q '<groupId' "$POM_FILE"; then
  echo "[ERROR] pom.xml does not appear to be a valid Maven project file. Exiting."
  exit 0
fi
# --- End validation ---

# Check if pom.xml exists in the current directory
echo "Trying to access $POM_FILE in: $(pwd)"
ls -l "$POM_FILE" 2>/dev/null || echo "$POM_FILE could not be listed."
if [ ! -f "$POM_FILE" ]; then
  echo "[DEBUG] $POM_FILE not found in the current directory: $(pwd)"
fi

echo "[DEBUG] Searching for <maven.compiler.source> or <java.version>..."
set +e
JAVA_VERSION_RAW=$(grep -Eo '<(maven\.compiler\.source|java\.version)>[0-9]+(\.[0-9]+)?(\.[0-9]+)?<' "$POM_FILE" | head -n1 | grep -Eo '[0-9]+(\.[0-9]+)?(\.[0-9]+)?')
set -e
echo "[DEBUG] JAVA_VERSION_RAW after first attempt: '$JAVA_VERSION_RAW'"

if [ -z "$JAVA_VERSION_RAW" ]; then
  echo "[DEBUG] Searching for <source>, <target> or <release> in maven-compiler-plugin..."
  set +e
  JAVA_VERSION_RAW=$(awk '/maven-compiler-plugin/,/<\/plugin>/' "$POM_FILE" | grep -Eo '<(source|target|release)>[0-9]+(\.[0-9]+)?(\.[0-9]+)?<' | head -n1 | grep -Eo '[0-9]+(\.[0-9]+)?(\.[0-9]+)?')
  set -e
  echo "[DEBUG] JAVA_VERSION_RAW after second attempt: '$JAVA_VERSION_RAW'"
fi

if [ -z "$JAVA_VERSION_RAW" ]; then
  echo "\n--- Java version not found. maven-compiler-plugin block in $POM_FILE: ---"
  awk '/maven-compiler-plugin/,/<\/plugin>/' "$POM_FILE"
  echo "--- End of maven-compiler-plugin block ---\n"
fi

if [ ! -f "$POM_FILE" ]; then
  echo "[ERROR] $POM_FILE not found."
  exit 1
fi
if [ -z "$JAVA_VERSION_RAW" ]; then
  echo "[ERROR] Could not extract Java version."
  exit 1
fi

JAVA_VERSION=$(echo "$JAVA_VERSION_RAW" | cut -d. -f1)
echo "Java version found in pom.xml: $JAVA_VERSION_RAW (using major version: $JAVA_VERSION)"

if [ ! -f "$JAVA_VERSION_FILE" ]; then
  echo "$JAVA_VERSION" > "$JAVA_VERSION_FILE"
  echo "File $JAVA_VERSION_FILE created with version $JAVA_VERSION."
else
  CURRENT_VERSION=$(cat "$JAVA_VERSION_FILE" | tr -d '[:space:]')

  if [ "$CURRENT_VERSION" = "$JAVA_VERSION" ]; then
    echo "The version in $JAVA_VERSION_FILE already matches pom.xml ($JAVA_VERSION)."
  else
    echo "$JAVA_VERSION" > "$JAVA_VERSION_FILE"
    echo "Updated $JAVA_VERSION_FILE to version $JAVA_VERSION."
  fi
fi

# --- Maven Version Detection and Wrapper Setup ---
echo "\n[INFO] Checking Maven version configuration..."

MAVEN_VERSION_RAW=""

# Try to find Maven version in properties
echo "[DEBUG] Searching for <maven.version> property..."
set +e
MAVEN_VERSION_RAW=$(grep -Eo '<maven\.version>[0-9]+\.[0-9]+\.[0-9]+<' "$POM_FILE" | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
set -e
echo "[DEBUG] MAVEN_VERSION_RAW from properties: '$MAVEN_VERSION_RAW'"

# If not found in properties, try maven-wrapper-plugin configuration
if [ -z "$MAVEN_VERSION_RAW" ]; then
  echo "[DEBUG] Searching for Maven version in maven-wrapper-plugin..."
  set +e
  MAVEN_VERSION_RAW=$(awk '/maven-wrapper-plugin/,/<\/plugin>/' "$POM_FILE" | grep -Eo '<mavenVersion>[0-9]+\.[0-9]+\.[0-9]+<' | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
  set -e
  echo "[DEBUG] MAVEN_VERSION_RAW from wrapper plugin: '$MAVEN_VERSION_RAW'"
fi

# If still not found, check existing .mvn/wrapper/maven-wrapper.properties
if [ -z "$MAVEN_VERSION_RAW" ] && [ -f ".mvn/wrapper/maven-wrapper.properties" ]; then
  echo "[DEBUG] Checking existing maven-wrapper.properties..."
  set +e
  MAVEN_VERSION_RAW=$(grep 'distributionUrl' ".mvn/wrapper/maven-wrapper.properties" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  set -e
  echo "[DEBUG] MAVEN_VERSION_RAW from existing wrapper: '$MAVEN_VERSION_RAW'"
fi

# Default to latest stable version if not found
if [ -z "$MAVEN_VERSION_RAW" ]; then
  MAVEN_VERSION_RAW="3.9.9"
  echo "[INFO] No Maven version specified in pom.xml. Using default: $MAVEN_VERSION_RAW"
else
  echo "[INFO] Maven version found: $MAVEN_VERSION_RAW"
fi

# Check if mvn command is available
if ! command -v mvn &> /dev/null; then
  echo "[WARNING] 'mvn' command not found. Skipping Maven wrapper generation."
  echo "[INFO] Please install Maven or add it to your PATH to generate the wrapper."
  exit 0
fi

# Generate or update Maven wrapper
echo "[INFO] Generating/updating Maven wrapper with version $MAVEN_VERSION_RAW..."
if mvn wrapper:wrapper -Dmaven="$MAVEN_VERSION_RAW"; then
  echo "[SUCCESS] Maven wrapper configured with version $MAVEN_VERSION_RAW"
  
  # Make wrapper scripts executable
  if [ -f "mvnw" ]; then
    chmod +x mvnw
    echo "[INFO] Made mvnw executable"
  fi
  if [ -f "mvnw.cmd" ]; then
    chmod +x mvnw.cmd
    echo "[INFO] Made mvnw.cmd executable"
  fi
else
  echo "[WARNING] Failed to generate Maven wrapper. You may need to run this manually."
  exit 0
fi