#!/bin/bash
set -eo pipefail

# ==============================================================================
# Nacos DB Standalone Backup & Restore Script
# Features:
#   - Database-only backup (MySQL)
#   - Docker command fallback (Uses mysql:latest if local commands are missing)
#   - S3 integration (Upload & Retention)
#   - One-key restore from local/S3
# ==============================================================================

# --- Default Configurations ---
DB_HOST="localhost"
DB_PORT=3306
DB_USER="nacos"
DB_PASSWORD="nacos"
DB_NAME="nacos_devtest"

BACKUP_DIR="/opt/nacos-backups"
RETENTION_DAYS=7

ENABLE_S3=false
S3_ALIAS="myminio"
S3_BUCKET="my-nacos-backups"
S3_PATH="nacos-db/"
S3_RETENTION_DAYS=30
MC_CMD="mcli"

# Logger
log() {
    echo -e "\033[32m[$(date +'%Y-%m-%d %H:%M:%S')] $1\033[0m"
}

error() {
    echo -e "\033[31m[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1\033[0m" >&2
}

usage() {
    cat <<EOF
Usage: $0 [options]

Core Options:
  --backup                      Perform a database backup.
  --restore <file|s3_url>       Restore the database from a local file or S3 URL.
  -h, --help                    Display this help message.

Database Configuration:
  --db-host <host>              Database host (Default: $DB_HOST)
  --db-port <port>              Database port (Default: $DB_PORT)
  --db-user <user>              Database user (Default: $DB_USER)
  --db-pass <pass>              Database password (Default: ******)
  --db-name <name>              Database name (Default: $DB_NAME)

Backup & Retention:
  --dir <path>                  Local backup directory (Default: $BACKUP_DIR)
  --retention <days>            Local retention days (Default: $RETENTION_DAYS)

S3 Configuration:
  --s3                          Enable S3 backup (via MinIO Client).
  --s3-alias <alias>            S3 alias configured in mc (Default: $S3_ALIAS)
  --s3-bucket <bucket>          S3 bucket name.
  --s3-path <path>              S3 path prefix (Default: $S3_PATH)
  --s3-retention <days>         S3 retention days (Default: $S3_RETENTION_DAYS)
  --mc-cmd <cmd>                MinIO Client command name (Default: $MC_CMD)

Examples:
  $0 --backup --db-host 1.2.3.4 --db-pass "my-secret"
  $0 --backup --s3 --s3-bucket my-backups
  $0 --restore mc/myminio/my-nacos-backups/nacos-db/nacos_db_20260109_1540.sql.gz
EOF
    exit 0
}

# --- Command Fallback Logic ---
# Check if a command exists locally, otherwise return a docker-run command
get_command() {
    local cmd=$1
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd"
    else
        # Fallback to Docker
        if ! command -v docker >/dev/null 2>&1; then
            error "Neither '$cmd' nor 'docker' found. Please install one of them."
            exit 1
        fi
        echo "docker run --rm -i mysql:latest $cmd"
    fi
}

# --- Backup Logic ---
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local filename="nacos_db_${timestamp}.sql.gz"
    local filepath="${BACKUP_DIR}/${filename}"

    log "Starting backup: ${DB_NAME} from ${DB_HOST}..."
    
    local mysqldump_cmd=$(get_command "mysqldump")
    
    # Execute dump and compress
    if [[ "$mysqldump_cmd" == *"docker"* ]]; then
        # If using docker, we pipe the output
        $mysqldump_cmd -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" --single-transaction "$DB_NAME" | gzip > "$filepath"
    else
        $mysqldump_cmd -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" --single-transaction "$DB_NAME" | gzip > "$filepath"
    fi

    if [ -s "$filepath" ]; then
        log "Backup successful: $filepath"
        
        # S3 Upload
        if [ "$ENABLE_S3" = true ]; then
            upload_to_s3 "$filepath" "$filename"
            cleanup_s3
        fi
        
        # Local Cleanup
        cleanup_local
    else
        error "Backup failed or file is empty."
        rm -f "$filepath"
        exit 1
    fi
}

# --- Restore Logic ---
do_restore() {
    local source=$1
    if [ -z "$source" ]; then
        error "Usage: $0 --restore <path_to_sql_gz_or_s3_url>"
        exit 1
    fi

    local restore_file=""
    
    # S3 Source handling
    if [[ "$source" == mc/* ]] || [[ "$source" == */* ]]; then
        # Check if it looks like an mc path (contains alias/bucket)
        if [[ "$source" == mc/* ]]; then
            source="${source#mc/}"
        fi
        
        log "Downloading backup from S3/MinIO: $source"
        restore_file="${BACKUP_DIR}/tmp_restore.sql.gz"
        $MC_CMD cp "$source" "$restore_file"
    else
        restore_file="$source"
    fi

    if [ ! -f "$restore_file" ]; then
        error "Restore file not found: $restore_file"
        exit 1
    fi

    log "WARNING: This will overwrite the database ${DB_NAME}. Continue? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        log "Restore cancelled."
        exit 0
    fi

    log "Restoring database..."
    local mysql_cmd=$(get_command "mysql")
    
    # Decompress and import
    gunzip < "$restore_file" | $mysql_cmd -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME"

    log "Restore completed successfully."
    
    # Clean up temp file if downloaded from S3
    if [[ "$source" == s3://* ]]; then
        rm -f "$restore_file"
    fi
}

# --- S3 Operations ---
upload_to_s3() {
    local file=$1
    local name=$2
    local target="${S3_ALIAS}/${S3_BUCKET}/${S3_PATH}${name}"
    log "Uploading to S3 (mc): $target"
    
    if ! command -v "$MC_CMD" >/dev/null 2>&1; then
        error "MinIO Client ($MC_CMD) not found. Skipping S3 upload."
        return 1
    fi

    $MC_CMD cp "$file" "$target"
}

cleanup_s3() {
    log "Cleaning up old backups from S3 (Retention: ${S3_RETENTION_DAYS} days)..."
    
    # Use mc find --older-than to delete old files
    $MC_CMD rm --recursive --older-than "${S3_RETENTION_DAYS}d" "${S3_ALIAS}/${S3_BUCKET}/${S3_PATH}"
}

cleanup_local() {
    log "Cleaning up local backups older than ${RETENTION_DAYS} days..."
    find "$BACKUP_DIR" -name "nacos_db_*.sql.gz" -mtime +$RETENTION_DAYS -exec rm -f {} \;
}

# --- CLI Parsing ---
if [[ $# -eq 0 ]]; then
    usage
fi

ACTION=""
RESTORE_SOURCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup)
            ACTION="backup"
            shift
            ;;
        --restore)
            ACTION="restore"
            RESTORE_SOURCE="$2"
            shift 2
            ;;
        --db-host)
            DB_HOST="$2"
            shift 2
            ;;
        --db-port)
            DB_PORT="$2"
            shift 2
            ;;
        --db-user)
            DB_USER="$2"
            shift 2
            ;;
        --db-pass)
            DB_PASSWORD="$2"
            shift 2
            ;;
        --db-name)
            DB_NAME="$2"
            shift 2
            ;;
        --dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --s3)
            ENABLE_S3=true
            shift
            ;;
        --s3-alias)
            S3_ALIAS="$2"
            shift 2
            ;;
        --s3-bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        --s3-path)
            S3_PATH="$2"
            shift 2
            ;;
        --mc-cmd)
            MC_CMD="$2"
            shift 2
            ;;
        --s3-retention)
            S3_RETENTION_DAYS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

if [ "$ACTION" == "backup" ]; then
    do_backup
elif [ "$ACTION" == "restore" ]; then
    do_restore "$RESTORE_SOURCE"
else
    error "Please specify --backup or --restore."
    usage
fi
