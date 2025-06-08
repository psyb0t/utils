#!/bin/bash

# Mode constants
readonly MODE_BACKUP="backup"
readonly MODE_RESTORE="restore"

# Default values
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

# Function to display usage
usage() {
    cat <<EOF
Usage: $0 <mode> [options]

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
    $0 backup --router-ip 192.168.88.1 --router-user admin --backup-dir /opt/backups
    $0 backup --continuous --max-backups 30 --sleep-interval 60 --max-backup-age 3
    $0 backup --force --router-ip 192.168.88.1
    $0 restore --backup-name mikrotik-backup_2024-01-01_12-00-00.backup
    $0 restore --router-ip 192.168.88.1 --backup-name mybackup.backup --backup-dir /home/user/backups
    $0 restore --router-ip 192.168.88.1

EOF
    exit 1
}

# Logging function
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message"
}

# Function to check if a recent backup exists
check_recent_backup() {
    find "$BACKUP_DIR" -mtime -"${MAX_BACKUP_AGE}" -name 'mikrotik-backup_*' 2>/dev/null | read -r
}

# Function to limit the number of backup files
limit_backups() {
    local backups
    local count
    local remove_count

    backups=$(ls -1tr "${BACKUP_DIR}"/mikrotik-backup_* 2>/dev/null)
    if [ -z "$backups" ]; then
        return 0
    fi

    count=$(echo "$backups" | wc -l)
    remove_count=$((count - MAX_BACKUPS))

    if [ "$remove_count" -gt 0 ]; then
        log "INFO" "Removing $remove_count old backup(s)."
        echo "$backups" | head -n "$remove_count" | while read -r file; do
            rm -f "$file"
            log "INFO" "Removed old backup: $(basename "$file")"
        done
    fi
}

# Function to create a single backup
create_backup() {
    local backup_name
    backup_name="mikrotik-backup_$(date +%Y-%m-%d_%H-%M-%S).backup"

    log "INFO" "Creating backup: $backup_name"

    # Create a backup on the MikroTik router
    if ssh "${ROUTER_USER}@${ROUTER_IP}" "/system backup save name=\"${backup_name}\""; then
        sleep 5 # Wait for the backup to be created

        # Attempt to fetch the backup file
        if scp "${ROUTER_USER}@${ROUTER_IP}:${BACKUP_PATH_ON_ROUTER}${backup_name}" "${BACKUP_DIR}/"; then
            log "INFO" "Backup ${backup_name} has been successfully fetched."

            # Remove the backup file from the router to save space
            if ssh "${ROUTER_USER}@${ROUTER_IP}" "/file remove \"${backup_name}\""; then
                log "INFO" "Backup file removed from router."
            else
                log "WARN" "Failed to remove backup file from router."
            fi

            return 0
        else
            log "ERROR" "Failed to fetch the backup file from MikroTik router."
            return 1
        fi
    else
        log "ERROR" "Failed to create backup on MikroTik router."
        return 1
    fi
}

# Function to run backup mode
backup_mode() {
    # Create backup directory if it doesn't exist
    if ! mkdir -p "$BACKUP_DIR"; then
        log "ERROR" "Failed to create backup directory: $BACKUP_DIR"
        exit 1
    fi

    log "INFO" "Backup directory: $BACKUP_DIR"
    log "INFO" "Router: ${ROUTER_USER}@${ROUTER_IP}"
    log "INFO" "Max backups: $MAX_BACKUPS"
    log "INFO" "Max backup age: $MAX_BACKUP_AGE days"

    if [ "$FORCE_BACKUP" = true ]; then
        log "INFO" "Force backup enabled - will create backup regardless of age"
    fi

    if [ "$CONTINUOUS_MODE" = true ]; then
        local sleep_seconds=$((SLEEP_INTERVAL * 60))
        log "INFO" "Starting continuous backup mode (${SLEEP_INTERVAL}-minute intervals)..."
        while true; do
            # Check for recent backups before proceeding (unless forced)
            if [ "$FORCE_BACKUP" = true ]; then
                log "INFO" "Force backup enabled. Creating backup."
                create_backup
            elif check_recent_backup; then
                log "INFO" "A backup newer than $MAX_BACKUP_AGE days exists. Skipping new backup creation."
            else
                log "INFO" "No recent backup found. Creating a new backup."
                create_backup
            fi

            # Limit the number of stored backups
            limit_backups

            log "INFO" "Waiting for $SLEEP_INTERVAL minutes before the next check..."
            sleep $sleep_seconds
        done
    else
        # Single backup - check for recent backups first (unless forced)
        if [ "$FORCE_BACKUP" = true ]; then
            log "INFO" "Force backup enabled. Creating backup."
            create_backup
        elif check_recent_backup; then
            log "INFO" "A backup newer than $MAX_BACKUP_AGE days exists. Skipping new backup creation."
        else
            log "INFO" "No recent backup found. Creating a new backup."
            create_backup
        fi
        limit_backups
    fi
}

# Function to find the latest backup file
find_latest_backup() {
    local latest_backup
    latest_backup=$(ls -1t "${BACKUP_DIR}"/mikrotik-backup_*.backup 2>/dev/null | head -n 1)

    if [ -z "$latest_backup" ]; then
        log "ERROR" "No backup files found in $BACKUP_DIR"
        exit 1
    fi

    echo "$(basename "$latest_backup")"
}

# Function to restore backup
restore_backup_mode() {
    # Check if backup directory exists
    if [ ! -d "$BACKUP_DIR" ]; then
        log "ERROR" "Backup directory does not exist: $BACKUP_DIR"
        exit 1
    fi

    # If no backup name provided, find the latest one
    if [ -z "$BACKUP_NAME" ]; then
        log "INFO" "No backup name specified, finding latest backup..."
        BACKUP_NAME=$(find_latest_backup)
        log "INFO" "Found latest backup: $BACKUP_NAME"
    fi

    local backup_file="${BACKUP_DIR}/${BACKUP_NAME}"

    # Check if backup file exists locally
    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        exit 1
    fi

    log "INFO" "Restoring backup: $BACKUP_NAME"
    log "INFO" "From: $backup_file"
    log "INFO" "To router: ${ROUTER_USER}@${ROUTER_IP}"

    # Copy the backup file to the router
    log "INFO" "Copying backup file to router..."
    if scp "$backup_file" "${ROUTER_USER}@${ROUTER_IP}:${BACKUP_PATH_ON_ROUTER}"; then
        log "INFO" "Backup file successfully copied to router."

        # Restore the backup
        log "INFO" "Starting restore process..."
        if ssh "${ROUTER_USER}@${ROUTER_IP}" "/system backup load name=\"${BACKUP_NAME}\""; then
            log "INFO" "Backup restore command executed successfully."

            # Ask user if they want to reboot the router
            echo
            read -p "Do you want to reboot the router to apply the backup? [y/N]: " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log "INFO" "Rebooting router..."
                ssh "${ROUTER_USER}@${ROUTER_IP}" "/system reboot"
                log "INFO" "Router reboot command sent."
            else
                log "INFO" "Skipping router reboot. You may need to reboot manually."
            fi

            # Clean up: Remove the backup file from the router
            log "INFO" "Cleaning up backup file from router..."
            if ssh "${ROUTER_USER}@${ROUTER_IP}" "/file remove \"${BACKUP_NAME}\""; then
                log "INFO" "Backup file removed from router."
            else
                log "WARN" "Failed to remove backup file from router."
            fi

        else
            log "ERROR" "Failed to restore backup on router."
            exit 1
        fi
    else
        log "ERROR" "Failed to copy backup file to router."
        exit 1
    fi
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    usage
fi

MODE="$1"
shift

# Validate mode
if [ "$MODE" != "$MODE_BACKUP" ] && [ "$MODE" != "$MODE_RESTORE" ]; then
    echo "Error: Invalid mode '$MODE'. Must be '$MODE_BACKUP' or '$MODE_RESTORE'."
    usage
fi

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --router-ip)
        ROUTER_IP="$2"
        shift 2
        ;;
    --router-user)
        ROUTER_USER="$2"
        shift 2
        ;;
    --backup-dir)
        BACKUP_DIR="$2"
        shift 2
        ;;
    --router-path)
        BACKUP_PATH_ON_ROUTER="$2"
        shift 2
        ;;
    --max-backups)
        MAX_BACKUPS="$2"
        shift 2
        ;;
    --backup-name)
        BACKUP_NAME="$2"
        shift 2
        ;;
    --sleep-interval)
        SLEEP_INTERVAL="$2"
        shift 2
        ;;
    --max-backup-age)
        MAX_BACKUP_AGE="$2"
        shift 2
        ;;
    --continuous)
        CONTINUOUS_MODE=true
        shift
        ;;
    --force)
        FORCE_BACKUP=true
        shift
        ;;
    --help)
        usage
        ;;
    *)
        echo "Error: Unknown option '$1'"
        usage
        ;;
    esac
done

# Validate required parameters
if [ -z "$ROUTER_IP" ] || [ -z "$ROUTER_USER" ]; then
    echo "Error: Router IP and username are required."
    exit 1
fi

# Validate numeric parameters
if ! [[ "$SLEEP_INTERVAL" =~ ^[0-9]+$ ]] || [ "$SLEEP_INTERVAL" -le 0 ]; then
    echo "Error: Sleep interval must be a positive integer (minutes)."
    exit 1
fi

if ! [[ "$MAX_BACKUP_AGE" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUP_AGE" -le 0 ]; then
    echo "Error: Max backup age must be a positive integer (days)."
    exit 1
fi

# Execute based on mode
case $MODE in
"$MODE_BACKUP")
    backup_mode
    ;;
"$MODE_RESTORE")
    restore_backup_mode
    ;;
esac
