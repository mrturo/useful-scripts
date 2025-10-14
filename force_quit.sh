#!/usr/bin/env bash
# Force-quit visible macOS apps (like Force Quit) while respecting real process trees.
# Runs up to 3 passes to catch apps that respawn or resist.
# Bash 3.2 compatible (macOS default). No associative arrays, no 'mapfile'.

set -euo pipefail

# === Ignore list (exact process names as shown by System Events or ps/pgrep) ===
IGNORE_APPS=(
  "Finder"
  "Terminal"
  "iTerm2"
  "Cisco Secure Client"
  "System Settings"
  "System Preferences"
)

# ===== Utilities =====
in_ignore() {
  local name="$1"
  for ig in "${IGNORE_APPS[@]}"; do
    [[ "$ig" == "$name" ]] && return 0
  done
  return 1
}

is_running_pid() { /bin/ps -p "$1" >/dev/null 2>&1; }
is_running_name() { /usr/bin/pgrep -ax "$1" >/dev/null 2>&1; }

graceful_quit_name() {
  local name="$1"
  /usr/bin/osascript -e 'tell application "'"$name"'" to quit' >/dev/null 2>&1 || true
}

force_kill_pid() {
  local pid="$1"
  /bin/kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    is_running_pid "$pid" || return 0
    /bin/sleep 0.2
  done
  /bin/kill -KILL "$pid" 2>/dev/null || true
}

# === Visible apps (robust): returns comma-separated "Name|PID, Name|PID, ..." ===
read_visible_name_pid_lines() {
/usr/bin/osascript <<'APPLESCRIPT' | tr -d '\r'
set out to {}
tell application "System Events"
  -- Use 'visible is true' to better match the Force Quit panel
  repeat with p in (processes where visible is true)
    set end of out to (name of p as text) & "|" & (unix id of p as text)
  end repeat
end tell
set AppleScript's text item delimiters to ", "
return out as text
APPLESCRIPT
}

# === Fallback visible apps using LaunchServices (names only) ===
fallback_visible_names() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsappinfo list 2>/dev/null \
  | /usr/bin/awk -F'"' '/"name"/{print $4}' \
  | /usr/bin/sed 's/^ *//;s/ *$//' \
  | /usr/bin/grep -v '^$' \
  | /usr/bin/sort -u
}

# Get unique visible app names (like Force Quit), with fallback when AppleScript is insufficient
list_visible_apps_unique() {
  local raw lines_count names
  raw=$(read_visible_name_pid_lines | /usr/bin/sed 's/, /\n/g')

  # Count how many names AppleScript yielded
  lines_count=$(printf '%s\n' "$raw" | /usr/bin/awk -F'|' '{print $1}' | /usr/bin/grep -v '^$' | /usr/bin/wc -l | /usr/bin/awk '{print $1}')
  if [ "${lines_count:-0}" -lt 2 ]; then
    # Fallback to LaunchServices if AppleScript returns too few items
    names=$(fallback_visible_names)
  else
    names=$(printf '%s\n' "$raw" | /usr/bin/awk -F'|' '{print $1}' | /usr/bin/sed 's/^ *//;s/ *$//' | /usr/bin/grep -v '^$' | /usr/bin/sort -u)
  fi

  printf '%s\n' "$names"
}

# Build process table: prints lines "PID PPID COMM"
build_ps_table() {
  /bin/ps -axo pid=,ppid=,comm= \
  | /usr/bin/awk '{pid=$1;ppid=$2;$1="";$2="";sub(/^  */,"");print pid" "ppid" "$0}'
}

# Collect descendants (including root) for a PID; stops walking under ignored COMM
collect_descendants() {
  local root="$1"
  # Get script directory
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local tmp_dir="$script_dir/tmp"
  mkdir -p "$tmp_dir"
 
  local visited="$tmp_dir/fq.visited.$$"
  local queue="$tmp_dir/fq.queue.$$"
  : >"$visited"; : >"$queue"; echo "$root" >>"$queue"

  while IFS= read -r line; do
    echo "$line"
  done < <(build_ps_table) >"$tmp_dir/fq.ps.$$"

  while IFS= read -r current || [[ -n "${current-}" ]]; do
    [[ -z "$current" ]] && continue
    /usr/bin/grep -qx "$current" "$visited" 2>/dev/null && continue
    echo "$current" >>"$visited"

    # If current COMM is ignored, do not enqueue its children
    local comm
    comm=$(/usr/bin/awk -v P="$current" '$1==P{ $1="";$2=""; sub(/^ /,""); print }' "$tmp_dir/fq.ps.$$")
    if in_ignore "$comm"; then
      continue
    fi

    /usr/bin/awk -v P="$current" '{ if ($2==P) print $1 }' "$tmp_dir/fq.ps.$$" >>"$queue"
  done <"$queue"

  cat "$visited"

  /bin/rm -f "$visited" "$queue" "$tmp_dir/fq.ps.$$" 2>/dev/null || true
}

# Compute ancestry depth for PIDs to order children before parents (post-order)
compute_depths() {
  # stdin: "PID" lines; stdout: "depth PID"
  # Get script directory
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local tmp_dir="$script_dir/tmp"
  mkdir -p "$tmp_dir"
 
  local tmp="$tmp_dir/fq.ps2.$$"
  build_ps_table >"$tmp"
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local d=0 cur="$pid" p
    while : ; do
      p=$(/usr/bin/awk -v C="$cur" '$1==C{print $2}' "$tmp")
      [[ -z "$p" || "$p" -le 1 ]] && break
      d=$((d+1)); cur="$p"
    done
    echo "$d $pid"
  done
  /bin/rm -f "$tmp" 2>/dev/null || true
}

close_by_name_postorder() {
  local name="$1"

  if in_ignore "$name"; then
    echo "⏭ Ignoring app: $name"
    return 0
  fi

  local pids
  pids=$(/usr/bin/pgrep -ax "$name" | /usr/bin/awk '{print $1}' || true)
  [[ -z "$pids" ]] && return 0

  # Aggregate subtree PIDs for all roots of this app
  # Get script directory
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local tmp_dir="$script_dir/tmp"
  mkdir -p "$tmp_dir"
 
  local all="$tmp_dir/fq.all.$$"; : >"$all"
  local pid
  for pid in $pids; do
    collect_descendants "$pid" >>"$all"
  done
  /usr/bin/sort -u "$all" > "${all}.u"

  echo "▶ Closing app: $name"
  graceful_quit_name "$name"

  local closed=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! is_running_name "$name"; then
      closed=1; echo "✅ Gracefully closed: $name"; break
    fi
    /bin/sleep 0.3
  done

  if [[ $closed -eq 0 ]]; then
    # Post-order kill: children (greater depth) first
    local ordered="$tmp_dir/fq.ordered.$$"
    compute_depths < "${all}.u" | /usr/bin/sort -nr -k1,1 | /usr/bin/awk '{print $2}' > "$ordered"

    while IFS= read -r kpid; do
      [[ -z "$kpid" ]] && continue
      is_running_pid "$kpid" || continue
      local kcomm
      kcomm=$(/bin/ps -o comm= -p "$kpid" 2>/dev/null || true)
      if in_ignore "$kcomm"; then
        echo "⏭ Skipping ignored process: $kcomm ($kpid)"
        continue
      fi
      force_kill_pid "$kpid"
    done <"$ordered"

    if is_running_name "$name"; then
      echo "⚠️ Still running after forced kill: $name"
    else
      echo "🧹 Force-closed: $name"
    fi

    /bin/rm -f "$ordered" 2>/dev/null || true
  fi

  /bin/rm -f "$all" "${all}.u" 2>/dev/null || true
}

# ===== Main (3 passes) =====
passes=3
for pass in $(/bin/echo 1 2 3 | /usr/bin/awk -v n="$passes" '{for(i=1;i<=n;i++)print i}'); do
  echo ""
  echo "===== Force-quit pass $pass/$passes ====="
  apps=$(list_visible_apps_unique)

  # Debug: show detected apps per pass
  echo "Detected apps:"
  echo "$apps" | nl -ba
  echo "-----------------------------------------"

  if [[ -z "$apps" ]]; then
    echo "No visible apps detected."
    continue
  fi

  echo "$apps" | while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    close_by_name_postorder "$app"
  done
done

# ===== Final report =====
echo ""
echo "===== Remaining visible apps after all passes ====="
remaining=$(/usr/bin/osascript -e 'tell application "System Events" to get name of (processes where visible is true)' | tr -d '\r' | sed 's/, /\n/g' | sed 's/^ *//;s/ *$//' | sort -u)

if [[ -z "$remaining" ]]; then
  echo "✅ No visible apps are still running."
else
  echo "$remaining" | while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    echo "⚠️ Still open: $app"
  done
fi