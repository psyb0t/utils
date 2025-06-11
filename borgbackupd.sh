#!/bin/bash

set -euo pipefail

# ============================================================================
# GLOBAL VARIABLES AND CONSTANTS
# ============================================================================

SCRIPT_NAME=$(basename "$0")
CONFIG_FILE=""
INTERVAL_MINUTES=""
CONTINUOUS_MODE=false
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
MIN_FREE_DISK_GB=10

# Log level constants
LOG_LEVEL_DEBUG="DEBUG"
LOG_LEVEL_INFO="INFO"
LOG_LEVEL_WARNING="WARNING"
LOG_LEVEL_ERROR="ERROR"
LOG_LEVEL_FATAL="FATAL"

# Arrays to hold all the backup jobs read from the config file
declare -a BACKUP_SOURCES=()
declare -a BACKUP_DESTS=()
declare -a BACKUP_RETENTIONS=()
declare -a BACKUP_EXCLUDES=() # Stores the raw comma-separated exclude patterns

# ============================================================================
# LOG LEVEL CONFIGURATION - CHANGE THIS TO CONTROL VERBOSITY
# ============================================================================
# Available log levels (in order of verbosity):
# DEBUG (most verbose) -> INFO -> WARNING -> ERROR -> FATAL (least verbose)
CURRENT_LOG_LEVEL=$LOG_LEVEL_DEBUG

# Log level hierarchy for filtering
declare -A LOG_LEVELS=(
    ["DEBUG"]=0
    ["INFO"]=1
    ["WARNING"]=2
    ["ERROR"]=3
    ["FATAL"]=4
)

# ============================================================================
# LOGGING AND NOTIFICATION FUNCTIONS
# ============================================================================

log() {
    # Function to log messages with timestamps and optional Telegram notifications
    local level=$1 message=$2

    # Check if this log level should be shown
    local current_level_num=${LOG_LEVELS[$CURRENT_LOG_LEVEL]}
    local msg_level_num=${LOG_LEVELS[$level]}

    # Only show messages at or above the current log level
    if [[ $msg_level_num -ge $current_level_num ]]; then
        # Print timestamped log message to console
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$message"
    fi

    # Send Telegram notifications for important log levels (regardless of log level setting)
    case $level in
    ERROR | FATAL | CRITICAL | WARNING)
        notify_user "$level" "$message"
        ;;
    esac

    # Exit immediately if this is a fatal error
    if [[ "$level" == "$LOG_LEVEL_FATAL" ]]; then
        exit 1
    fi
}

debug_log() {
    # Convenience function for debug logging
    log "$LOG_LEVEL_DEBUG" "$1"
}

notify_user() {
    # Send notifications via telegram-logger-client
    local level=$1 message=$2

    debug_log "Attempting to send Telegram notification: level=$level"

    # Check if telegram-logger-client is available
    if command -v telegram-logger-client &>/dev/null; then
        debug_log "telegram-logger-client found, sending notification"
        # Convert log levels to telegram-logger format
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

        debug_log "Sending to telegram with level: $tg_level"
        # Send to telegram (suppress output to avoid log spam)
        telegram-logger-client --caller="$SCRIPT_NAME" --level="$tg_level" --message="$message" &>/dev/null || true
        debug_log "Telegram notification sent (or failed silently)"
    else
        debug_log "telegram-logger-client not available, skipping notification"
    fi
}

# ============================================================================
# SIGNAL HANDLING FOR CONTINUOUS MODE
# ============================================================================

handle_signal() {
    local signal=$1
    log "$LOG_LEVEL_INFO" "Received signal $signal, shutting down gracefully..."
    debug_log "Signal handler triggered: $signal"

    # Kill any running borg processes
    pkill -f "borg create\|borg prune\|borg compact" 2>/dev/null || true

    log "$LOG_LEVEL_INFO" "Backup script stopped"
    exit 0
}

setup_signal_handlers() {
    debug_log "Setting up signal handlers for continuous mode"
    trap 'handle_signal SIGTERM' TERM
    trap 'handle_signal SIGINT' INT
    trap 'handle_signal SIGHUP' HUP
}

# ============================================================================
# HELP AND VALIDATION FUNCTIONS
# ============================================================================

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME <config_file> [interval_minutes]

Arguments:
    config_file            Path to backup config file (required)
    interval_minutes       Run continuously with this interval in minutes (optional)
                           If not provided, runs once and exits

Config file format (retention period is REQUIRED for each line):
    source_path:destination_path --retention-period=N [--exclude=pattern1,pattern2,...]

Examples:
    # Run once
    $SCRIPT_NAME backup.conf

    # Run continuously every 30 minutes
    $SCRIPT_NAME backup.conf 30

    /home/user/docs:/backup/docs --retention-period=30
    /home/user/code:/backup/code --retention-period=60 --exclude=*.pyc,**/venv,**/node_modules
    /var/log:/backup/logs --retention-period=7
    /home/user/.ssh:/backup/ssh --retention-period=365 --exclude=/home/user/.ssh/id_rsa

Required options per line:
    --retention-period=N    Days to keep backups for this source (MANDATORY)

Optional options per line:
    --exclude=patterns      Comma-separated list of patterns to exclude

The script creates destination directories and borg repos if they don't exist.

EOF
}

check_borg_installed() {
    # Verify that borg is installed and available
    debug_log "Checking if borg is installed"

    if ! command -v borg &>/dev/null; then
        debug_log "borg command not found in PATH"
        log "$LOG_LEVEL_FATAL" "borg is not installed or not in PATH

Installation instructions:

Ubuntu/Debian:
    sudo apt update && sudo apt install borgbackup

Arch Linux:
    sudo pacman -S borg

Fedora/RHEL/CentOS:
    sudo dnf install borgbackup

macOS (Homebrew):
    brew install borgbackup

From source/pip:
    pip install borgbackup

After installation, make sure 'borg' is available in your PATH."
    fi

    debug_log "borg found in PATH: $(which borg)"
    debug_log "borg version: $(borg --version 2>/dev/null || echo 'version check failed')"
}

check_telegram_logger_client_installed() {
    # Check if telegram-logger-client is available for notifications
    debug_log "Checking if telegram-logger-client is installed"

    if ! command -v telegram-logger-client &>/dev/null; then
        debug_log "telegram-logger-client not found in PATH"
        echo >&2 "WARNING: telegram-logger-client not found - notifications will be disabled"
        echo >&2 "Install with: pipx install telegram-logger-client"
        echo >&2 "Documentation: https://github.com/psyb0t/py-telegram-logger-client"
    else
        debug_log "telegram-logger-client found in PATH: $(which telegram-logger-client)"
    fi
}

check_disk_space() {
    # Check if destination has enough free space before backup
    local dest_path="$1"

    debug_log "Checking disk space for destination: $dest_path"

    # Determine which directory to check
    local dest_dir
    if [[ -d "$dest_path" ]]; then
        dest_dir="$dest_path"
        debug_log "Destination exists as directory: $dest_dir"
    else
        dest_dir="$(dirname "$dest_path")"
        debug_log "Destination doesn't exist, checking parent: $dest_dir"
    fi

    # Get available space in KB and convert to GB
    local available_space
    available_space=$(df --output=avail "$dest_dir" | tail -n1)
    local available_gb=$((available_space / 1024 / 1024))

    debug_log "Available space: ${available_space}KB = ${available_gb}GB"
    debug_log "Minimum required: ${MIN_FREE_DISK_GB}GB"

    # Check if we have enough space
    if [[ $available_gb -lt $MIN_FREE_DISK_GB ]]; then
        debug_log "Insufficient disk space detected"
        log "$LOG_LEVEL_ERROR" "$(
            cat <<EOF
    Not enough free space on $dest_dir
    Available: ${available_gb}GB, Minimum required: ${MIN_FREE_DISK_GB}GB
    Free up some space or consider:
    - Setting borg config additional_free_space:
        borg config $dest_dir additional_free_space ${MIN_FREE_DISK_GB}G
    - Creating a space reserve file you can delete when needed
    - Using prune/compact to clean old backups
EOF
        )"
        return 1
    fi

    log "$LOG_LEVEL_INFO" "Disk space check OK: ${available_gb}GB available on $dest_dir"
    debug_log "Disk space check passed"
    return 0
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
    # Parse and validate command line arguments
    debug_log "Parsing command line arguments: $*"
    debug_log "Number of arguments: $#"

    if [[ $# -lt 1 || $# -gt 2 ]]; then
        debug_log "Incorrect number of arguments provided"
        show_help
        exit 1
    fi

    CONFIG_FILE="$1"
    debug_log "Config file argument: $CONFIG_FILE"

    # Check for interval argument
    if [[ $# -eq 2 ]]; then
        INTERVAL_MINUTES="$2"
        debug_log "Interval argument: $INTERVAL_MINUTES minutes"

        # Validate interval is a positive integer
        if [[ ! "$INTERVAL_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
            log "$LOG_LEVEL_FATAL" "Interval must be a positive integer (minutes)"
        fi

        CONTINUOUS_MODE=true
        debug_log "Continuous mode enabled"
    else
        debug_log "No interval provided, running in single-shot mode"
    fi

    # Verify config file exists and is readable
    if [[ ! -r "$CONFIG_FILE" ]]; then
        debug_log "Config file does not exist or is not readable: $CONFIG_FILE"
        log "$LOG_LEVEL_FATAL" "Config file '$CONFIG_FILE' doesn't exist or is not readable."
    fi

    debug_log "Config file exists and is readable"

    log "$LOG_LEVEL_INFO" "Using config: $CONFIG_FILE"
    if [[ "$CONTINUOUS_MODE" == true ]]; then
        log "$LOG_LEVEL_INFO" "Running continuously every $INTERVAL_MINUTES minutes"
    else
        log "$LOG_LEVEL_INFO" "Running once"
    fi
    log "$LOG_LEVEL_INFO" "All backup lines must specify --retention-period=N"
    debug_log "Current log level set to: $CURRENT_LOG_LEVEL"
}

# ============================================================================
# DIRECTORY AND REPOSITORY MANAGEMENT
# ============================================================================

ensure_destination_exists() {
    # Create destination directory if it doesn't exist
    local dest_path="$1"

    debug_log "Ensuring destination exists: $dest_path"

    if [[ ! -d "$dest_path" ]]; then
        debug_log "Destination directory doesn't exist, creating it"
        log "$LOG_LEVEL_INFO" "Creating destination directory: $dest_path"
        mkdir -p "$dest_path" || log "$LOG_LEVEL_FATAL" "Failed to create destination directory: $dest_path"
        debug_log "Successfully created destination directory"
    else
        debug_log "Destination directory already exists"
    fi
}

init_borg_repo() {
    # Initialize a borg repository if it doesn't exist
    local repo_path="$1"

    debug_log "Checking if borg repository exists: $repo_path"

    if [[ ! -d "$repo_path" ]] || [[ ! -f "$repo_path/config" ]]; then
        debug_log "Borg repository doesn't exist or is incomplete, initializing"
        log "$LOG_LEVEL_INFO" "Creating borg repository at $repo_path"
        ensure_destination_exists "$repo_path"
        debug_log "Running: borg init --encryption=none $repo_path"
        borg init --encryption=none "$repo_path"
        debug_log "Borg repository initialized successfully"
    else
        debug_log "Borg repository already exists and looks valid"
    fi
}

# ============================================================================
# BACKUP OPERATIONS
# ============================================================================

create_backup() {
    # Create a borg backup archive
    local source="$1"
    local repo_path="$2"
    shift 2
    local -a exclude_args=("$@")
    local archive_name="${repo_path}::backup-${TIMESTAMP}"

    debug_log "Starting backup: source=$source, repo=$repo_path"
    debug_log "Archive name: $archive_name"
    debug_log "Exclude arguments count: ${#exclude_args[@]}"
    if [[ ${#exclude_args[@]} -gt 0 ]]; then
        debug_log "Exclude arguments: ${exclude_args[*]}"
    fi

    # Verify source exists
    if [[ ! -d "$source" && ! -f "$source" ]]; then
        debug_log "Source path doesn't exist: $source"
        log "$LOG_LEVEL_ERROR" "Source path '$source' doesn't exist, skipping"
        return 1
    fi
    debug_log "Source path exists and is accessible"

    # Ensure destination directory structure exists
    debug_log "Ensuring parent directory exists for repo path"
    ensure_destination_exists "$(dirname "$repo_path")"

    # Check available disk space
    debug_log "Checking disk space before backup"
    if ! check_disk_space "$repo_path"; then
        debug_log "Disk space check failed"
        log "$LOG_LEVEL_ERROR" "Skipping backup due to insufficient disk space"
        return 1
    fi

    # Initialize borg repository if needed
    debug_log "Initializing borg repository if needed"
    init_borg_repo "$repo_path"

    log "$LOG_LEVEL_INFO" "Backing up $source -> $repo_path"
    if [[ ${#exclude_args[@]} -gt 0 ]]; then
        log "$LOG_LEVEL_INFO" "Exclude patterns: ${exclude_args[*]}"
    fi

    # Build borg create command
    local borg_cmd=(
        borg create
        --verbose
        --filter AME
        --list
        --stats
        --show-rc
        --compression auto,lz4
        --exclude-caches
    )

    debug_log "Base borg command: ${borg_cmd[*]}"

    # Add exclude patterns if any
    if [[ ${#exclude_args[@]} -gt 0 ]]; then
        borg_cmd+=("${exclude_args[@]}")
        debug_log "Added exclude patterns to command"
    fi

    # Add archive name and source path
    borg_cmd+=("$archive_name" "$source")
    debug_log "Final borg command: ${borg_cmd[*]}"

    # Execute the backup command
    debug_log "Executing borg backup command"
    "${borg_cmd[@]}"

    local backup_exit=$?
    debug_log "Borg backup exit code: $backup_exit"

    if [[ $backup_exit -eq 0 ]]; then
        log "$LOG_LEVEL_INFO" "Backup completed successfully"
        debug_log "Backup operation completed without errors"
    elif [[ $backup_exit -eq 1 ]]; then
        log "$LOG_LEVEL_INFO" "Backup completed with warnings"
        debug_log "Backup operation completed with warnings (exit code 1)"
    else
        log "$LOG_LEVEL_ERROR" "Backup failed with exit code $backup_exit"
        debug_log "Backup operation failed with exit code $backup_exit"
        return $backup_exit
    fi

    debug_log "Backup function completed successfully"
    return 0
}

prune_backups() {
    # Remove old backup archives based on retention policy
    local repo_path="$1"
    local keep_days="$2"

    debug_log "Starting prune operation: repo=$repo_path, keep_days=$keep_days"

    # Verify repository exists
    if [[ ! -d "$repo_path" ]]; then
        debug_log "Repository doesn't exist for pruning: $repo_path"
        log "$LOG_LEVEL_ERROR" "Repository '$repo_path' doesn't exist, can't prune"
        return 1
    fi
    debug_log "Repository exists, proceeding with prune"

    log "$LOG_LEVEL_INFO" "Pruning backups older than $keep_days days in $repo_path"

    # Build prune command for debugging
    local prune_cmd=(
        borg prune
        --list
        --prefix 'backup-'
        --show-rc
        --keep-daily="$keep_days"
        "$repo_path"
    )
    debug_log "Prune command: ${prune_cmd[*]}"

    # Run borg prune
    debug_log "Executing borg prune command"
    "${prune_cmd[@]}"

    local prune_exit=$?
    debug_log "Borg prune exit code: $prune_exit"

    if [[ $prune_exit -eq 0 ]]; then
        log "$LOG_LEVEL_INFO" "Pruning completed successfully"
        debug_log "Prune operation completed without errors"
    else
        log "$LOG_LEVEL_ERROR" "Pruning failed with exit code $prune_exit"
        debug_log "Prune operation failed with exit code $prune_exit"
        return $prune_exit
    fi

    # Compact repository to reclaim space
    debug_log "Starting repository compaction"
    debug_log "Compact command: borg compact $repo_path"
    borg compact "$repo_path"
    local compact_exit=$?
    debug_log "Borg compact exit code: $compact_exit"

    log "$LOG_LEVEL_INFO" "Repository compacted"
    debug_log "Prune function completed successfully"

    return 0
}

# ============================================================================
# CONFIG FILE PROCESSING
# ============================================================================

process_config_file() {
    # Read and process config file, populating the global backup job arrays.
    local config_file="$1"
    local line_number=0

    debug_log "Starting to parse config file: $config_file"

    # Process each line in the config file.
    while IFS= read -r line; do
        line_number=$((line_number + 1))
        debug_log "Parsing line $line_number: $line"

        # Skip empty lines and comments
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            debug_log "Skipping line $line_number (empty or comment)"
            continue
        fi

        # Parse the line to extract components
        local source dest retention_period exclude_patterns
        local temp_line="$line"

        # Initialize retention period as unset
        retention_period=""
        exclude_patterns=""

        # Extract retention period - this is REQUIRED
        if [[ "$temp_line" =~ --retention-period=([0-9]+) ]]; then
            retention_period="${BASH_REMATCH[1]}"
            debug_log "Found retention period: $retention_period days"
            temp_line=$(echo "$temp_line" | sed 's/--retention-period=[0-9]\+//')
        else
            log "$LOG_LEVEL_WARNING" "Skipping line $line_number: Missing required --retention-period=N"
            continue
        fi

        # Extract exclude patterns if specified
        if [[ "$temp_line" =~ --exclude=([^[:space:]]+) ]]; then
            exclude_patterns="${BASH_REMATCH[1]}"
            debug_log "Found exclude patterns: $exclude_patterns"
            temp_line=$(echo "$temp_line" | sed 's/--exclude=[^[:space:]]\+//')
        fi

        # Parse source:destination
        IFS=':' read -r source dest <<<"$temp_line"
        source=$(echo "$source" | xargs) # trim whitespace
        dest=$(echo "$dest" | xargs)     # trim whitespace

        # Validate source and dest
        if [[ -z "$source" || -z "$dest" ]]; then
            log "$LOG_LEVEL_WARNING" "Skipping line $line_number: Invalid config line (missing source or dest)"
            continue
        fi

        # Add the parsed job to our global arrays
        BACKUP_SOURCES+=("$source")
        BACKUP_DESTS+=("$dest")
        BACKUP_RETENTIONS+=("$retention_period")
        BACKUP_EXCLUDES+=("$exclude_patterns")

        log "$LOG_LEVEL_INFO" "Added backup task: $source -> $dest"
        debug_log "Stored task details: retention=$retention_period, excludes='$exclude_patterns'"

    done <"$config_file"

    debug_log "Finished parsing config file. Found ${#BACKUP_SOURCES[@]} tasks."
}

run_all_backups() {
    # Execute all backup jobs stored in the global arrays.
    local total_success=0
    local total_failed=0

    # Generate new timestamp for this run
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    debug_log "Updated timestamp for this backup run: $TIMESTAMP"

    local total_jobs=${#BACKUP_SOURCES[@]}
    log "$LOG_LEVEL_INFO" "Starting backup run with $total_jobs tasks."

    # Ensure we found at least one valid backup configuration
    if [[ $total_jobs -eq 0 ]]; then
        log "$LOG_LEVEL_FATAL" "No valid backup configurations found in config file."
    fi

    # Loop through each stored job
    for i in "${!BACKUP_SOURCES[@]}"; do
        local source="${BACKUP_SOURCES[$i]}"
        local dest="${BACKUP_DESTS[$i]}"
        local retention="${BACKUP_RETENTIONS[$i]}"
        local exclude_patterns="${BACKUP_EXCLUDES[$i]}"
        local -a exclude_args=()

        # Process exclude patterns from the stored string into an array for borg
        if [[ -n "$exclude_patterns" ]]; then
            debug_log "Processing exclude patterns: $exclude_patterns"
            IFS=',' read -ra patterns <<<"$exclude_patterns"
            for pattern in "${patterns[@]}"; do
                pattern=$(echo "$pattern" | xargs) # trim whitespace
                if [[ -n "$pattern" ]]; then
                    exclude_args+=(--exclude "$pattern")
                fi
            done
        fi
        debug_log "Total exclude arguments for this job: ${#exclude_args[@]}"

        # Display current backup operation
        echo "----------------------------------------"
        log "$LOG_LEVEL_INFO" "Processing task $((i + 1))/$total_jobs: $source -> $dest (retention: ${retention} days)"
        debug_log "Starting backup and prune operations"

        # Run backup and prune for the current job
        if create_backup "$source" "$dest" "${exclude_args[@]}"; then
            debug_log "Backup succeeded, proceeding with prune"
            if prune_backups "$dest" "$retention"; then
                total_success=$((total_success + 1))
                log "$LOG_LEVEL_INFO" "Successfully processed $source"
                debug_log "Both backup and prune succeeded for $source"
            else
                total_failed=$((total_failed + 1))
                log "$LOG_LEVEL_ERROR" "Backup for $source succeeded but pruning failed."
                debug_log "Backup succeeded but prune failed for $source"
            fi
        else
            total_failed=$((total_failed + 1))
            log "$LOG_LEVEL_ERROR" "Backup failed for $source"
            debug_log "Backup failed for $source, skipping prune"
        fi
        echo
    done

    # Display final summary
    echo "========================================"
    log "$LOG_LEVEL_INFO" "Backup run completed"
    log "$LOG_LEVEL_INFO" "Successful: $total_success"
    log "$LOG_LEVEL_INFO" "Failed: $total_failed"
    debug_log "Script execution summary complete"

    # In continuous mode, don't exit on failures, just log them
    if [[ "$CONTINUOUS_MODE" == false && $total_failed -gt 0 ]]; then
        debug_log "Exiting with error code 1 due to failed backups (single-shot mode)"
        exit 1
    fi
}

# ============================================================================
# CONTINUOUS MODE
# ============================================================================

run_continuous() {
    local interval_seconds=$((INTERVAL_MINUTES * 60))

    log "$LOG_LEVEL_INFO" "Starting continuous backup mode (interval: ${INTERVAL_MINUTES} minutes)"
    setup_signal_handlers

    local run_counter=1

    while true; do
        log "$LOG_LEVEL_INFO" "========== Backup Run #$run_counter =========="

        # Re-read config file each time to pick up changes
        BACKUP_SOURCES=()
        BACKUP_DESTS=()
        BACKUP_RETENTIONS=()
        BACKUP_EXCLUDES=()

        process_config_file "$CONFIG_FILE"
        run_all_backups

        run_counter=$((run_counter + 1))

        log "$LOG_LEVEL_INFO" "Waiting ${INTERVAL_MINUTES} minutes until next backup run..."
        debug_log "Sleeping for $interval_seconds seconds"

        sleep "$interval_seconds"
    done
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Parse arguments and validate environment
    debug_log "Script started with arguments: $*"
    debug_log "Current working directory: $(pwd)"
    debug_log "Script path: ${BASH_SOURCE[0]}"
    debug_log "Process ID: $$"
    debug_log "User: $(whoami)"
    debug_log "Timestamp: $TIMESTAMP"

    parse_args "$@"
    check_borg_installed
    check_telegram_logger_client_installed

    if [[ "$CONTINUOUS_MODE" == true ]]; then
        debug_log "Running in continuous mode"
        run_continuous
    else
        debug_log "Running in single-shot mode"
        # Phase 1: Read and parse the entire config file
        process_config_file "$CONFIG_FILE"

        # Phase 2: Execute all the loaded backup jobs
        run_all_backups
    fi

    debug_log "Main function completed successfully"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    debug_log "Script executed directly, running main function"
    main "$@"
else
    debug_log "Script sourced, not running main function"
fi

debug_log "Script execution completed"
exit 0
