#!/bin/bash

# Network Exporter Installation Script
# Supports RedHat series (RHEL, CentOS, Fedora) and Debian series (Ubuntu, Debian)
# Author: Auto-generated script
# Version: 1.0

set -e  # Exit on any error

# Default configuration
NETWORK_EXPORTER_VERSION="1.6.1"
NETWORK_EXPORTER_USER="network_exporter"
NETWORK_EXPORTER_PORT="9427"
INSTALL_DIR="/opt/network_exporter"
SERVICE_FILE="/etc/systemd/system/network_exporter.service"
CONFIG_FILE="/etc/network_exporter/config.yml"
CONFIG_SOURCE="network_exporter.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Network Exporter Installation Script for Linux

OPTIONS:
    -h, --help              Show this help message
    -v, --version VERSION   Specify network exporter version (default: ${NETWORK_EXPORTER_VERSION})
    -p, --port PORT         Specify port number (default: ${NETWORK_EXPORTER_PORT})
    -u, --user USER         Specify service user (default: ${NETWORK_EXPORTER_USER})
    -d, --directory DIR     Specify installation directory (default: ${INSTALL_DIR})
    --uninstall            Uninstall network exporter
    --dry-run              Show what would be done without executing

EXAMPLES:
    $0                                          # Install with defaults
    $0 -v 1.5.0 -p 9428                       # Install specific version on custom port
    $0 --uninstall                             # Uninstall network exporter
    $0 --dry-run                               # Preview installation steps

SUPPORTED DISTRIBUTIONS:
    - RedHat series: RHEL, CentOS, Fedora, Rocky Linux, AlmaLinux
    - Debian series: Ubuntu, Debian, Linux Mint

EOF
}

# Print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/redhat-release ]]; then
        DISTRO="redhat"
        if command -v dnf &> /dev/null; then
            PKG_MANAGER="dnf"
        else
            PKG_MANAGER="yum"
        fi
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        PKG_MANAGER="apt"
    else
        print_error "Unsupported distribution. This script supports RedHat and Debian series only."
        exit 1
    fi
    
    print_info "Detected distribution: $DISTRO (Package manager: $PKG_MANAGER)"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install required packages
install_dependencies() {
    print_info "Installing required dependencies..."
    
    case $DISTRO in
        "redhat")
            $PKG_MANAGER install -y wget curl tar systemd
            ;;
        "debian")
            apt update
            apt install -y wget curl tar systemd
            ;;
    esac
}

# Create service user
create_user() {
    if id "$NETWORK_EXPORTER_USER" &>/dev/null; then
        print_info "User $NETWORK_EXPORTER_USER already exists"
    else
        print_info "Creating service user: $NETWORK_EXPORTER_USER"
        if [[ "$DRY_RUN" == "false" ]]; then
            useradd --system --no-create-home --shell /bin/false $NETWORK_EXPORTER_USER
        fi
    fi
}

# Download and install network exporter
download_and_install() {
    print_info "Downloading network exporter version $NETWORK_EXPORTER_VERSION..."
    
    # Determine architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="x86_64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armv7"
            ;;
        *)
            print_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    DOWNLOAD_URL="https://github.com/syepes/network_exporter/releases/download/${NETWORK_EXPORTER_VERSION}/network_exporter_${NETWORK_EXPORTER_VERSION}.Linux_${ARCH}.tar.gz"
    TEMP_DIR=$(mktemp -d)
    
    if [[ "$DRY_RUN" == "false" ]]; then
        cd "$TEMP_DIR"
        wget "$DOWNLOAD_URL" -O network_exporter.tar.gz
        tar -xzf network_exporter.tar.gz
        
        # Create installation directory
        mkdir -p "$INSTALL_DIR"
        mkdir -p "$(dirname $CONFIG_FILE)"
        
        # Copy binary
        cp network_exporter "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/network_exporter"
        chown -R $NETWORK_EXPORTER_USER:$NETWORK_EXPORTER_USER "$INSTALL_DIR"
        
        # Cleanup
        rm -rf "$TEMP_DIR"
    else
        print_info "Would download from: $DOWNLOAD_URL"
        print_info "Would install to: $INSTALL_DIR"
    fi
}

# Create configuration file
create_config() {
    print_info "Creating configuration file: $CONFIG_FILE"
    if [[ -f "$CONFIG_SOURCE" ]]; then
        print_info "Found existing network_exporter.yml in release, copying it..."
        cp "$CONFIG_SOURCE" "$CONFIG_FILE"
    else
        if [[ "$DRY_RUN" == "false" ]]; then
            cat > "$CONFIG_FILE" << EOF
# Network Exporter Configuration
# Listen address and port
listen_address: "0.0.0.0:${NETWORK_EXPORTER_PORT}"

# Timeout settings
timeout: 5s

# Log level (debug, info, warn, error)
log_level: info

# Targets configuration
targets:
  - name: "google_dns"
    host: "8.8.8.8"
    port: 53
    protocol: "tcp"
  - name: "cloudflare_dns"
    host: "1.1.1.1"
    port: 53
    protocol: "udp"
EOF
            chown $NETWORK_EXPORTER_USER:$NETWORK_EXPORTER_USER "$CONFIG_FILE"
        else
            print_info "Would create config file: $CONFIG_FILE"
        fi
    fi
}

# Create systemd service
create_service() {
    print_info "Creating systemd service: $SERVICE_FILE"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Network Exporter
Documentation=https://github.com/syepes/network_exporter
After=network.target

[Service]
Type=simple
User=$NETWORK_EXPORTER_USER
Group=$NETWORK_EXPORTER_USER
ExecStart=$INSTALL_DIR/network_exporter --config.file=$CONFIG_FILE
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=network_exporter
KillMode=mixed
KillSignal=SIGTERM
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN
NoNewPrivileges=false

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable network_exporter
    else
        print_info "Would create systemd service: $SERVICE_FILE"
        print_info "Would enable and start service"
    fi
}

# Start service
start_service() {
    print_info "Starting network exporter service..."
    
    if [[ "$DRY_RUN" == "false" ]]; then
        systemctl start network_exporter
        
        # Wait a moment for service to start
        sleep 2
        
        if systemctl is-active --quiet network_exporter; then
            print_info "Network exporter started successfully on port $NETWORK_EXPORTER_PORT"
            print_info "Metrics available at: http://localhost:$NETWORK_EXPORTER_PORT/metrics"
        else
            print_error "Failed to start network exporter service"
            systemctl status network_exporter
            exit 1
        fi
    else
        print_info "Would start network_exporter service"
    fi
}

# Uninstall network exporter
uninstall() {
    print_info "Uninstalling network exporter..."
    
    # Stop and disable service
    if systemctl is-active --quiet network_exporter 2>/dev/null; then
        systemctl stop network_exporter
    fi
    
    if systemctl is-enabled --quiet network_exporter 2>/dev/null; then
        systemctl disable network_exporter
    fi
    
    # Remove files
    rm -f "$SERVICE_FILE"
    rm -rf "$INSTALL_DIR"
    rm -rf "$(dirname $CONFIG_FILE)"
    
    # Remove user
    if id "$NETWORK_EXPORTER_USER" &>/dev/null; then
        userdel "$NETWORK_EXPORTER_USER"
    fi
    
    systemctl daemon-reload
    
    print_info "Network exporter uninstalled successfully"
}

# Main installation function
main() {
    print_info "Starting network exporter installation..."
    
    detect_distro
    check_root
    install_dependencies
    create_user
    download_and_install
    create_config
    create_service
    start_service
    
    print_info "Installation completed successfully!"
    echo
    echo "Service Status:"
    systemctl status network_exporter --no-pager -l
    echo
    echo "To view logs: journalctl -u network_exporter -f"
    echo "Configuration file: $CONFIG_FILE"
    echo "Metrics endpoint: http://localhost:$NETWORK_EXPORTER_PORT/metrics"
}

# Parse command line arguments
DRY_RUN="false"
UNINSTALL="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--version)
            NETWORK_EXPORTER_VERSION="$2"
            shift 2
            ;;
        -p|--port)
            NETWORK_EXPORTER_PORT="$2"
            shift 2
            ;;
        -u|--user)
            NETWORK_EXPORTER_USER="$2"
            shift 2
            ;;
        -d|--directory)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Execute main function or uninstall
if [[ "$UNINSTALL" == "true" ]]; then
    check_root
    uninstall
else
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "DRY RUN MODE - No actual changes will be made"
        echo
    fi
    main
fi