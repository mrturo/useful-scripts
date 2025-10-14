#!/bin/bash
# check_maven_java_version.sh
# Checks the Java version in pom.xml (Maven) and syncs it with the .java-version file at the repository root.

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
  exit 0
fi

CURRENT_VERSION=$(cat "$JAVA_VERSION_FILE" | tr -d '[:space:]')

if [ "$CURRENT_VERSION" = "$JAVA_VERSION" ]; then
  echo "The version in $JAVA_VERSION_FILE already matches pom.xml ($JAVA_VERSION)."
  exit 0
else
  echo "$JAVA_VERSION" > "$JAVA_VERSION_FILE"
  echo "Updated $JAVA_VERSION_FILE to version $JAVA_VERSION."
  exit 0
fi