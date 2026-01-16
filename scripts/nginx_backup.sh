#!/bin/bash
set -eo pipefail

# ==============================================================================
# Nginx Backup Script
# Features:
#   - Local Rsync: filtered backup of nginx.conf and conf.d/
#   - Local Packing: Compress into .tar.gz
#   - S3 integration (Upload & Retention) - Ported from nacos_backup.sh
# ==============================================================================

# --- Default Configurations ---
# Source Defaults
SOURCE_PATH="/etc/nginx"

# Local Defaults
BACKUP_DIR="/tmp/nginx-backups"
RETENTION_DAYS=7
KEEP_COUNT=1

# S3 Defaults
ENABLE_S3=false
S3_ALIAS=""
S3_BUCKET=""
S3_PATH="nginx-data/"
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
  --backup                      Perform an nginx backup.
  -h, --help                    Display this help message.

Source Configuration:
  --source-path <path>          Nginx Config Root (Default: $SOURCE_PATH)
                                Scripts expects 'nginx.conf' and 'conf.d/' inside this path.

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
  $0 --backup --source-path /etc/nginx --s3 ...
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
            files=$(eval "$mcli_cmd ls --json \"$target\"" | grep "nginx_backup_" | sed 's/.*"key":"\([^"]*\)".*/\1/' | sort -r)
        else
            files=$($mcli_cmd ls --json "$target" | grep "nginx_backup_" | sed 's/.*"key":"\([^"]*\)".*/\1/' | sort -r)
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
        find "$BACKUP_DIR" -maxdepth 1 -name "nginx_backup_*.tar.gz" -mtime +$RETENTION_DAYS -exec rm -f {} \;
    fi

    if [ "$KEEP_COUNT" -gt 0 ]; then
        log "Cleaning up local backups (Keeping latest: ${KEEP_COUNT})..."
        # shellcheck disable=SC2012
        ls -t "$BACKUP_DIR"/nginx_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) | xargs -r rm -f
    fi
}

# --- Backup Logic ---
do_backup() {
    if [ ! -d "$SOURCE_PATH" ]; then
        error "Source directory does not exist: $SOURCE_PATH"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local sync_dir="${BACKUP_DIR}/nginx_sync"
    local filename="nginx_backup_${timestamp}.tar.gz"
    local filepath="${BACKUP_DIR}/${filename}"
    
    rm -rf "$sync_dir"
    mkdir -p "$sync_dir"

    log "Starting Nginx Config Backup from ${SOURCE_PATH}..."
    
    # Check if files exist to warn user
    if [ ! -f "${SOURCE_PATH}/nginx.conf" ]; then
        log "WARNING: nginx.conf not found in ${SOURCE_PATH}"
    fi

    # Rsync with specific Nginx filters
    # - Include nginx.conf (at root)
    # - Include conf.d dir and everything inside
    # - Exclude everything else
    rsync -aq \
        --include='nginx.conf' \
        --include='conf.d/' \
        --include='conf.d/**' \
        --exclude='*' \
        "${SOURCE_PATH}/" "$sync_dir/" || {
            error "Rsync failed."
            exit 1
        }
    
    log "Files prepared in $sync_dir"

    log "Packing backup to $filepath..."
    tar -czf "$filepath" -C "$sync_dir" . || {
        error "Failed to create archive."
        exit 1
    }
    
    if [ -s "$filepath" ]; then
        local s3_success=false
        if [ "$ENABLE_S3" = true ]; then
            if upload_to_s3 "$filepath" "$filename"; then
                s3_success=true
                cleanup_s3
            fi
        fi
        
        if [ "$s3_success" = true ] && [ "$S3_CLEANUP_LOCAL" = true ]; then
            log "S3 upload successful, deleting local tarball."
            rm -f "$filepath"
        fi
        
        rm -rf "$sync_dir"
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
        --source-path)
            SOURCE_PATH="$2"
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
