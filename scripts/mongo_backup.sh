#!/bin/bash
set -eo pipefail

# ==============================================================================
# MongoDB Backup Script
# Features:
#   - mongodump: Archive mode + Gzip (Single file output)
#   - Connection: Supports both Simple args and URI (for ReplicaSet/Cluster)
#   - S3 integration (Upload & Retention) - Ported from nacos_backup.sh
# ==============================================================================

# --- Default Configurations ---
# Database Defaults
DB_HOST=""
DB_PORT="27017"
DB_USER=""
DB_PWD=""
DB_NAME=""
MONGO_URI=""

# Local Defaults
BACKUP_DIR="/tmp/mongo-backups"
RETENTION_DAYS=7
KEEP_COUNT=1

# S3 Defaults
ENABLE_S3=false
S3_ALIAS=""
S3_BUCKET=""
S3_PATH="mongo-data/"
S3_RETENTION_DAYS=30
S3_KEEP_COUNT=1
S3_CLEANUP_LOCAL=false
# Auto-detect mcli or mc
if command -v mcli >/dev/null 2>&1; then
    MC_CMD="mcli"
elif command -v mc >/dev/null 2>&1; then
    MC_CMD="mc"
else
    MC_CMD="mcli"
fi

# Detect config directory: prefer .mcli if it exists, otherwise .mc
if [ -d "$HOME/.mcli" ]; then
    MC_CONFIG_DIR="$HOME/.mcli"
else
    MC_CONFIG_DIR="$HOME/.mc"
fi

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
  --backup                      Perform a MongoDB backup.
  -h, --help                    Display this help message.

Connection Configuration (Choose A or B):
  A. Simple (Standalone):
    --host <host>               Database Host IP (Default: 127.0.0.1 if not set)
    --port <port>               Database Port (Default: 27017)
    --user <user>               Database Username
    --pwd <password>            Database Password
    --db <name>                 Database Name (Optional, dumps all if omitted)

  B. Advanced (Replica Set / Cluster):
    --uri <uri>                 MongoDB Connection URI (Overrides simple args)
                                e.g. "mongodb://user:pass@host1:27017,host2:27017/?replicaSet=rs0"

Local Configuration:
  --dir <path>                  Temporary backup directory (Default: $BACKUP_DIR)
  --retention <days>            Local retention days (Default: $RETENTION_DAYS)
  --keep-count <count>          Local retention count (Default: $KEEP_COUNT, 0 to disable)

S3 Configuration:
  --s3                          Enable S3 backup.
  --s3-alias <alias>            S3 alias for mcli (Default: same as --s3-bucket)
  --s3-bucket <bucket>          S3 bucket name.
  --s3-path <path>              S3 path prefix (Default: $S3_PATH)
  --s3-retention <days>         S3 retention days (Default: $S3_RETENTION_DAYS)
  --s3-keep-count <count>       S3 retention count (Default: $S3_KEEP_COUNT, 0 to disable)
  --s3-cleanup-local            Delete local backup file after successful S3 upload.
  --s3-url <url>                S3 Endpoint URL.
  --s3-ak <access_key>          S3 Access Key.
  --s3-sk <secret_key>          S3 Secret Key.
  --mc-cmd <cmd>                MinIO Client command name (Default: $MC_CMD)

Examples:
  # Simple
  $0 --backup --host 127.0.0.1 --db mydb --user admin --pwd pass --s3 ...
  
  # URI (Replica Set)
  $0 --backup --uri "mongodb://user:pass@h1,h2/?replicaSet=rs0" --s3 ...
EOF
    exit 0
}

# --- Command Fallback Logic ---
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

# --- S3 Operations ---
setup_mcli_alias() {
    local mcli_cmd=$1
    if [ -n "$S3_ENDPOINT" ] && [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ]; then
        if [[ "$S3_ENDPOINT" != http://* ]] && [[ "$S3_ENDPOINT" != https://* ]]; then
            log "No scheme found in S3 URL, defaulting to http://"
            S3_ENDPOINT="http://${S3_ENDPOINT}"
        fi

        # Virtual Hosted Style fix
        if [ -n "$S3_BUCKET" ]; then
            local domain="${S3_ENDPOINT#*://}"
            # Check if domain is an IP address using regex
            if [[ ! "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
                if [[ "$domain" != "${S3_BUCKET}."* ]]; then
                     if [[ "$S3_ENDPOINT" != *"aliyuncs.com"* ]] && [[ "$S3_ENDPOINT" != *"accesspoint"* ]]; then
                         log "Prepending bucket to endpoint for Virtual Hosted Style: ${S3_BUCKET}.${domain}"
                         if [[ "$S3_ENDPOINT" == https://* ]]; then
                             S3_ENDPOINT="https://${S3_BUCKET}.${domain}"
                         else
                             S3_ENDPOINT="http://${S3_BUCKET}.${domain}"
                         fi
                     fi
                fi
            else
                log "Endpoint is an IP address, skipping Virtual Hosted Style adjustment."
            fi
        fi

        log "Configuring mcli alias: $S3_ALIAS (Endpoint: $S3_ENDPOINT)"
        mkdir -p "$MC_CONFIG_DIR"

        local lookup_flag=""
        if [[ "$S3_ENDPOINT" == *"aliyuncs.com"* ]]; then
             lookup_flag="--path on"
        fi

        if [[ "$mcli_cmd" == *"docker"* ]]; then
            eval "$mcli_cmd alias set \"$S3_ALIAS\" \"$S3_ENDPOINT\" \"$S3_ACCESS_KEY\" \"$S3_SECRET_KEY\" --api s3v4 $lookup_flag"
        else
            $mcli_cmd alias set "$S3_ALIAS" "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api s3v4 $lookup_flag
        fi
    fi
}

upload_to_s3() {
    local file=$1
    local name=$2
    
    local mcli_cmd
    mcli_cmd=$(get_command "$MC_CMD" "minio/mc:latest" "-v \"$BACKUP_DIR:$BACKUP_DIR\" -v \"$MC_CONFIG_DIR:/root/.mc\"" "") || {
        error "MinIO Client ($MC_CMD) not found. Skipping S3 upload."
        return 1
    }
    setup_mcli_alias "$mcli_cmd"

    local clean_path="${S3_PATH#/}"
    [[ -n "$clean_path" && "$clean_path" != */ ]] && clean_path="${clean_path}/"
    
    local target
    local endpoint_no_proto="${S3_ENDPOINT#*://}"
    
    if [[ "$S3_ENDPOINT" == *"accesspoint.aliyuncs.com"* ]] || \
       { [ -n "$S3_BUCKET" ] && [[ "$endpoint_no_proto" == "${S3_BUCKET}."* ]]; }; then
        target="${S3_ALIAS}/${clean_path}${name}"
    elif [ -n "$S3_BUCKET" ]; then
        target="${S3_ALIAS}/${S3_BUCKET}/${clean_path}${name}"
    else
        target="${S3_ALIAS}/${clean_path}${name}"
    fi

    log "Uploading to S3: $target"
    if [[ "$mcli_cmd" == *"docker"* ]]; then
        eval "$mcli_cmd cp \"$file\" \"$target\""
    else
        $mcli_cmd cp "$file" "$target"
    fi
}

cleanup_s3() {
    local mcli_cmd
    mcli_cmd=$(get_command "$MC_CMD" "minio/mc:latest" "-v \"$MC_CONFIG_DIR:/root/.mc\"" "") || return 1
    setup_mcli_alias "$mcli_cmd"
    
    local clean_path="${S3_PATH#/}"
    [[ -n "$clean_path" && "$clean_path" != */ ]] && clean_path="${clean_path}/"
    
    local target
    local endpoint_no_proto="${S3_ENDPOINT#*://}"

    if [[ "$S3_ENDPOINT" == *"accesspoint.aliyuncs.com"* ]] || \
       { [ -n "$S3_BUCKET" ] && [[ "$endpoint_no_proto" == "${S3_BUCKET}."* ]]; }; then
        target="${S3_ALIAS}/${clean_path}"
    elif [ -n "$S3_BUCKET" ]; then
        target="${S3_ALIAS}/${S3_BUCKET}/${clean_path}"
    else
        target="${S3_ALIAS}/${clean_path}"
    fi

    if [ "$S3_RETENTION_DAYS" -gt 0 ]; then
        log "Cleaning up old S3 backups (Retention: ${S3_RETENTION_DAYS} days)..."
        if [[ "$mcli_cmd" == *"docker"* ]]; then
            eval "$mcli_cmd rm --recursive --older-than \"${S3_RETENTION_DAYS}d\" \"$target\"" >/dev/null 2>&1 || true
        else
            $mcli_cmd rm --recursive --older-than "${S3_RETENTION_DAYS}d" "$target" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$S3_KEEP_COUNT" -gt 0 ]; then
        log "Cleaning up old S3 backups (Keeping latest: ${S3_KEEP_COUNT})..."
        local files
        if [[ "$mcli_cmd" == *"docker"* ]]; then
            files=$(eval "$mcli_cmd ls --json \"$target\"" | grep "mongo_backup_" | sed 's/.*"key":"\([^"]*\)".*/\1/' | sort -r)
        else
            files=$($mcli_cmd ls --json "$target" | grep "mongo_backup_" | sed 's/.*"key":"\([^"]*\)".*/\1/' | sort -r)
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
    if [ "$RETENTION_DAYS" -gt 0 ]; then
        log "Cleaning up local backups older than ${RETENTION_DAYS} days..."
        find "$BACKUP_DIR" -maxdepth 1 -name "mongo_backup_*.archive.gz" -mtime +$RETENTION_DAYS -exec rm -f {} \;
    fi

    if [ "$KEEP_COUNT" -gt 0 ]; then
        log "Cleaning up local backups (Keeping latest: ${KEEP_COUNT})..."
        # shellcheck disable=SC2012
        ls -t "$BACKUP_DIR"/mongo_backup_*.archive.gz 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) | xargs -r rm -f
    fi
}

# --- Backup Logic ---
do_backup() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local filename="mongo_backup_${timestamp}.archive.gz"
    local filepath="${BACKUP_DIR}/${filename}"
    
    log "Starting MongoDB Backup..."

    local mongodump_cmd_args=""
    local use_uri=false

    # 1. Determine Arguments
    if [ -n "$MONGO_URI" ]; then
        log "Using MongoDB URI..."
        use_uri=true
        mongodump_cmd_args="--uri=\"$MONGO_URI\""
    else
        log "Using Host/Port/User args..."
        [ -z "$DB_HOST" ] && DB_HOST="127.0.0.1"
        mongodump_cmd_args="--host \"$DB_HOST\" --port \"$DB_PORT\""
        
        if [ -n "$DB_USER" ] && [ -n "$DB_PWD" ]; then
            mongodump_cmd_args="$mongodump_cmd_args --username \"$DB_USER\" --password \"$DB_PWD\""
        fi
        
        if [ -n "$DB_NAME" ]; then
            mongodump_cmd_args="$mongodump_cmd_args --db \"$DB_NAME\""
        fi
    fi

    # Append output args
    # Explicitly ensure --gzip is separate
    mongodump_cmd_args="$mongodump_cmd_args --archive=\"$filepath\" --gzip"

    # 2. Get Command (Local or Docker)
    if command -v mongodump >/dev/null 2>&1; then
        # Local execution
        log "Executing: mongodump $mongodump_cmd_args"
        eval "mongodump $mongodump_cmd_args" || {
            error "mongodump failed."
            exit 1
        }
    else
        # Docker execution
        if command -v docker >/dev/null 2>&1; then
            log "mongodump not found locally, using Docker..."
            
            # Construct docker command string for logging and execution
            local docker_run_cmd="docker run --rm -v \"$BACKUP_DIR:$BACKUP_DIR\" mongo:latest mongodump $mongodump_cmd_args"
            log "Executing: $docker_run_cmd"
            
            eval "$docker_run_cmd" || {
                error "Docker mongodump failed."
                exit 1
            }
        else
            error "Neither mongodump nor docker found."
            exit 1
        fi
    fi
    
    log "Backup created at $filepath"

    
    if [ -s "$filepath" ]; then
        local s3_success=false
        if [ "$ENABLE_S3" = true ]; then
            if upload_to_s3 "$filepath" "$filename"; then
                s3_success=true
                cleanup_s3
            fi
        fi
        
        if [ "$s3_success" = true ] && [ "$S3_CLEANUP_LOCAL" = true ]; then
            log "S3 upload successful, deleting local file."
            rm -f "$filepath"
        fi
        
        cleanup_local
    else
        error "Backup file is empty."
        rm -f "$filepath"
        exit 1
    fi
}

# --- CLI Parsing ---
if [[ $# -eq 0 ]]; then
    usage
fi

ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup)
            ACTION="backup"
            shift
            ;;
        --host)
            DB_HOST="$2"
            shift 2
            ;;
        --port)
            DB_PORT="$2"
            shift 2
            ;;
        --user)
            DB_USER="$2"
            shift 2
            ;;
        --pwd)
            DB_PWD="$2"
            shift 2
            ;;
        --db)
            DB_NAME="$2"
            shift 2
            ;;
        --uri)
            MONGO_URI="$2"
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

if [ -z "$S3_ALIAS" ]; then
    if [ -n "$S3_BUCKET" ]; then
        S3_ALIAS="$S3_BUCKET"
    else
        S3_ALIAS="myminio"
    fi
fi

if [[ "$S3_ALIAS" =~ ^[0-9] ]]; then
    S3_ALIAS="s3-${S3_ALIAS}"
fi
S3_ALIAS=$(echo "$S3_ALIAS" | sed 's/[^a-zA-Z0-9_-]/_/g')

if [ "$ACTION" == "backup" ]; then
    do_backup
else
    error "Please specify --backup."
    usage
fi
