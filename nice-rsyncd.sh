#!/usr/bin/env bash
# Bash shebang - tells system to run this with bash

# Exit on any error, undefined variables, or pipe failures
set -euo pipefail

# Check if rsync is installed - we need it for this whole thing to work
if ! command -v rsync &>/dev/null; then
  echo >&2 "ERROR: rsync not found"
  echo >&2 "Install on Debian/Ubuntu: sudo apt install rsync"
  exit 1
fi

# Check if telegram-logger-client is available for notifications
if ! command -v telegram-logger-client &>/dev/null; then
  echo >&2 "WARNING: telegram-logger-client not found - notifications will be disabled"
  echo >&2 "Install with: pipx install telegram-logger-client"
  echo >&2 "Documentation: https://github.com/psyb0t/py-telegram-logger-client"
fi

################################################################################
# CONSTANTS - these don't change during script execution
################################################################################

# Two sync modes: ltr = left-to-right (copy only), mirror = exact copy with deletions
readonly MODE_LTR="ltr"
readonly MODE_MIRROR="mirror"
readonly SCRIPT_NAME="nice-rsyncd"

log() {
  # Function to log messages with timestamps and optional desktop notifications
  local level=$1 message=$2

  # Print timestamped log message to console
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$message"

  # Send desktop notifications for important log levels (errors, warnings)
  case $level in
  ERROR | FATAL | CRITICAL | WARNING)
    notify_user "$level" "$message"
    ;;
  esac
}

notify_user() {
  # Send notifications via telegram-logger-client instead of desktop notifications
  local level=$1 message=$2

  # Check if telegram-logger-client is available
  if command -v telegram-logger-client &>/dev/null; then
    # Convert log levels to telegram-logger format (lowercase)
    local tg_level
    case $level in
    ERROR | FATAL | CRITICAL)
      tg_level="error"
      ;;
    WARNING)
      tg_level="warning"
      ;;
    *)
      tg_level="info"
      ;;
    esac

    # Send to telegram (suppress output to avoid log spam)
    telegram-logger-client --caller="$SCRIPT_NAME" --level="$tg_level" --message="$message" &>/dev/null || true
  fi
}

usage() {
  # Display help text explaining how to use this script
  cat <<EOF
Simple rsync scheduler daemon - continuously syncs folders at specified intervals

This script runs forever, reading your config file and syncing all your folders
every X minutes. It's basically a poor man's backup daemon using rsync.
Great for keeping your shit backed up without having to remember to do it manually.

Usage: $0 <config.txt> <minutes>

    <config.txt> : config file with sync tasks (one per line)
    <minutes>    : how often to sync (in minutes)

Config line format (whitespace-separated):
    <source>:<dest>   <mode>

    <mode> : $MODE_LTR  (copy only) | $MODE_MIRROR  (mirror --delete)

Example:
    $0 sync.conf 30

Config file example:
    /home/syp/Documents:/mnt/backup/docs   $MODE_MIRROR
    /home/syp/projects:/mnt/backup/projects   $MODE_LTR
EOF
  exit 0
}

validate_and_create_dest() {
  # Check if source exists and create destination if needed
  local src=$1 dest=$2

  # Make sure source directory actually exists
  [[ -d $src ]] || {
    log ERROR "Source missing: $src"
    return 1
  }

  # Create destination directory if it doesn't exist
  if [[ ! -d $dest ]]; then
    log INFO "Creating destination folder: $dest"
    mkdir -p "$dest"
  fi
}

check_file_conflicts() {
  # Look for files in destination that are newer than their source versions
  # This helps detect potential conflicts before syncing
  local src=$1 dest=$2

  # Find all files in destination and check if they're newer than source
  while IFS= read -r -d '' dest_file; do
    # Get relative path by removing destination prefix
    local rel_path="${dest_file#$dest/}"
    # Build corresponding source file path
    local src_file="$src/$rel_path"

    # Check if source file exists and destination is newer
    if [[ -f "$src_file" && "$dest_file" -nt "$src_file" ]]; then
      log WARNING "File conflict detected: $dest_file (destination newer than $src_file)"
      return 0 # Found at least one conflict
    fi
  done < <(find "$dest" -type f -print0 2>/dev/null)

  return 1 # No conflicts found
}

run_sync() {
  # Main sync function - handles both ltr and mirror modes
  local src=$1 dest=$2 mode=$3

  # Only check for conflicts in ltr mode - mirror mode doesn't give a shit about newer files
  # Mirror mode will overwrite everything anyway, so conflicts don't matter
  if [[ $mode == "$MODE_LTR" ]] && check_file_conflicts "$src" "$dest"; then
    log WARNING "Conflicts detected in $dest - some files may be skipped"
  fi

  # Build rsync command with base options:
  # ionice -c2 -n7 = lower I/O priority so it doesn't hog system resources
  # -a = archive mode (preserves permissions, timestamps, etc.)
  # -A = preserve ACLs (Access Control Lists)
  # -X = preserve extended attributes
  # -v = verbose output
  # --info=progress2 = show progress info
  local cmd=(ionice -c2 -n7 rsync -aAXv --info=progress2)

  # Configure mode-specific options
  if [[ $mode == "$MODE_MIRROR" ]]; then
    # Mirror mode: force overwrite everything and delete extra files
    cmd+=(--delete)
  else
    # LTR mode: only update files that are older in destination
    cmd+=(--update)
  fi

  log INFO "Starting sync ($mode): $src -> $dest"

  # Run rsync and capture output
  local rsync_output
  rsync_output=$("${cmd[@]}" "${src}/" "${dest}/" 2>&1) || {
    log ERROR "rsync failed for $src -> $dest"
    return 1
  }

  # Show rsync output to user
  echo "$rsync_output"
  log INFO "Finished sync ($mode): $src"
}

cleanup() {
  # Clean shutdown function - called when script receives SIGINT or SIGTERM
  log INFO "$SCRIPT_NAME shutting down"
  exit 0
}

# Set up signal handlers to call cleanup() on Ctrl+C or kill signals
trap cleanup INT TERM

################################################################################
# MAIN LOGIC - where the actual work happens
################################################################################

# Check command line arguments - need at least config file and interval
if [[ $# -lt 2 || $1 == "-h" || $1 == "--help" ]]; then
  usage
fi

# Get command line arguments
CONFIG_FILE=$1
SYNC_INTERVAL=$2

# Validate that sync interval is a number
if [[ ! $SYNC_INTERVAL =~ ^[0-9]+$ ]]; then
  log ERROR "Invalid interval: $SYNC_INTERVAL (must be a number)"
  exit 1
fi

# Make sure config file exists
if [[ ! -f $CONFIG_FILE ]]; then
  log ERROR "Config file not found: $CONFIG_FILE"
  exit 1
fi

# Arrays to store parsed config data
SOURCES=() # Source directories
DESTS=()   # Destination directories
MODES=()   # Sync modes (ltr or mirror)

# Parse config file line by line
while IFS= read -r raw; do
  # Skip empty lines and comments (lines starting with #, optionally with whitespace)
  if [[ -z $raw ]] || [[ $raw =~ ^[[:space:]]*# ]]; then
    continue
  fi

  # Parse line format: "source:dest mode"
  read -r srcdest mode <<<"$raw"
  # Split source:dest on the colon
  IFS=':' read -r SRC DEST <<<"$srcdest"

  # Remove trailing slashes to normalize paths
  SRC=${SRC%/}
  DEST=${DEST%/}

  # Validate paths and create destination if needed
  if ! validate_and_create_dest "$SRC" "$DEST"; then
    continue # Skip this entry if validation failed
  fi

  # Add to our arrays
  SOURCES+=("$SRC")
  DESTS+=("$DEST")
  MODES+=("$mode")

  log INFO "Added sync task: $SRC -> $DEST ($mode)"

done <"$CONFIG_FILE"

log INFO "Starting sync daemon - will sync every $SYNC_INTERVAL minutes"

# Main daemon loop - runs forever until killed
while true; do
  log INFO "Starting sync cycle"

  # Run sync for each configured source/dest pair
  for i in "${!SOURCES[@]}"; do
    run_sync "${SOURCES[$i]}" "${DESTS[$i]}" "${MODES[$i]}"
  done

  log INFO "Sync cycle complete - sleeping for $SYNC_INTERVAL minutes"
  # Sleep for specified interval (convert minutes to seconds)
  sleep $((SYNC_INTERVAL * 60))
done
