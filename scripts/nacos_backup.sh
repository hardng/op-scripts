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
KEEP_COUNT=1

ENABLE_S3=false
S3_ALIAS=""
S3_BUCKET="my-nacos-backups"
S3_PATH="nacos-db/"
S3_RETENTION_DAYS=30
S3_KEEP_COUNT=1
S3_CLEANUP_LOCAL=false
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
  --keep-count <count>          Local retention count (Default: $KEEP_COUNT, 0 to disable)

S3 Configuration:
  --s3                          Enable S3 backup (via MinIO Client).
  --s3-alias <alias>            S3 alias for mcli (Default: same as --s3-bucket)
  --s3-bucket <bucket>          S3 bucket name.
  --s3-path <path>              S3 path prefix (Default: $S3_PATH)
  --s3-retention <days>         S3 retention days (Default: $S3_RETENTION_DAYS)
  --s3-keep-count <count>       S3 retention count (Default: $S3_KEEP_COUNT, 0 to disable)
  --s3-cleanup-local            Delete local backup file after successful S3 upload.
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
    local container_cmd=${4-$cmd}
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd"
    else
        # Fallback to Docker
        if command -v docker >/dev/null 2>&1; then
            echo "docker run --rm $extra_flags $image $container_cmd"
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
        local s3_success=false
        if [ "$ENABLE_S3" = true ]; then
            if upload_to_s3 "$filepath" "$filename"; then
                s3_success=true
                cleanup_s3
            fi
        fi
        
        # Clean up local file if S3 succeeded and cleanup is requested
        if [ "$s3_success" = true ] && [ "$S3_CLEANUP_LOCAL" = true ]; then
            log "S3 upload successful, deleting local backup: $filepath"
            rm -f "$filepath"
        fi

        # Global Local Cleanup (Retention)
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
        
        local mcli_cmd
        mcli_cmd=$(get_command "$MC_CMD" "minio/mc:latest" "-v \"$BACKUP_DIR:$BACKUP_DIR\" -v \"$HOME/.mc:/root/.mc\"" "") || {
            error "MinIO Client ($MC_CMD) not found. Skipping S3 download."
            exit 1
        }
        setup_mcli_alias "$mcli_cmd"

        if [[ "$mcli_cmd" == *"docker"* ]]; then
            eval "$mcli_cmd cp \"$source\" \"$restore_file\""
        else
            $mcli_cmd cp "$source" "$restore_file"
        fi
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
        # Ensure host config dir exists
        mkdir -p "$HOME/.mc"

        # Aliyun Access Point auto-detection for Path-Style access
        local path_flag=""
        if [[ "$S3_ENDPOINT" == *"accesspoint.aliyuncs.com"* ]]; then
            log "Aliyun Access Point detected: Enabling Path-Style access (--path on)"
            path_flag="--path on"
        fi

        if [[ "$mcli_cmd" == *"docker"* ]]; then
            eval "$mcli_cmd alias set \"$S3_ALIAS\" \"$S3_ENDPOINT\" \"$S3_ACCESS_KEY\" \"$S3_SECRET_KEY\" --api s3v4 $path_flag"
        else
            $mcli_cmd alias set "$S3_ALIAS" "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api s3v4 $path_flag
        fi
    fi
}

upload_to_s3() {
    local file=$1
    local name=$2
    
    local mcli_cmd
    # Use empty string for container_cmd because minio/mc entrypoint is already 'mc'
    mcli_cmd=$(get_command "$MC_CMD" "minio/mc:latest" "-v \"$BACKUP_DIR:$BACKUP_DIR\" -v \"$HOME/.mc:/root/.mc\"" "") || {
        error "MinIO Client ($MC_CMD) not found. Skipping S3 upload."
        return 1
    }

    setup_mcli_alias "$mcli_cmd"

    # Robust path handling
    local clean_path="${S3_PATH#/}" # Remove leading slash
    [[ -n "$clean_path" && "$clean_path" != */ ]] && clean_path="${clean_path}/" # Ensure trailing slash
    
    local target
    if [ -n "$S3_BUCKET" ]; then
        target="${S3_ALIAS}/${S3_BUCKET}/${clean_path}${name}"
    else
        target="${S3_ALIAS}/${clean_path}${name}"
    fi

    log "Uploading to S3 (mcli): $target"
    if [[ "$mcli_cmd" == *"docker"* ]]; then
        eval "$mcli_cmd cp \"$file\" \"$target\""
    else
        $mcli_cmd cp "$file" "$target"
    fi
}

cleanup_s3() {
    local mcli_cmd
    mcli_cmd=$(get_command "$MC_CMD" "minio/mc:latest" "-v \"$HOME/.mc:/root/.mc\"" "") || return 1
    setup_mcli_alias "$mcli_cmd"
    
    local clean_path="${S3_PATH#/}"
    [[ -n "$clean_path" && "$clean_path" != */ ]] && clean_path="${clean_path}/"
    
    local target
    if [ -n "$S3_BUCKET" ]; then
        target="${S3_ALIAS}/${S3_BUCKET}/${clean_path}"
    else
        target="${S3_ALIAS}/${clean_path}"
    fi

    # 1. Time-based retention
    if [ "$S3_RETENTION_DAYS" -gt 0 ]; then
        log "Cleaning up old S3 backups (Retention: ${S3_RETENTION_DAYS} days)..."
        if [[ "$mcli_cmd" == *"docker"* ]]; then
            eval "$mcli_cmd rm --recursive --older-than \"${S3_RETENTION_DAYS}d\" \"$target\"" >/dev/null 2>&1 || true
        else
            $mcli_cmd rm --recursive --older-than "${S3_RETENTION_DAYS}d" "$target" >/dev/null 2>&1 || true
        fi
    fi

    # 2. Count-based retention
    if [ "$S3_KEEP_COUNT" -gt 0 ]; then
        log "Cleaning up old S3 backups (Keeping latest: ${S3_KEEP_COUNT})..."
        local files
        if [[ "$mcli_cmd" == *"docker"* ]]; then
            files=$(eval "$mcli_cmd ls --json \"$target\"" | grep "nacos_db_" | sed 's/.*"key":"\([^"]*\)".*/\1/' | sort -r)
        else
            files=$($mcli_cmd ls --json "$target" | grep "nacos_db_" | sed 's/.*"key":"\([^"]*\)".*/\1/' | sort -r)
        fi
        
        local count=0
        while read -r line; do
            [ -z "$line" ] && continue
            count=$((count + 1))
            if [ "$count" -gt "$S3_KEEP_COUNT" ]; then
                log "Deleting excess S3 backup: $line"
                if [[ "$mcli_cmd" == *"docker"* ]]; then
                    eval "$mcli_cmd rm \"${target}${line}\"" >/dev/null 2>&1
                else
                    $mcli_cmd rm "${target}${line}" >/dev/null 2>&1
                fi
            fi
        done <<< "$files"
    fi
}

cleanup_local() {
    # 1. Time-based retention
    if [ "$RETENTION_DAYS" -gt 0 ]; then
        log "Cleaning up local backups older than ${RETENTION_DAYS} days..."
        find "$BACKUP_DIR" -name "nacos_db_*.sql.gz" -mtime +$RETENTION_DAYS -exec rm -f {} \;
    fi

    # 2. Count-based retention
    if [ "$KEEP_COUNT" -gt 0 ]; then
        log "Cleaning up local backups (Keeping latest: ${KEEP_COUNT})..."
        # List files by time (newest first), skip the first KEEP_COUNT, and delete the rest
        # shellcheck disable=SC2012
        ls -t "$BACKUP_DIR"/nacos_db_*.sql.gz 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) | xargs -r rm -f
    fi
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
        --s3-keep-count)
            S3_KEEP_COUNT="$2"
            shift 2
            ;;
        --s3-cleanup-local)
            S3_CLEANUP_LOCAL=true
            shift
            ;;
        --keep-count)
            KEEP_COUNT="$2"
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

# Determine S3_ALIAS: 
# 1. User specified via --s3-alias 
# 2. Otherwise default to S3_BUCKET if bucket is specified
# 3. Last fallback to 'myminio'
if [ -z "$S3_ALIAS" ]; then
    if [ -n "$S3_BUCKET" ]; then
        S3_ALIAS="$S3_BUCKET"
    else
        S3_ALIAS="myminio"
    fi
fi

# DEBUG: Final alias confirmation
# log "DEBUG: S3_ALIAS=$S3_ALIAS, S3_BUCKET=$S3_BUCKET"

if [ "$ACTION" == "backup" ]; then
    do_backup
elif [ "$ACTION" == "restore" ]; then
    do_restore "$RESTORE_SOURCE"
else
    error "Please specify --backup or --restore."
    usage
fi
