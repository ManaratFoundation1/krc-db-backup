#!/bin/bash

#################################################################
# PostgreSQL Backup Script with S3 Storage and Rotation
# Features:
# - Compressed backups with size validation
# - S3 storage with 2-backup retention
# - Safe rotation (validates before deletion)
# - Comprehensive logging
# - Error handling and notifications
#################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
else
    echo "ERROR: .env file not found at ${SCRIPT_DIR}/.env"
    exit 1
fi

# Validate required variables
REQUIRED_VARS=(
    "PG_HOST" "PG_PORT" "PG_DATABASE" "PG_USER" "PGPASSWORD"
    "AWS_REGION" "S3_BUCKET" "BACKUP_LOCAL_DIR" "LOG_DIR"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable $var is not set in .env"
        exit 1
    fi
done

# Set defaults
S3_PREFIX="${S3_PREFIX:-postgres-backups}"
MIN_SIZE_PERCENTAGE="${MIN_SIZE_PERCENTAGE:-50}"
MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-5}"  # Minimum free space to maintain (GB)
SPACE_MULTIPLIER="${SPACE_MULTIPLIER:-3}"  # Required free space = expected backup size * multiplier

# Ensure AWS credentials are exported for AWS CLI
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_REGION

# Create directories if they don't exist
mkdir -p "${BACKUP_LOCAL_DIR}"
mkdir -p "${LOG_DIR}"

# Logging setup
TIMESTAMP=$(date '+%Y-%m-%d_%H:%M:%S')
LOG_FILE="${LOG_DIR}/backup_${TIMESTAMP}.log"

# Function: Log messages
log() {
    local level="$1"
    shift
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "${LOG_FILE}" >&2
}

# Function: Log and exit on error
die() {
    log "ERROR" "$*"
    exit 1
}

# Function: Get file size in bytes
get_file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "0"
}

# Function: Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024))KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

# Function: Get available disk space in bytes
get_available_space() {
    local directory="$1"
    df -B1 "$directory" | awk 'NR==2 {print $4}'
}

# Function: Emergency cleanup of temporary files
emergency_cleanup() {
    log "WARN" "Emergency cleanup triggered - removing temporary backup files"
    find "${BACKUP_LOCAL_DIR}" -name "*.backup" -type f -delete 2>/dev/null || true
    find "${BACKUP_LOCAL_DIR}" -name "*.sql" -type f -delete 2>/dev/null || true
    find "${BACKUP_LOCAL_DIR}" -name "*.sql.gz" -type f -delete 2>/dev/null || true
}

# Function: Check disk space before backup
check_disk_space() {
    log "INFO" "Checking disk space availability..."
    
    # Get available space in backup directory
    local available_bytes=$(get_available_space "${BACKUP_LOCAL_DIR}")
    local available_gb=$((available_bytes / 1073741824))
    
    log "INFO" "Available disk space: $(format_bytes $available_bytes) (${available_gb}GB)"
    
    # Check minimum free space threshold
    if [ "$available_gb" -lt "$MIN_FREE_SPACE_GB" ]; then
        log "ERROR" "Insufficient disk space: ${available_gb}GB available, minimum ${MIN_FREE_SPACE_GB}GB required"
        log "WARN" "Attempting emergency cleanup..."
        emergency_cleanup
        
        # Recheck after cleanup
        available_bytes=$(get_available_space "${BACKUP_LOCAL_DIR}")
        available_gb=$((available_bytes / 1073741824))
        
        if [ "$available_gb" -lt "$MIN_FREE_SPACE_GB" ]; then
            die "Still insufficient disk space after cleanup: ${available_gb}GB available"
        fi
        
        log "INFO" "Cleanup successful. Available space: ${available_gb}GB"
    fi
    
    # Get expected backup size from last backup
    local expected_size=$(get_last_backup_size)
    
    if [ "$expected_size" -gt 0 ]; then
        local required_space=$((expected_size * SPACE_MULTIPLIER))
        local required_gb=$((required_space / 1073741824))
        
        log "INFO" "Expected backup size: $(format_bytes $expected_size)"
        log "INFO" "Required free space: $(format_bytes $required_space) (${SPACE_MULTIPLIER}x buffer)"
        
        if [ "$available_bytes" -lt "$required_space" ]; then
            log "ERROR" "Insufficient disk space for backup"
            log "ERROR" "Available: $(format_bytes $available_bytes), Required: $(format_bytes $required_space)"
            
            # Try emergency cleanup
            log "WARN" "Attempting emergency cleanup..."
            emergency_cleanup
            
            # Recheck
            available_bytes=$(get_available_space "${BACKUP_LOCAL_DIR}")
            
            if [ "$available_bytes" -lt "$required_space" ]; then
                die "Insufficient disk space even after cleanup. Cannot proceed with backup."
            fi
            
            log "INFO" "Cleanup successful. Proceeding with backup."
        fi
    else
        log "INFO" "No previous backup found. Proceeding with first backup (${available_gb}GB available)."
    fi
    
    log "INFO" "Disk space check passed"
    return 0
}

# Function: Check if AWS CLI is installed and configured
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        die "AWS CLI is not installed. Please install it first."
    fi
    
    # Test AWS credentials
    if ! aws sts get-caller-identity --region "${AWS_REGION}" &>/dev/null; then
        die "AWS credentials are not configured correctly"
    fi
    
    log "INFO" "AWS CLI configured successfully"
}

# Function: Get the last backup size from S3 metadata
get_last_backup_size() {
    local last_backup=$(aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${S3_PREFIX}/" \
        --query 'sort_by(Contents, &LastModified)[-1].[Key,Size]' \
        --output text \
        --region "${AWS_REGION}" 2>/dev/null)
    
    if [ -z "$last_backup" ] || [ "$last_backup" = "None" ]; then
        echo "0"
        return
    fi
    
    echo "$last_backup" | awk '{print $2}'
}

# Function: Validate backup size
validate_backup_size() {
    local backup_file="$1"
    local current_size=$(get_file_size "$backup_file")
    
    log "INFO" "Current backup size: $(format_bytes $current_size)"
    
    # Get last backup size from S3
    local last_size=$(get_last_backup_size)
    
    if [ "$last_size" -eq 0 ]; then
        log "INFO" "No previous backup found. Accepting first backup."
        return 0
    fi
    
    log "INFO" "Last backup size: $(format_bytes $last_size)"
    
    # Calculate minimum acceptable size
    local min_size=$((last_size * MIN_SIZE_PERCENTAGE / 100))
    
    if [ "$current_size" -lt "$min_size" ]; then
        log "ERROR" "Backup size validation failed!"
        log "ERROR" "Current: $(format_bytes $current_size), Last: $(format_bytes $last_size)"
        log "ERROR" "Current backup is less than ${MIN_SIZE_PERCENTAGE}% of last backup"
        return 1
    fi
    
    log "INFO" "Backup size validation passed"
    return 0
}

# Function: Create PostgreSQL backup
create_backup() {
    local backup_name="$1"
    local backup_file="${BACKUP_LOCAL_DIR}/${backup_name}.backup"
    
    log "INFO" "Starting backup for database: ${PG_DATABASE}"
    log "INFO" "Backup file: ${backup_file}"
    
    # Record start time and space
    local start_space=$(get_available_space "${BACKUP_LOCAL_DIR}")
    
    # Create backup with pg_dump (custom format is already compressed)
    log "INFO" "Running pg_dump..."
    if PGPASSWORD="${PGPASSWORD}" pg_dump \
        -h "${PG_HOST}" \
        -p "${PG_PORT}" \
        -U "${PG_USER}" \
        -d "${PG_DATABASE}" \
        -F c \
        -b \
        -v \
        -f "${backup_file}" 2>>"${LOG_FILE}"; then
        
        # Check if backup file was created
        if [ ! -f "${backup_file}" ] || [ ! -s "${backup_file}" ]; then
            log "ERROR" "Backup file is empty or doesn't exist"
            rm -f "${backup_file}"
            return 1
        fi
        
        # Report space used
        local end_space=$(get_available_space "${BACKUP_LOCAL_DIR}")
        local used_space=$((start_space - end_space))
        log "INFO" "Backup created successfully (used $(format_bytes $used_space))"
        log "INFO" "Remaining disk space: $(format_bytes $end_space)"
        
        echo "${backup_file}"
        return 0
    else
        log "ERROR" "pg_dump failed"
        rm -f "${backup_file}"
        
        # Emergency cleanup in case partial file consumed space
        emergency_cleanup
        return 1
    fi
}

# Function: Upload backup to S3
upload_to_s3() {
    local backup_file="$1"
    local backup_name=$(basename "$backup_file")
    local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${backup_name}"
    
    log "INFO" "Uploading to S3: ${s3_path}"
    
    if aws s3 cp "${backup_file}" "${s3_path}" \
        --region "${AWS_REGION}" \
        --storage-class STANDARD_IA \
        --metadata "timestamp=$(date -u +%s),database=${PG_DATABASE}" \
        2>>"${LOG_FILE}"; then
        
        log "INFO" "Upload to S3 completed successfully"
        return 0
    else
        log "ERROR" "Failed to upload to S3"
        return 1
    fi
}

# Function: Rotate S3 backups (keep last 2)
rotate_s3_backups() {
    log "INFO" "Starting S3 backup rotation"
    
    # List all backups sorted by modification time
    local backups=$(aws s3api list-objects-v2 \
        --bucket "${S3_BUCKET}" \
        --prefix "${S3_PREFIX}/" \
        --query 'sort_by(Contents, &LastModified)[].Key' \
        --output text \
        --region "${AWS_REGION}" 2>/dev/null)
    
    if [ -z "$backups" ]; then
        log "INFO" "No backups found in S3"
        return 0
    fi
    
    # Convert to array
    local backup_array=($backups)
    local total_backups=${#backup_array[@]}
    
    log "INFO" "Found ${total_backups} backup(s) in S3"
    
    # Keep last 2, delete older ones
    if [ "$total_backups" -gt 2 ]; then
        local to_delete=$((total_backups - 2))
        log "INFO" "Removing ${to_delete} old backup(s)"
        
        for ((i=0; i<to_delete; i++)); do
            local key="${backup_array[$i]}"
            log "INFO" "Deleting: s3://${S3_BUCKET}/${key}"
            
            if aws s3 rm "s3://${S3_BUCKET}/${key}" \
                --region "${AWS_REGION}" \
                2>>"${LOG_FILE}"; then
                log "INFO" "Successfully deleted old backup"
            else
                log "ERROR" "Failed to delete: ${key}"
            fi
        done
    else
        log "INFO" "No rotation needed. Keeping all ${total_backups} backup(s)"
    fi
}

# Function: Cleanup local backup
cleanup_local() {
    local backup_file="$1"
    log "INFO" "Cleaning up local backup: ${backup_file}"
    rm -f "${backup_file}"
}

# Function: Cleanup old logs (keep last 30 days)
cleanup_old_logs() {
    log "INFO" "Cleaning up old logs (keeping last 30 days)"
    find "${LOG_DIR}" -name "backup_*.log" -type f -mtime +30 -delete 2>/dev/null || true
}

# Main execution
main() {
    log "INFO" "=========================================="
    log "INFO" "PostgreSQL Backup Script Started"
    log "INFO" "=========================================="
    
    # Generate backup name with format: HH:MM_DD-MM-YYYY
    local backup_timestamp=$(date '+%H:%M_%d-%m-%Y')
    local backup_name="${backup_timestamp}"
    
    log "INFO" "Backup name: ${backup_name}"
    
    # Check prerequisites
    check_aws_cli
    
    # Check if pg_dump is available
    if ! command -v pg_dump &> /dev/null; then
        die "pg_dump is not installed or not in PATH"
    fi
    
    # CRITICAL: Check disk space before proceeding
    if ! check_disk_space; then
        die "Disk space check failed. Backup aborted to prevent system issues."
    fi
    
    # Create backup
    local backup_file
    if ! backup_file=$(create_backup "$backup_name"); then
        die "Backup creation failed"
    fi
    
    # Validate backup size
    if ! validate_backup_size "$backup_file"; then
        log "ERROR" "Backup size validation failed. Backup will not be uploaded."
        cleanup_local "$backup_file"
        die "Backup aborted due to size validation failure"
    fi
    
    # Upload to S3
    if ! upload_to_s3 "$backup_file"; then
        cleanup_local "$backup_file"
        die "Failed to upload backup to S3"
    fi
    
    # Rotate backups in S3 (keep last 2)
    rotate_s3_backups
    
    # Cleanup local backup
    cleanup_local "$backup_file"
    
    # Cleanup old logs
    cleanup_old_logs
    
    log "INFO" "=========================================="
    log "INFO" "Backup completed successfully"
    log "INFO" "=========================================="
}

# Execute main function
main "$@"
