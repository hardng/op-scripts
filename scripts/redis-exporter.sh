#!/bin/bash

set -euo pipefail

# Default configuration
DEFAULT_VERSION="1.55.0"
REDIS_EXPORTER_USER="redis_exporter"
REDIS_EXPORTER_GROUP="redis_exporter"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
LOG_DIR="/var/log/redis_exporter"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat << EOF
Redis Exporter Installation Script

USAGE:
    $0 [COMMAND] [OPTIONS]

COMMANDS:
    install     Install redis-exporter
    uninstall   Remove redis-exporter
    update      Update redis-exporter to specified version

OPTIONS:
    -v, --version VERSION       Specify version to install/update (default: ${DEFAULT_VERSION})
    -a, --addr ADDRESS         Redis address (default: localhost:6379)
    -u, --user USERNAME        Redis username (for Redis 6.0+ ACL)
    -p, --password PASSWORD    Redis password
    -w, --web-port PORT        Web listen port (default: 9121)
    -c, --cluster              Enable Redis cluster mode
    -h, --help                 Show this help message

EXAMPLES:
    $0 install                                    # Install default version
    $0 install -v 1.54.0                        # Install specific version
    $0 install -a localhost:6379                # Install with Redis address
    $0 install -a 172.20.33.139:6379 -p 42QbQcwCFWTUh8m -w 56379  # With auth and custom port
    $0 install -a redis-node1:6379 -c           # Install for Redis cluster
    $0 update -v 1.56.0                         # Update to specific version
    $0 uninstall                                 # Remove redis-exporter

SUPPORTED SYSTEMS:
    - RedHat/CentOS/Rocky/AlmaLinux 8, 9, 10
    - Debian 10, 11, 12
    - Ubuntu 20.04, 22.04, 24.04

EOF
}

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_MAJOR_VERSION=$(echo $VERSION_ID | cut -d. -f1)
    else
        error "Cannot detect operating system"
        exit 1
    fi

    case $OS in
        "rhel"|"centos"|"rocky"|"almalinux")
            if [[ ! "$OS_MAJOR_VERSION" =~ ^(8|9|10)$ ]]; then
                error "Unsupported RedHat-based version: $OS_VERSION"
                exit 1
            fi
            PKG_MANAGER="dnf"
            SUPPORTED_OS="redhat"
            ;;
        "debian")
            if [[ ! "$OS_MAJOR_VERSION" =~ ^(10|11|12)$ ]]; then
                error "Unsupported Debian version: $OS_VERSION"
                exit 1
            fi
            PKG_MANAGER="apt"
            SUPPORTED_OS="debian"
            ;;
        "ubuntu")
            if [[ ! "$OS_VERSION" =~ ^(20\.04|22\.04|24\.04)$ ]]; then
                error "Unsupported Ubuntu version: $OS_VERSION"
                exit 1
            fi
            PKG_MANAGER="apt"
            SUPPORTED_OS="debian"
            ;;
        *)
            error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac

    log "Detected OS: $OS $OS_VERSION"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

install_dependencies() {
    log "Installing dependencies..."
    
    case $SUPPORTED_OS in
        "redhat")
            $PKG_MANAGER install -y wget curl tar
            ;;
        "debian")
            apt-get update
            apt-get install -y wget curl tar
            ;;
    esac
}

create_user() {
    if ! id "$REDIS_EXPORTER_USER" &>/dev/null; then
        log "Creating user: $REDIS_EXPORTER_USER"
        useradd --system --no-create-home --shell /bin/false "$REDIS_EXPORTER_USER"
    else
        log "User $REDIS_EXPORTER_USER already exists"
    fi
}

create_directories() {
    log "Creating directories..."
    mkdir -p "$LOG_DIR"
    chown "$REDIS_EXPORTER_USER:$REDIS_EXPORTER_GROUP" "$LOG_DIR"
    chmod 755 "$LOG_DIR"
}

download_redis_exporter() {
    local version=$1
    local arch=$(uname -m)
    
    case $arch in
        x86_64)
            arch="amd64"
            ;;
        aarch64)
            arch="arm64"
            ;;
        *)
            error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    local download_url="https://github.com/oliver006/redis_exporter/releases/download/v${version}/redis_exporter-v${version}.linux-${arch}.tar.gz"
    local temp_dir=$(mktemp -d)
    
    log "Downloading redis_exporter v${version} for ${arch}..."
    
    if ! wget -q -O "${temp_dir}/redis_exporter.tar.gz" "$download_url"; then
        error "Failed to download redis_exporter v${version}"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    log "Extracting redis_exporter..."
    tar -xzf "${temp_dir}/redis_exporter.tar.gz" -C "$temp_dir"
    
    if [[ -f "${temp_dir}/redis_exporter-v${version}.linux-${arch}/redis_exporter" ]]; then
        cp "${temp_dir}/redis_exporter-v${version}.linux-${arch}/redis_exporter" "$INSTALL_DIR/"
    elif [[ -f "${temp_dir}/redis_exporter" ]]; then
        cp "${temp_dir}/redis_exporter" "$INSTALL_DIR/"
    else
        error "redis_exporter binary not found in archive"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    chmod +x "${INSTALL_DIR}/redis_exporter"
    rm -rf "$temp_dir"
    
    log "redis_exporter v${version} installed to $INSTALL_DIR"
}

create_systemd_service() {
    local redis_addr=${1:-"localhost:6379"}
    local redis_user=${2:-""}
    local redis_password=${3:-""}
    local web_port=${4:-"9121"}
    local is_cluster=${5:-"false"}
    
    log "Creating systemd service file..."
    
    # Build the ExecStart command
    local exec_start="$INSTALL_DIR/redis_exporter"
    exec_start="$exec_start -redis.addr=$redis_addr"
    exec_start="$exec_start -web.listen-address=:$web_port"
    exec_start="$exec_start -web.telemetry-path=/metrics"
    exec_start="$exec_start -log-format=txt"
    
    if [[ -n "$redis_user" ]]; then
        exec_start="$exec_start -redis.user=$redis_user"
    fi
    
    if [[ -n "$redis_password" ]]; then
        # Create password file for security
        local password_file="/etc/redis_exporter_password"
        echo "{ \"redis://${redis_addr}\": \"${redis_password}\" }" > "$password_file"
        chmod 600 "$password_file"
        chown "$REDIS_EXPORTER_USER:$REDIS_EXPORTER_GROUP" "$password_file"
        exec_start="$exec_start -redis.password-file=$password_file"
    fi
    
    if [[ "$is_cluster" == "true" ]]; then
        exec_start="$exec_start -is-cluster"
    fi
    
    cat > "${SERVICE_DIR}/redis_exporter.service" << EOF
[Unit]
Description=Redis Exporter
Documentation=https://github.com/oliver006/redis_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$REDIS_EXPORTER_USER
Group=$REDIS_EXPORTER_GROUP
ExecStart=$exec_start
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=redis_exporter

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$LOG_DIR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

install_redis_exporter() {
    local version=${1:-$DEFAULT_VERSION}
    local redis_addr=${2:-"localhost:6379"}
    local redis_user=${3:-""}
    local redis_password=${4:-""}
    local web_port=${5:-"9121"}
    local is_cluster=${6:-"false"}
    
    log "Starting redis_exporter installation (version: $version)..."
    
    detect_os
    check_root
    install_dependencies
    create_user
    create_directories
    download_redis_exporter "$version"
    create_systemd_service "$redis_addr" "$redis_user" "$redis_password" "$web_port" "$is_cluster"
    
    log "Enabling and starting redis_exporter service..."
    systemctl enable redis_exporter
    systemctl start redis_exporter
    
    log "Installation completed successfully!"
    log "Service status:"
    systemctl status redis_exporter --no-pager -l
    log ""
    log "Logs: journalctl -u redis_exporter -f"
    log "Metrics endpoint: http://localhost:$web_port/metrics"
    log "Redis connection: $redis_addr"
    if [[ "$is_cluster" == "true" ]]; then
        log "Redis cluster mode: ENABLED"
    fi
    if [[ -n "$redis_password" ]]; then
        log "Password file: /etc/redis_exporter_password"
    fi
}

uninstall_redis_exporter() {
    log "Starting redis_exporter uninstallation..."
    
    check_root
    
    # Stop and disable service
    if systemctl is-active redis_exporter &>/dev/null; then
        log "Stopping redis_exporter service..."
        systemctl stop redis_exporter
    fi
    
    if systemctl is-enabled redis_exporter &>/dev/null; then
        log "Disabling redis_exporter service..."
        systemctl disable redis_exporter
    fi
    
    # Remove files
    log "Removing files..."
    rm -f "${SERVICE_DIR}/redis_exporter.service"
    rm -f "${INSTALL_DIR}/redis_exporter"
    rm -f "/etc/redis_exporter_password"
    
    # Ask user about configuration and logs
    read -p "Remove log files? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        log "Log files removed"
    fi
    
    read -p "Remove user '$REDIS_EXPORTER_USER'? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        userdel "$REDIS_EXPORTER_USER" &>/dev/null || true
        log "User removed"
    fi
    
    systemctl daemon-reload
    
    log "Uninstallation completed!"
}

update_redis_exporter() {
    local version=${1:-$DEFAULT_VERSION}
    
    log "Starting redis_exporter update to version $version..."
    
    check_root
    
    if [[ ! -f "${INSTALL_DIR}/redis_exporter" ]]; then
        error "redis_exporter is not installed"
        exit 1
    fi
    
    # Get current version
    current_version=$("${INSTALL_DIR}/redis_exporter" --version 2>&1 | grep -oP 'version \K[0-9.]+' || echo "unknown")
    log "Current version: $current_version"
    log "Target version: $version"
    
    if [[ "$current_version" == "$version" ]]; then
        log "Already running version $version"
        return 0
    fi
    
    # Stop service
    log "Stopping redis_exporter service..."
    systemctl stop redis_exporter
    
    # Backup current binary
    cp "${INSTALL_DIR}/redis_exporter" "${INSTALL_DIR}/redis_exporter.backup"
    
    # Download new version
    if ! download_redis_exporter "$version"; then
        error "Failed to download new version, restoring backup..."
        cp "${INSTALL_DIR}/redis_exporter.backup" "${INSTALL_DIR}/redis_exporter"
        systemctl start redis_exporter
        exit 1
    fi
    
    # Start service
    log "Starting redis_exporter service..."
    systemctl start redis_exporter
    
    # Cleanup backup
    rm -f "${INSTALL_DIR}/redis_exporter.backup"
    
    log "Update completed successfully!"
    log "Service status:"
    systemctl status redis_exporter --no-pager -l
}

main() {
    local command=""
    local version=""
    local redis_addr="localhost:6379"
    local redis_user=""
    local redis_password=""
    local web_port="9121"
    local is_cluster="false"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            install|uninstall|update)
                command=$1
                shift
                ;;
            -v|--version)
                version=$2
                shift 2
                ;;
            -a|--addr)
                redis_addr=$2
                shift 2
                ;;
            -u|--user)
                redis_user=$2
                shift 2
                ;;
            -p|--password)
                redis_password=$2
                shift 2
                ;;
            -w|--web-port)
                web_port=$2
                shift 2
                ;;
            -c|--cluster)
                is_cluster="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Check if command is provided
    if [[ -z "$command" ]]; then
        error "No command specified"
        usage
        exit 1
    fi
    
    # Set default version if not specified
    if [[ -z "$version" ]]; then
        version=$DEFAULT_VERSION
    fi
    
    # Execute command
    case $command in
        install)
            install_redis_exporter "$version" "$redis_addr" "$redis_user" "$redis_password" "$web_port" "$is_cluster"
            ;;
        uninstall)
            uninstall_redis_exporter
            ;;
        update)
            update_redis_exporter "$version"
            ;;
        *)
            error "Invalid command: $command"
            usage
            exit 1
            ;;
    esac
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi