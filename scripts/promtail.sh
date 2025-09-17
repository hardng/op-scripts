#!/bin/bash

# =============================================================================
# Promtail Automatic Installation Script for Virtual Machines
# Supported: Ubuntu/Debian, CentOS/RHEL, Low-resource VM optimization
# Features: Auto-install Promtail, configure log collection, systemd service
# =============================================================================

set -e

# Configuration variables
PROMTAIL_VERSION="2.9.0"
PROMTAIL_USER="promtail"
PROMTAIL_GROUP="promtail"
INSTALL_DIR="/opt/promtail"
CONFIG_DIR="/etc/promtail"
DATA_DIR="/var/lib/promtail"
LOG_DIR="/var/log/promtail"
LOKI_URL=""  # User must specify external Loki address

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Show help information
show_help() {
    cat << EOF
Promtail Automatic Installation Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -v, --version VERSION    Specify Promtail version (default: $PROMTAIL_VERSION)
    -l, --loki-url URL       Specify Loki server URL (required)
    -u, --user USER          Running user (default: $PROMTAIL_USER)
    --low-resource           Enable low-resource VM optimization mode
    -h, --help               Show this help message

EXAMPLES:
    $0 -l http://loki.example.com:3100          # Basic installation
    $0 -v 2.8.0 -l http://loki:3100             # Specify version and Loki URL
    $0 --low-resource -l http://loki:3100       # Low-resource VM optimization mode
    $0 -u myuser -l http://loki:3100            # Custom user

DESCRIPTION:
    This script automatically installs and configures Promtail for log collection
    in virtual machine environments. It supports multiple Linux distributions and
    provides optimization for low-resource environments.

FEATURES:
    - Multi-distribution support (Ubuntu/Debian/CentOS/RHEL/Fedora)
    - Multi-architecture support (amd64/arm64/arm)
    - Automatic service configuration with systemd
    - Log rotation setup
    - Low-resource optimization for constrained environments
    - Security hardening with dedicated user

REQUIREMENTS:
    - Root privileges (run with sudo)
    - Internet connection for downloading Promtail
    - External Loki server (not installed by this script)
    - systemd-based Linux distribution

POST-INSTALLATION:
    - Service status: systemctl status promtail
    - View logs: journalctl -u promtail -f
    - Config file: $CONFIG_DIR/config.yml
    - Test config: promtail -config.file=$CONFIG_DIR/config.yml -dry-run

EOF
}

# Parse command line arguments
parse_args() {
    LOW_RESOURCE=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                PROMTAIL_VERSION="$2"
                shift 2
                ;;
            -l|--loki-url)
                LOKI_URL="$2"
                shift 2
                ;;
            -u|--user)
                PROMTAIL_USER="$2"
                PROMTAIL_GROUP="$2"
                shift 2
                ;;
            --low-resource)
                LOW_RESOURCE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown parameter: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script requires root privileges"
        echo "Please run with: sudo $0"
        exit 1
    fi
}

# Validate Loki URL
check_loki_url() {
    if [[ -z "$LOKI_URL" ]]; then
        log_error "Loki server URL must be specified"
        echo "Use -l parameter, example: $0 -l http://your-loki-server:3100"
        exit 1
    fi
    
    log_info "Loki server URL: $LOKI_URL"
}

# Detect operating system
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
        log_info "Detected system: $OS $VERSION"
        
        case $ID in
            ubuntu|debian)
                PKG_MANAGER="apt"
                ;;
            centos|rhel|rocky|almalinux)
                PKG_MANAGER="yum"
                ;;
            fedora)
                PKG_MANAGER="dnf"
                ;;
            *)
                log_warn "Untested system: $ID"
                PKG_MANAGER="apt"
                ;;
        esac
    else
        log_error "Cannot detect system type"
        exit 1
    fi
}

# Detect architecture
detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            PROMTAIL_ARCH="amd64"
            ;;
        aarch64|arm64)
            PROMTAIL_ARCH="arm64"
            ;;
        armv7l)
            PROMTAIL_ARCH="arm"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    log_info "Detected architecture: $ARCH -> $PROMTAIL_ARCH"
}

# Install system dependencies
install_dependencies() {
    log_step "Installing system dependencies..."
    
    case $PKG_MANAGER in
        apt)
            apt update
            apt install -y curl wget unzip systemd
            ;;
        yum)
            yum update -y
            yum install -y curl wget unzip systemd
            ;;
        dnf)
            dnf update -y
            dnf install -y curl wget unzip systemd
            ;;
    esac
    
    log_info "Dependencies installation completed"
}

# Create user and directories
create_user_and_dirs() {
    log_step "Creating user and directories..."
    
    # Create user
    if ! id "$PROMTAIL_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false $PROMTAIL_USER
        log_info "Created user: $PROMTAIL_USER"
    else
        log_info "User already exists: $PROMTAIL_USER"
    fi
    
    # Create directories
    mkdir -p $INSTALL_DIR $CONFIG_DIR $DATA_DIR $LOG_DIR
    chown -R $PROMTAIL_USER:$PROMTAIL_GROUP $INSTALL_DIR $DATA_DIR $LOG_DIR
    chmod 755 $CONFIG_DIR
    
    log_info "Directory creation completed"
}

# Download and install Promtail
download_promtail() {
    log_step "Downloading Promtail $PROMTAIL_VERSION..."
    
    cd /tmp
    
    DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${PROMTAIL_ARCH}.zip"
    
    log_info "Download URL: $DOWNLOAD_URL"
    
    # Download file
    if ! wget -q --show-progress "$DOWNLOAD_URL" -O promtail.zip; then
        log_error "Download failed, please check network connection and version"
        exit 1
    fi
    
    # Extract and install
    unzip -q promtail.zip
    mv promtail-linux-${PROMTAIL_ARCH} $INSTALL_DIR/promtail
    chmod +x $INSTALL_DIR/promtail
    chown $PROMTAIL_USER:$PROMTAIL_GROUP $INSTALL_DIR/promtail
    
    # Create symbolic link
    ln -sf $INSTALL_DIR/promtail /usr/local/bin/promtail
    
    # Cleanup temporary files
    rm -f promtail.zip promtail-linux-${PROMTAIL_ARCH}
    
    log_info "Promtail installation completed"
    
    # Verify installation
    $INSTALL_DIR/promtail --version
}

# Generate configuration file
generate_config() {
    log_step "Generating configuration file..."
    
    # Basic configuration
    if [[ $LOW_RESOURCE == true ]]; then
        generate_low_resource_config
    else
        generate_standard_config
    fi
    
    log_info "Configuration file generated: $CONFIG_DIR/config.yml"
}

# Standard configuration
generate_standard_config() {
    cat > $CONFIG_DIR/config.yml << EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: info

positions:
  filename: $DATA_DIR/positions.yaml

clients:
  - url: $LOKI_URL/loki/api/v1/push
    # Optional: authentication configuration
    # basic_auth:
    #   username: admin
    #   password: admin

scrape_configs:
  # System logs
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          __path__: /var/log/*.log

  # Application logs example
  - job_name: applications
    static_configs:
      - targets:
          - localhost
        labels:
          job: applications
          __path__: /app/*/app.log
    pipeline_stages:
      - regex:
          expression: '/app/(?P<service>[^/]+)/app\.log'
      - labels:
          service:

  # Nginx logs
  - job_name: nginx
    static_configs:
      - targets:
          - localhost
        labels:
          job: nginx
          __path__: /var/log/nginx/*.log

limits_config:
  readline_rate: 10000
  readline_burst: 20000
EOF
}

# Low-resource VM optimization configuration
# Optimized for resource-constrained Linux VM environments:
# 1. CPU optimization: Reduce log reading rate, lower CPU usage
# 2. Memory optimization: Increase batch size, reduce memory fragmentation 
# 3. I/O optimization: Reduce file scanning frequency, lower disk I/O
# 4. Network optimization: Increase batch wait time, reduce network requests
# 5. Storage optimization: Collect only critical logs, reduce storage pressure
# Suitable for: VPS with <1 core 1GB, test environments, development environments
generate_low_resource_config() {
    cat > $CONFIG_DIR/config.yml << EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0
  log_level: warn  # Reduce log output

positions:
  filename: $DATA_DIR/positions.yaml
  sync_period: 30s  # Reduce sync frequency

clients:
  - url: $LOKI_URL/loki/api/v1/push
    batch_wait: 5s    # Increase batch wait time
    batch_size: 102400 # 1MB batch size

scrape_configs:
  # Critical system logs only
  - job_name: critical-logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: critical
          __path__: |
            /var/log/syslog
            /var/log/auth.log
            /var/log/kern.log

  # Application logs (limited scan frequency)
  - job_name: apps
    static_configs:
      - targets:
          - localhost
        labels:
          job: apps
          __path__: /app/*/app.log
    # Reduce scan frequency to save resources
    scan_frequency: 30s

# Resource limit configuration
limits_config:
  readline_rate: 1000    # Lower read rate
  readline_burst: 2000   # Lower burst read
EOF
}

# Create systemd service
create_systemd_service() {
    log_step "Creating systemd service..."
    
    cat > /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail service
Documentation=https://grafana.com/docs/loki/latest/clients/promtail/
After=network.target

[Service]
Type=simple
User=$PROMTAIL_USER
Group=$PROMTAIL_GROUP
ExecStart=$INSTALL_DIR/promtail -config.file=$CONFIG_DIR/config.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

# Security configuration
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA_DIR $LOG_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable promtail
    
    log_info "Systemd service creation completed"
}

# Setup log rotation
setup_logrotate() {
    log_step "Configuring log rotation..."
    
    cat > /etc/logrotate.d/promtail << EOF
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 $PROMTAIL_USER $PROMTAIL_GROUP
    postrotate
        systemctl reload promtail 2>/dev/null || true
    endscript
}
EOF
    
    log_info "Log rotation configuration completed"
}

# Start service
start_service() {
    log_step "Starting Promtail service..."
    
    systemctl start promtail
    sleep 3
    
    if systemctl is-active --quiet promtail; then
        log_info "✅ Promtail service started successfully"
        systemctl status promtail --no-pager -l
    else
        log_error "❌ Promtail service failed to start"
        echo "Check logs: journalctl -u promtail -f"
        exit 1
    fi
}

# Show installation summary
show_summary() {
    log_step "Installation Summary"
    
    echo
    echo "===========================================" 
    echo "🎉 Promtail Installation Completed!"
    echo "==========================================="
    echo "Version: $PROMTAIL_VERSION"
    echo "Architecture: $PROMTAIL_ARCH"
    echo "Install directory: $INSTALL_DIR"
    echo "Configuration file: $CONFIG_DIR/config.yml"
    echo "Data directory: $DATA_DIR"
    echo "Log directory: $LOG_DIR"
    echo "Loki URL: $LOKI_URL"
    echo "Web interface: http://localhost:9080"
    echo
    echo "Common Commands:"
    echo "  Start service: systemctl start promtail"
    echo "  Stop service: systemctl stop promtail"
    echo "  Restart service: systemctl restart promtail"
    echo "  Check status: systemctl status promtail"
    echo "  View logs: journalctl -u promtail -f"
    echo "  Test config: promtail -config.file=$CONFIG_DIR/config.yml -dry-run"
    echo
    if [[ $LOW_RESOURCE == true ]]; then
        echo "✨ Low-resource VM optimization mode enabled"
        echo "   - Reduced resource usage"
        echo "   - Lower scan frequency"
        echo "   - Optimized batch processing"
        echo "   - Suitable for <1 core 1GB environments"
    fi
    echo "==========================================="
}

# Main function
main() {
    echo "🚀 Promtail Automatic Installation Script Started"
    
    parse_args "$@"
    check_root
    check_loki_url
    detect_system
    detect_arch
    install_dependencies
    create_user_and_dirs
    download_promtail
    generate_config
    create_systemd_service
    setup_logrotate
    start_service
    show_summary
    
    log_info "🎉 Installation completed! Please modify configuration file as needed: $CONFIG_DIR/config.yml"
}

# Script entry point
main "$@"