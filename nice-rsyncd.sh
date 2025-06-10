#!/usr/bin/env bash
set -euo pipefail

if ! command -v rsync &>/dev/null; then
  echo >&2 "ERROR: rsync not found"
  echo >&2 "Install on Debian/Ubuntu: sudo apt install rsync"
  exit 1
fi

################################################################################
# CONSTANTS
################################################################################

readonly MODE_LTR="ltr"
readonly MODE_MIRROR="mirror"
readonly SCRIPT_NAME="nice-rsyncd"

log() {
  local level=$1 message=$2
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$message"

  # Notify on these log levels
  case $level in
  ERROR | FATAL | CRITICAL | WARNING)
    notify_user "$level" "$message"
    ;;
  esac
}

notify_user() {
  local level=$1 message=$2

  if command -v notify-send &>/dev/null; then
    case $level in
    ERROR | FATAL | CRITICAL)
      notify-send -u critical "$SCRIPT_NAME [$level]" "$message"
      ;;
    WARNING)
      notify-send -u normal "$SCRIPT_NAME [$level]" "$message"
      ;;
    *)
      notify-send -u low "$SCRIPT_NAME [$level]" "$message"
      ;;
    esac
  fi
}

usage() {
  cat <<EOF
Simple rsync scheduler daemon - continuously syncs folders at specified intervals

This script runs forever, reading your config file and syncing all your folders
every X minutes. It's basically a poor man's backup daemon using rsync.
Great for keeping your shit backed up without having to remember to do it manually.

Usage: $0 <config.txt> <minutes>

    <config.txt> : config file with sync tasks
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
  local src=$1 dest=$2

  [[ -d $src ]] || {
    log ERROR "Source missing: $src"
    return 1
  }

  if [[ ! -d $dest ]]; then
    log INFO "Creating destination folder: $dest"
    mkdir -p "$dest"
  fi
}

check_file_conflicts() {
  local src=$1 dest=$2

  # Find files in destination that are newer than their source counterparts
  while IFS= read -r -d '' dest_file; do
    local rel_path="${dest_file#$dest/}"
    local src_file="$src/$rel_path"

    if [[ -f "$src_file" && "$dest_file" -nt "$src_file" ]]; then
      log WARNING "File conflict detected: $dest_file (destination newer than $src_file)"
      return 0
    fi
  done < <(find "$dest" -type f -print0 2>/dev/null)

  return 1
}

run_sync() {
  local src=$1 dest=$2 mode=$3

  # Check for conflicts before syncing
  if check_file_conflicts "$src" "$dest"; then
    log WARNING "Conflicts detected in $dest - some files may be skipped"
  fi

  local cmd=(ionice -c2 -n7 rsync -aAXv --info=progress2 --update)

  if [[ $mode == "$MODE_MIRROR" ]]; then
    cmd+=(--delete)
  fi

  log INFO "Starting sync ($mode): $src -> $dest"

  local rsync_output
  rsync_output=$("${cmd[@]}" "${src}/" "${dest}/" 2>&1) || {
    log ERROR "rsync failed for $src -> $dest"
    return 1
  }

  echo "$rsync_output"
  log INFO "Finished sync ($mode): $src"
}

cleanup() {
  log INFO "$SCRIPT_NAME shutting down"
  exit 0
}

trap cleanup INT TERM

################################################################################
# MAIN LOGIC
################################################################################

if [[ $# -lt 2 || $1 == "-h" || $1 == "--help" ]]; then
  usage
fi

CONFIG_FILE=$1
SYNC_INTERVAL=$2

if [[ ! $SYNC_INTERVAL =~ ^[0-9]+$ ]]; then
  log ERROR "Invalid interval: $SYNC_INTERVAL (must be a number)"
  exit 1
fi

if [[ ! -f $CONFIG_FILE ]]; then
  log ERROR "Config file not found: $CONFIG_FILE"
  exit 1
fi

# Store config in simple arrays
SOURCES=()
DESTS=()
MODES=()

while IFS= read -r raw; do
  if [[ -z $raw ]] || [[ $raw =~ ^[[:space:]]*# ]]; then
    continue
  fi

  read -r srcdest mode <<<"$raw"
  IFS=':' read -r SRC DEST <<<"$srcdest"

  SRC=${SRC%/}
  DEST=${DEST%/}

  if ! validate_and_create_dest "$SRC" "$DEST"; then
    continue
  fi

  SOURCES+=("$SRC")
  DESTS+=("$DEST")
  MODES+=("$mode")

  log INFO "Added sync task: $SRC -> $DEST ($mode)"

done <"$CONFIG_FILE"

log INFO "Starting sync daemon - will sync every $SYNC_INTERVAL minutes"

while true; do
  log INFO "Starting sync cycle"

  for i in "${!SOURCES[@]}"; do
    run_sync "${SOURCES[$i]}" "${DESTS[$i]}" "${MODES[$i]}"
  done

  log INFO "Sync cycle complete - sleeping for $SYNC_INTERVAL minutes"
  sleep $((SYNC_INTERVAL * 60))
done
