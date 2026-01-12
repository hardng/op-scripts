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
S3_ENDPOINT=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""

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
  --db-pwd <pwd>                Database password (Default: ******)
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
  --s3-url <url>                S3 Endpoint URL (e.g., http://minio:9000).
  --s3-ak <access_key>          S3 Access Key.
  --s3-sk <secret_key>          S3 Secret Key.
  --mc-cmd <cmd>                MinIO Client command name (Default: $MC_CMD)

Examples:
  $0 --backup --s3 --s3-url http://localhost:9000 --s3-ak admin --s3-sk password --s3-bucket my-backups
  $0 --restore mcli/myminio/my-nacos-backups/nacos-db/nacos_db_20260109_1540.sql.gz
EOF
    exit 0
}

# --- Command Fallback Logic ---
# Check if a command exists locally, otherwise return a docker-run command
get_command() {
    local cmd=$1
    local image=$2
    local extra_flags=$3
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd"
    else
        # Fallback to Docker
        if command -v docker >/dev/null 2>&1; then
            echo "docker run --rm $extra_flags $image $cmd"
        else
            return 1
        fi
    fi
}

# --- Backup Logic ---
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local filename="nacos_db_${timestamp}.sql.gz"
    local filepath="${BACKUP_DIR}/${filename}"

    log "Starting backup: ${DB_NAME} from ${DB_HOST}..."
    
    local mysqldump_cmd
    mysqldump_cmd=$(get_command "mysqldump" "mysql:latest" "-i") || {
        error "Neither 'mysqldump' nor 'docker' found. Please install one of them."
        exit 1
    }
    
    # Execute dump and compress
    log "Executing dump..."
    # Flags explained:
    # --single-transaction: consistent backup for InnoDB without locking
    # --no-tablespaces: avoids privilege error for tablespace info
    # --column-statistics=0: avoids 8.0+ client error for statistics
    # --set-gtid-purged=OFF: avoids RELOAD privilege error on RDS/Managed DBs
    # --skip-lock-tables: ensures no locking is attempted
    local dump_flags="--single-transaction --no-tablespaces --column-statistics=0 --set-gtid-purged=OFF --skip-lock-tables"
    if [[ "$mysqldump_cmd" == *"docker"* ]]; then
        # If using docker, we pipe the output
        eval "$mysqldump_cmd -h\"$DB_HOST\" -P\"$DB_PORT\" -u\"$DB_USER\" -p\"$DB_PASSWORD\" $dump_flags \"$DB_NAME\"" | gzip > "$filepath"
    else
        $mysqldump_cmd -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" $dump_flags "$DB_NAME" | gzip > "$filepath"
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
    local mysql_cmd
    mysql_cmd=$(get_command "mysql" "mysql:latest" "-i") || {
        error "Neither 'mysql' nor 'docker' found. Please install one of them."
        exit 1
    }
    
    # Decompress and import
    if [[ "$mysql_cmd" == *"docker"* ]]; then
        gunzip < "$restore_file" | eval "$mysql_cmd -h\"$DB_HOST\" -P\"$DB_PORT\" -u\"$DB_USER\" -p\"$DB_PASSWORD\" \"$DB_NAME\""
    else
        gunzip < "$restore_file" | $mysql_cmd -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME"
    fi

    log "Restore completed successfully."
    
    # Clean up temp file if downloaded from S3/MinIO
    if [ "$restore_file" == "${BACKUP_DIR}/tmp_restore.sql.gz" ]; then
        rm -f "$restore_file"
    fi
}

# --- S3 Operations ---
setup_mcli_alias() {
    local mcli_cmd=$1
    if [ -n "$S3_ENDPOINT" ] && [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ]; then
        # mcli requires the URL to have a scheme (http/https)
        if [[ "$S3_ENDPOINT" != http://* ]] && [[ "$S3_ENDPOINT" != https://* ]]; then
            log "No scheme found in S3 URL, defaulting to http://"
            S3_ENDPOINT="http://${S3_ENDPOINT}"
        fi
        log "Configuring mcli alias: $S3_ALIAS (Endpoint: $S3_ENDPOINT)"
        # Use s3v4 with --path on to force path-style access for Aliyun OSS Access Points
        $mcli_cmd alias set "$S3_ALIAS" "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api s3v4 --path on >/dev/null 2>&1 || \
        $mcli_cmd alias set "$S3_ALIAS" "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api s3v4 >/dev/null
    fi
}

upload_to_s3() {
    local file=$1
    local name=$2
    
    local mcli_cmd
    # When using docker for mc, we need to mount the backup directory to access the file
    mcli_cmd=$(get_command "$MC_CMD" "minio/mc:latest" "-v \"$BACKUP_DIR:$BACKUP_DIR\" -v \"$HOME/.mc:/root/.mc\"") || {
        error "MinIO Client ($MC_CMD) not found and Docker is not available. Skipping S3 upload."
        return 1
    }

    setup_mcli_alias "$mcli_cmd"

    # Robust path handling
    local clean_path="${S3_PATH#/}" # Remove leading slash
    [[ -n "$clean_path" && "$clean_path" != */ ]] && clean_path="${clean_path}/" # Ensure trailing slash
    
    local target="${S3_ALIAS}/${S3_BUCKET}/${clean_path}${name}"
    log "Uploading to S3 (mcli): $target"
    $mcli_cmd cp "$file" "$target"
}

cleanup_s3() {
    log "Cleaning up old backups from S3 (Retention: ${S3_RETENTION_DAYS} days)..."
    local mcli_cmd
    mcli_cmd=$(get_command "$MC_CMD" "minio/mc:latest" "-v \"$HOME/.mc:/root/.mc\"") || return 1
    
    setup_mcli_alias "$mcli_cmd"
    
    local clean_path="${S3_PATH#/}"
    [[ -n "$clean_path" && "$clean_path" != */ ]] && clean_path="${clean_path}/"

    # Use mc find --older-than to delete old files
    $mcli_cmd rm --recursive --older-than "${S3_RETENTION_DAYS}d" "${S3_ALIAS}/${S3_BUCKET}/${clean_path}"
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
        --db-pwd)
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
        --s3-url)
            S3_ENDPOINT="$2"
            shift 2
            ;;
        --s3-ak)
            S3_ACCESS_KEY="$2"
            shift 2
            ;;
        --s3-sk)
            S3_SECRET_KEY="$2"
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
