#!/bin/bash

set -euo pipefail

# ============================================================================
# GLOBAL VARIABLES AND CONSTANTS
# ============================================================================

SCRIPT_NAME=$(basename "$0")
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# Mode constants
readonly MODE_BACKUP="backup"
readonly MODE_RESTORE="restore"

# Log level constants
LOG_LEVEL_DEBUG="DEBUG"
LOG_LEVEL_INFO="INFO"
LOG_LEVEL_WARNING="WARNING"
LOG_LEVEL_ERROR="ERROR"
LOG_LEVEL_FATAL="FATAL"

# Default configuration values
ROUTER_IP="192.168.88.1"
ROUTER_USER="admin"
BACKUP_DIR="$HOME/mikrotik-backup"
BACKUP_PATH_ON_ROUTER="/"
MAX_BACKUPS=20
BACKUP_NAME=""
CONTINUOUS_MODE=false
FORCE_BACKUP=false
SLEEP_INTERVAL=30 # minutes
MAX_BACKUP_AGE=7  # days
MODE=""

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

    # Kill any running SSH/SCP processes
    pkill -f "ssh.*${ROUTER_IP}\|scp.*${ROUTER_IP}" 2>/dev/null || true

    log "$LOG_LEVEL_INFO" "MikroTik backup script stopped"
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
Usage: $SCRIPT_NAME <mode> [options]

Modes:
    $MODE_BACKUP      Create backup(s) of MikroTik router
    $MODE_RESTORE     Restore backup to MikroTik router

Options:
    --router-ip IP          Router IP address (default: $ROUTER_IP)
    --router-user USER      Router username (default: $ROUTER_USER)
    --backup-dir DIR        Local backup directory (default: $BACKUP_DIR)
    --router-path PATH      Path on router (default: $BACKUP_PATH_ON_ROUTER)
    --max-backups NUM       Maximum number of backups to keep (default: $MAX_BACKUPS)
    --backup-name NAME      Backup filename (if not set in restore mode then the latest backup file is used)
    --continuous            Run backup in continuous mode
    --force                 Force backup creation even if recent backup exists
    --sleep-interval MIN    Sleep interval in minutes for continuous mode (default: $SLEEP_INTERVAL)
    --max-backup-age DAYS   Maximum age in days before creating new backup (default: $MAX_BACKUP_AGE)
    --help                  Show this help message

Examples:
    $SCRIPT_NAME backup --router-ip 192.168.88.1 --router-user admin --backup-dir /opt/backups
    $SCRIPT_NAME backup --continuous --max-backups 30 --sleep-interval 60 --max-backup-age 3
    $SCRIPT_NAME backup --force --router-ip 192.168.88.1
    $SCRIPT_NAME restore --backup-name mikrotik-backup_2024-01-01_12-00-00.backup
    $SCRIPT_NAME restore --router-ip 192.168.88.1 --backup-name mybackup.backup --backup-dir /home/user/backups
    $SCRIPT_NAME restore --router-ip 192.168.88.1

EOF
}

check_dependencies() {
    debug_log "Checking required dependencies"

    # Check if ssh is available
    if ! command -v ssh &>/dev/null; then
        log "$LOG_LEVEL_FATAL" "ssh is not installed or not in PATH. Please install openssh-client."
    fi
    debug_log "ssh found: $(which ssh)"

    # Check if scp is available
    if ! command -v scp &>/dev/null; then
        log "$LOG_LEVEL_FATAL" "scp is not installed or not in PATH. Please install openssh-client."
    fi
    debug_log "scp found: $(which scp)"

    log "$LOG_LEVEL_INFO" "All required dependencies are available"
}

check_telegram_logger_client() {
    debug_log "Checking if telegram-logger-client is installed"

    if ! command -v telegram-logger-client &>/dev/null; then
        debug_log "telegram-logger-client not found in PATH"
        log "$LOG_LEVEL_WARNING" "telegram-logger-client not found - notifications will be disabled"
        log "$LOG_LEVEL_WARNING" "Install with: pipx install telegram-logger-client"
        log "$LOG_LEVEL_WARNING" "Documentation: https://github.com/psyb0t/py-telegram-logger-client"
    else
        debug_log "telegram-logger-client found: $(which telegram-logger-client)"
        log "$LOG_LEVEL_INFO" "Telegram notifications enabled"
    fi
}

test_router_connection() {
    debug_log "Testing connection to router: ${ROUTER_USER}@${ROUTER_IP}"

    log "$LOG_LEVEL_INFO" "Testing connection to router..."

    # Test SSH connection with a simple command
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "${ROUTER_USER}@${ROUTER_IP}" "/system resource print" &>/dev/null; then
        log "$LOG_LEVEL_INFO" "Router connection test successful"
        debug_log "SSH connection to router established successfully"
        return 0
    else
        log "$LOG_LEVEL_ERROR" "Failed to connect to router ${ROUTER_USER}@${ROUTER_IP}"
        log "$LOG_LEVEL_ERROR" "Please check:"
        log "$LOG_LEVEL_ERROR" "  - Router IP address is correct"
        log "$LOG_LEVEL_ERROR" "  - Router is accessible from this machine"
        log "$LOG_LEVEL_ERROR" "  - SSH service is enabled on router"
        log "$LOG_LEVEL_ERROR" "  - SSH key authentication is configured"
        debug_log "SSH connection test failed"
        return 1
    fi
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
    debug_log "Parsing command line arguments: $*"
    debug_log "Number of arguments: $#"

    if [[ $# -eq 0 ]]; then
        debug_log "No arguments provided"
        show_help
        exit 1
    fi

    MODE="$1"
    debug_log "Mode argument: $MODE"
    shift

    # Validate mode
    if [[ "$MODE" != "$MODE_BACKUP" && "$MODE" != "$MODE_RESTORE" ]]; then
        debug_log "Invalid mode provided: $MODE"
        log "$LOG_LEVEL_FATAL" "Invalid mode '$MODE'. Must be '$MODE_BACKUP' or '$MODE_RESTORE'."
    fi

    debug_log "Valid mode selected: $MODE"

    # Parse named arguments
    while [[ $# -gt 0 ]]; do
        debug_log "Processing argument: $1"
        case $1 in
        --router-ip)
            ROUTER_IP="$2"
            debug_log "Router IP set to: $ROUTER_IP"
            shift 2
            ;;
        --router-user)
            ROUTER_USER="$2"
            debug_log "Router user set to: $ROUTER_USER"
            shift 2
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            debug_log "Backup directory set to: $BACKUP_DIR"
            shift 2
            ;;
        --router-path)
            BACKUP_PATH_ON_ROUTER="$2"
            debug_log "Router path set to: $BACKUP_PATH_ON_ROUTER"
            shift 2
            ;;
        --max-backups)
            MAX_BACKUPS="$2"
            debug_log "Max backups set to: $MAX_BACKUPS"
            shift 2
            ;;
        --backup-name)
            BACKUP_NAME="$2"
            debug_log "Backup name set to: $BACKUP_NAME"
            shift 2
            ;;
        --sleep-interval)
            SLEEP_INTERVAL="$2"
            debug_log "Sleep interval set to: $SLEEP_INTERVAL minutes"
            shift 2
            ;;
        --max-backup-age)
            MAX_BACKUP_AGE="$2"
            debug_log "Max backup age set to: $MAX_BACKUP_AGE days"
            shift 2
            ;;
        --continuous)
            CONTINUOUS_MODE=true
            debug_log "Continuous mode enabled"
            shift
            ;;
        --force)
            FORCE_BACKUP=true
            debug_log "Force backup enabled"
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            debug_log "Unknown option: $1"
            log "$LOG_LEVEL_FATAL" "Unknown option '$1'"
            ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$ROUTER_IP" || -z "$ROUTER_USER" ]]; then
        debug_log "Missing required parameters: ROUTER_IP=$ROUTER_IP, ROUTER_USER=$ROUTER_USER"
        log "$LOG_LEVEL_FATAL" "Router IP and username are required."
    fi

    # Validate numeric parameters
    if ! [[ "$SLEEP_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$SLEEP_INTERVAL" -le 0 ]]; then
        debug_log "Invalid sleep interval: $SLEEP_INTERVAL"
        log "$LOG_LEVEL_FATAL" "Sleep interval must be a positive integer (minutes)."
    fi

    if ! [[ "$MAX_BACKUP_AGE" =~ ^[0-9]+$ ]] || [[ "$MAX_BACKUP_AGE" -le 0 ]]; then
        debug_log "Invalid max backup age: $MAX_BACKUP_AGE"
        log "$LOG_LEVEL_FATAL" "Max backup age must be a positive integer (days)."
    fi

    if ! [[ "$MAX_BACKUPS" =~ ^[0-9]+$ ]] || [[ "$MAX_BACKUPS" -le 0 ]]; then
        debug_log "Invalid max backups: $MAX_BACKUPS"
        log "$LOG_LEVEL_FATAL" "Max backups must be a positive integer."
    fi

    debug_log "All arguments parsed and validated successfully"
}

# ============================================================================
# DIRECTORY AND FILE MANAGEMENT
# ============================================================================

ensure_backup_directory_exists() {
    debug_log "Ensuring backup directory exists: $BACKUP_DIR"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        debug_log "Backup directory doesn't exist, creating it"
        log "$LOG_LEVEL_INFO" "Creating backup directory: $BACKUP_DIR"

        if mkdir -p "$BACKUP_DIR"; then
            debug_log "Successfully created backup directory"
            log "$LOG_LEVEL_INFO" "Backup directory created successfully"
        else
            debug_log "Failed to create backup directory"
            log "$LOG_LEVEL_FATAL" "Failed to create backup directory: $BACKUP_DIR"
        fi
    else
        debug_log "Backup directory already exists"
    fi

    # Check if directory is writable
    if [[ ! -w "$BACKUP_DIR" ]]; then
        debug_log "Backup directory is not writable"
        log "$LOG_LEVEL_FATAL" "Backup directory is not writable: $BACKUP_DIR"
    fi

    debug_log "Backup directory is ready for use"
}

check_recent_backup() {
    debug_log "Checking for recent backups newer than $MAX_BACKUP_AGE days"

    local recent_backups
    recent_backups=$(find "$BACKUP_DIR" -mtime -"${MAX_BACKUP_AGE}" -name 'mikrotik-backup_*' 2>/dev/null || true)

    if [[ -n "$recent_backups" ]]; then
        debug_log "Found recent backup(s): $recent_backups"
        return 0
    else
        debug_log "No recent backups found"
        return 1
    fi
}

limit_backups() {
    debug_log "Starting backup cleanup process, max backups: $MAX_BACKUPS"

    local backups count remove_count

    # Get list of backup files sorted by modification time (oldest first)
    backups=$(ls -1tr "${BACKUP_DIR}"/mikrotik-backup_* 2>/dev/null || true)

    if [[ -z "$backups" ]]; then
        debug_log "No backup files found to clean up"
        return 0
    fi

    count=$(echo "$backups" | wc -l)
    remove_count=$((count - MAX_BACKUPS))

    debug_log "Found $count backups, need to remove $remove_count"

    if [[ "$remove_count" -gt 0 ]]; then
        log "$LOG_LEVEL_INFO" "Removing $remove_count old backup(s) to maintain limit of $MAX_BACKUPS"

        echo "$backups" | head -n "$remove_count" | while read -r file; do
            debug_log "Removing old backup: $file"
            if rm -f "$file"; then
                log "$LOG_LEVEL_INFO" "Removed old backup: $(basename "$file")"
                debug_log "Successfully removed: $file"
            else
                log "$LOG_LEVEL_ERROR" "Failed to remove backup: $(basename "$file")"
                debug_log "Failed to remove: $file"
            fi
        done
    else
        debug_log "No backup cleanup needed"
    fi
}

find_latest_backup() {
    debug_log "Looking for latest backup file in: $BACKUP_DIR"

    local latest_backup
    latest_backup=$(ls -1t "${BACKUP_DIR}"/mikrotik-backup_*.backup 2>/dev/null | head -n 1 || true)

    if [[ -z "$latest_backup" ]]; then
        debug_log "No backup files found"
        log "$LOG_LEVEL_FATAL" "No backup files found in $BACKUP_DIR"
    fi

    debug_log "Latest backup found: $latest_backup"
    echo "$(basename "$latest_backup")"
}

# ============================================================================
# BACKUP OPERATIONS
# ============================================================================

create_backup() {
    debug_log "Starting backup creation process"

    local backup_name
    backup_name="mikrotik-backup_${TIMESTAMP}.backup"

    debug_log "Backup filename: $backup_name"
    log "$LOG_LEVEL_INFO" "Creating backup: $backup_name"

    # Create a backup on the MikroTik router
    debug_log "Executing backup command on router"
    log "$LOG_LEVEL_INFO" "Requesting backup creation on router..."

    if ssh "${ROUTER_USER}@${ROUTER_IP}" "/system backup save name=\"${backup_name}\""; then
        debug_log "Backup creation command succeeded"
        log "$LOG_LEVEL_INFO" "Backup created on router successfully"

        # Wait for the backup to be created
        debug_log "Waiting 5 seconds for backup file to be ready"
        sleep 5

        # Attempt to fetch the backup file
        debug_log "Fetching backup file from router"
        log "$LOG_LEVEL_INFO" "Downloading backup file from router..."

        local remote_path="${ROUTER_USER}@${ROUTER_IP}:${BACKUP_PATH_ON_ROUTER}${backup_name}"
        local local_path="${BACKUP_DIR}/${backup_name}"

        debug_log "Remote path: $remote_path"
        debug_log "Local path: $local_path"

        if scp "$remote_path" "$local_path"; then
            debug_log "Backup file downloaded successfully"
            log "$LOG_LEVEL_INFO" "Backup ${backup_name} downloaded successfully"

            # Verify the downloaded file exists and has content
            if [[ -f "$local_path" && -s "$local_path" ]]; then
                debug_log "Backup file verified: $(ls -lh "$local_path")"
                log "$LOG_LEVEL_INFO" "Backup file verified: $(du -h "$local_path" | cut -f1)"
            else
                debug_log "Downloaded backup file is empty or missing"
                log "$LOG_LEVEL_ERROR" "Downloaded backup file is empty or corrupted"
                return 1
            fi

            # Remove the backup file from the router to save space
            debug_log "Cleaning up backup file from router"
            if ssh "${ROUTER_USER}@${ROUTER_IP}" "/file remove \"${backup_name}\""; then
                debug_log "Backup file removed from router successfully"
                log "$LOG_LEVEL_INFO" "Backup file cleaned up from router"
            else
                debug_log "Failed to remove backup file from router"
                log "$LOG_LEVEL_WARNING" "Failed to remove backup file from router"
            fi

            debug_log "Backup creation completed successfully"
            return 0
        else
            debug_log "Failed to download backup file"
            log "$LOG_LEVEL_ERROR" "Failed to download backup file from router"

            # Try to clean up the failed backup on router
            debug_log "Attempting to clean up failed backup on router"
            ssh "${ROUTER_USER}@${ROUTER_IP}" "/file remove \"${backup_name}\"" 2>/dev/null || true

            return 1
        fi
    else
        debug_log "Backup creation command failed"
        log "$LOG_LEVEL_ERROR" "Failed to create backup on MikroTik router"
        return 1
    fi
}

backup_mode() {
    debug_log "Entering backup mode"

    # Create backup directory if it doesn't exist
    ensure_backup_directory_exists

    if [[ "$CONTINUOUS_MODE" == true ]]; then
        log "$LOG_LEVEL_INFO" "$(
            cat <<EOF
Backup configuration:
  Directory: $BACKUP_DIR
  Router: ${ROUTER_USER}@${ROUTER_IP}
  Max backups: $MAX_BACKUPS
  Max backup age: $MAX_BACKUP_AGE days
  Force backup: $FORCE_BACKUP
  Continuous mode: $CONTINUOUS_MODE
  Sleep interval: $SLEEP_INTERVAL minutes
EOF
        )"
    else
        log "$LOG_LEVEL_INFO" "$(
            cat <<EOF
Backup configuration:
  Directory: $BACKUP_DIR
  Router: ${ROUTER_USER}@${ROUTER_IP}
  Max backups: $MAX_BACKUPS
  Max backup age: $MAX_BACKUP_AGE days
  Force backup: $FORCE_BACKUP
  Continuous mode: $CONTINUOUS_MODE
EOF
        )"
    fi

    # Test router connection before starting
    if ! test_router_connection; then
        debug_log "Router connection test failed, aborting"
        log "$LOG_LEVEL_FATAL" "Cannot connect to router, aborting backup process"
    fi

    if [[ "$CONTINUOUS_MODE" == true ]]; then
        debug_log "Starting continuous backup mode"
        run_continuous_backup
    else
        debug_log "Running single backup"
        run_single_backup
    fi
}

run_single_backup() {
    debug_log "Running single backup operation"

    # Check for recent backups first (unless forced)
    if [[ "$FORCE_BACKUP" == true ]]; then
        debug_log "Force backup enabled, creating backup regardless of age"
        log "$LOG_LEVEL_INFO" "Force backup enabled - creating backup regardless of age"
        create_backup
    elif check_recent_backup; then
        debug_log "Recent backup found, skipping new backup creation"
        log "$LOG_LEVEL_INFO" "A backup newer than $MAX_BACKUP_AGE days exists. Skipping new backup creation."
        log "$LOG_LEVEL_INFO" "Use --force to create backup anyway"
    else
        debug_log "No recent backup found, creating new backup"
        log "$LOG_LEVEL_INFO" "No recent backup found. Creating a new backup."
        create_backup
    fi

    # Clean up old backups
    debug_log "Running backup cleanup"
    limit_backups

    debug_log "Single backup operation completed"
}

run_continuous_backup() {
    debug_log "Starting continuous backup mode"

    local sleep_seconds=$((SLEEP_INTERVAL * 60))
    local run_counter=1

    log "$LOG_LEVEL_INFO" "Starting continuous backup mode (${SLEEP_INTERVAL}-minute intervals)"
    setup_signal_handlers

    while true; do
        debug_log "Starting backup run #$run_counter"
        log "$LOG_LEVEL_INFO" "========== Backup Run #$run_counter =========="

        # Update timestamp for this run
        TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
        debug_log "Updated timestamp: $TIMESTAMP"

        # Check for recent backups before proceeding (unless forced)
        if [[ "$FORCE_BACKUP" == true ]]; then
            debug_log "Force backup enabled for continuous run"
            log "$LOG_LEVEL_INFO" "Force backup enabled - creating backup"
            create_backup
        elif check_recent_backup; then
            debug_log "Recent backup found, skipping this run"
            log "$LOG_LEVEL_INFO" "A backup newer than $MAX_BACKUP_AGE days exists. Skipping new backup creation."
        else
            debug_log "No recent backup found, creating new backup"
            log "$LOG_LEVEL_INFO" "No recent backup found. Creating a new backup."
            create_backup
        fi

        # Limit the number of stored backups
        debug_log "Running backup cleanup for run #$run_counter"
        limit_backups

        run_counter=$((run_counter + 1))

        log "$LOG_LEVEL_INFO" "Waiting $SLEEP_INTERVAL minutes before next backup check..."
        debug_log "Sleeping for $sleep_seconds seconds"
        sleep $sleep_seconds
    done
}

# ============================================================================
# RESTORE OPERATIONS
# ============================================================================

restore_backup_mode() {
    debug_log "Entering restore mode"

    # Check if backup directory exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        debug_log "Backup directory doesn't exist: $BACKUP_DIR"
        log "$LOG_LEVEL_FATAL" "Backup directory does not exist: $BACKUP_DIR"
    fi

    debug_log "Backup directory exists and is accessible"

    # If no backup name provided, find the latest one
    if [[ -z "$BACKUP_NAME" ]]; then
        debug_log "No backup name specified, finding latest backup"
        log "$LOG_LEVEL_INFO" "No backup name specified, finding latest backup..."
        BACKUP_NAME=$(find_latest_backup)
        log "$LOG_LEVEL_INFO" "Found latest backup: $BACKUP_NAME"
    fi

    local backup_file="${BACKUP_DIR}/${BACKUP_NAME}"
    debug_log "Backup file path: $backup_file"

    # Check if backup file exists locally
    if [[ ! -f "$backup_file" ]]; then
        debug_log "Backup file not found: $backup_file"
        log "$LOG_LEVEL_FATAL" "Backup file not found: $backup_file"
    fi

    # Verify backup file has content
    if [[ ! -s "$backup_file" ]]; then
        debug_log "Backup file is empty: $backup_file"
        log "$LOG_LEVEL_FATAL" "Backup file is empty: $backup_file"
    fi

    debug_log "Backup file verified: $(ls -lh "$backup_file")"

    log "$LOG_LEVEL_INFO" "$(
        cat <<EOF
Restore configuration:
  Backup file: $BACKUP_NAME
  Local path: $backup_file
  Router: ${ROUTER_USER}@${ROUTER_IP}
  File size: $(du -h "$backup_file" | cut -f1)
EOF
    )"

    # Test router connection before starting
    if ! test_router_connection; then
        debug_log "Router connection test failed, aborting restore"
        log "$LOG_LEVEL_FATAL" "Cannot connect to router, aborting restore process"
    fi

    # Copy the backup file to the router
    debug_log "Starting file transfer to router"
    log "$LOG_LEVEL_INFO" "Uploading backup file to router..."

    local remote_path="${ROUTER_USER}@${ROUTER_IP}:${BACKUP_PATH_ON_ROUTER}"
    debug_log "Remote path: $remote_path"

    if scp "$backup_file" "$remote_path"; then
        debug_log "Backup file uploaded successfully"
        log "$LOG_LEVEL_INFO" "Backup file uploaded to router successfully"

        # Restore the backup
        debug_log "Starting restore process on router"
        log "$LOG_LEVEL_INFO" "Starting restore process on router..."

        if ssh "${ROUTER_USER}@${ROUTER_IP}" "/system backup load name=\"${BACKUP_NAME}\""; then
            debug_log "Restore command executed successfully"
            log "$LOG_LEVEL_INFO" "Backup restore completed successfully"

            # Ask user if they want to reboot the router
            echo
            read -p "Do you want to reboot the router to apply the backup? [y/N]: " -n 1 -r
            echo

            if [[ $REPLY =~ ^[Yy]$ ]]; then
                debug_log "User chose to reboot router"
                log "$LOG_LEVEL_INFO" "Rebooting router..."

                if ssh "${ROUTER_USER}@${ROUTER_IP}" "/system reboot"; then
                    debug_log "Reboot command sent successfully"
                    log "$LOG_LEVEL_INFO" "Router reboot command sent successfully"
                else
                    debug_log "Reboot command failed"
                    log "$LOG_LEVEL_WARNING" "Failed to send reboot command"
                fi
            else
                debug_log "User chose not to reboot"
                log "$LOG_LEVEL_INFO" "Skipping router reboot. You may need to reboot manually to apply all changes."
            fi

            # Clean up: Remove the backup file from the router
            debug_log "Cleaning up backup file from router"
            log "$LOG_LEVEL_INFO" "Cleaning up backup file from router..."

            if ssh "${ROUTER_USER}@${ROUTER_IP}" "/file remove \"${BACKUP_NAME}\""; then
                debug_log "Backup file removed from router successfully"
                log "$LOG_LEVEL_INFO" "Backup file cleaned up from router"
            else
                debug_log "Failed to remove backup file from router"
                log "$LOG_LEVEL_WARNING" "Failed to clean up backup file from router"
            fi

            debug_log "Restore process completed successfully"
            log "$LOG_LEVEL_INFO" "Restore process completed successfully"

        else
            debug_log "Restore command failed"
            log "$LOG_LEVEL_ERROR" "Failed to restore backup on router"

            # Clean up the uploaded file
            debug_log "Cleaning up uploaded file after failed restore"
            ssh "${ROUTER_USER}@${ROUTER_IP}" "/file remove \"${BACKUP_NAME}\"" 2>/dev/null || true

            return 1
        fi
    else
        debug_log "Failed to upload backup file to router"
        log "$LOG_LEVEL_ERROR" "Failed to upload backup file to router"
        return 1
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    debug_log "Script started with arguments: $*"
    debug_log "Current working directory: $(pwd)"
    debug_log "Script path: ${BASH_SOURCE[0]}"
    debug_log "Process ID: $$"
    debug_log "User: $(whoami)"
    debug_log "Timestamp: $TIMESTAMP"

    # Parse and validate arguments
    parse_args "$@"

    # Check dependencies
    check_dependencies
    check_telegram_logger_client

    # Execute based on mode
    debug_log "Executing mode: $MODE"
    case $MODE in
    "$MODE_BACKUP")
        debug_log "Starting backup mode execution"
        backup_mode
        ;;
    "$MODE_RESTORE")
        debug_log "Starting restore mode execution"
        restore_backup_mode
        ;;
    *)
        debug_log "Unknown mode: $MODE"
        log "$LOG_LEVEL_FATAL" "Unknown mode: $MODE"
        ;;
    esac

    debug_log "Main function completed successfully"
    log "$LOG_LEVEL_INFO" "Script execution completed successfully"
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
