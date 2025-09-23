#!/bin/bash

# MySQL Exporter One-Click Installation Script
# Compatible with RedHat/CentOS/Rocky/AlmaLinux and Debian/Ubuntu series (last 8 years)
# Author: Auto-generated Script
# Version: 1.0

set -e

# Default configuration
DEFAULT_EXPORTER_VERSION="0.15.1"
DEFAULT_LISTEN_ADDRESS="0.0.0.0:9104"
DEFAULT_CONFIG_FILE="/etc/mysql_exporter/.my.cnf"
DEFAULT_USER="mysql_exporter"
DEFAULT_MYSQL_USER="mon"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    cat << EOF
MySQL Exporter Installation Script

USAGE:
    $0 [ACTION] [OPTIONS]

ACTIONS:
    install                      Install MySQL Exporter (default action)
    uninstall                    Uninstall MySQL Exporter completely
    --help                       Show this help message

OPTIONS (for install action):
    -h, --host HOST              MySQL host (default: localhost)
    -P, --port PORT              MySQL port (default: 3306)  
    -u, --user USER              MySQL username (required for install)
    -p, --password PASSWORD      MySQL password (required for install)
    -m, --mysql-user USER        MySQL monitoring username for exporter (default: $DEFAULT_MYSQL_USER)
    -d, --database DATABASE      MySQL database to monitor (default: mysql)
    -v, --version VERSION        MySQL Exporter version (default: $DEFAULT_EXPORTER_VERSION)
    -l, --listen ADDRESS         Listen address (default: $DEFAULT_LISTEN_ADDRESS)

EXAMPLES:
    # Basic installation
    $0 install -u monitoring_user -p password123

    # Custom configuration with specific MySQL monitoring user
    $0 install -h 192.168.1.100 -P 3307 -u monitor -p secret123 -m exporter_user -v 0.14.0

    # Remote database with custom listen address
    $0 install -h db.example.com -u exporter -p mypass -l 0.0.0.0:9105

    # Uninstall MySQL Exporter
    $0 uninstall

    # Show help
    $0 --help

REQUIREMENTS:
    - Root privileges or sudo access
    - MySQL/MariaDB server accessible with provided credentials (for install)
    - Internet connection for downloading binaries (for install)

SUPPORTED SYSTEMS:
    - RedHat/CentOS/Rocky/AlmaLinux 7, 8, 9
    - Debian 9, 10, 11, 12
    - Ubuntu 16.04, 18.04, 20.04, 22.04, 24.04

UNINSTALL NOTES:
    The uninstall action will:
    - Stop and disable the MySQL Exporter service
    - Remove the systemd service file
    - Remove the binary from /usr/local/bin/
    - Remove the configuration directory /etc/mysql_exporter/
    - Remove the system user mysql_exporter
    - Clean up all related files and directories

EOF
}

# Function to detect OS
detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS_FAMILY="redhat"
        if grep -q "CentOS" /etc/redhat-release; then
            OS_NAME="centos"
        elif grep -q "Rocky" /etc/redhat-release; then
            OS_NAME="rocky"
        elif grep -q "AlmaLinux" /etc/redhat-release; then
            OS_NAME="almalinux"
        elif grep -q "Red Hat" /etc/redhat-release; then
            OS_NAME="rhel"
        fi
        OS_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
    elif [ -f /etc/debian_version ]; then
        OS_FAMILY="debian"
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS_NAME=$ID
            OS_VERSION=$VERSION_ID
        fi
    else
        print_error "Unsupported operating system"
        exit 1
    fi
    
    print_info "Detected OS: $OS_NAME $OS_VERSION"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Function to install dependencies
install_dependencies() {
    print_info "Installing dependencies..."
    
    if [ "$OS_FAMILY" = "redhat" ]; then
        if [ "$OS_VERSION" -ge 8 ]; then
            dnf install -y wget curl tar systemd > /dev/null 2>&1
        else
            yum install -y wget curl tar systemd > /dev/null 2>&1
        fi
    elif [ "$OS_FAMILY" = "debian" ]; then
        apt-get update > /dev/null 2>&1
        apt-get install -y wget curl tar systemd > /dev/null 2>&1
    fi
    
    print_success "Dependencies installed successfully"
}

# Function to create system user
create_user() {
    if ! id "$DEFAULT_USER" &>/dev/null; then
        print_info "Creating system user: $DEFAULT_USER"
        useradd --no-create-home --shell /bin/false $DEFAULT_USER
        print_success "User $DEFAULT_USER created"
    else
        print_info "User $DEFAULT_USER already exists"
    fi
}

# Function to download and install MySQL Exporter
install_mysql_exporter() {
    local version=$1
    local arch=$(uname -m)
    
    # Convert architecture naming
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) 
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    
    local download_url="https://github.com/prometheus/mysqld_exporter/releases/download/v${version}/mysqld_exporter-${version}.linux-${arch}.tar.gz"
    local temp_dir=$(mktemp -d)
    
    print_info "Downloading MySQL Exporter v${version} for ${arch}..."
    
    cd $temp_dir
    if ! wget -q "$download_url"; then
        print_error "Failed to download MySQL Exporter"
        rm -rf $temp_dir
        exit 1
    fi
    
    print_info "Extracting and installing MySQL Exporter..."
    tar -xzf mysqld_exporter-${version}.linux-${arch}.tar.gz
    
    # Install binary
    cp mysqld_exporter-${version}.linux-${arch}/mysqld_exporter /usr/local/bin/
    chmod +x /usr/local/bin/mysqld_exporter
    chown $DEFAULT_USER:$DEFAULT_USER /usr/local/bin/mysqld_exporter
    
    # Clean up
    cd /
    rm -rf $temp_dir
    
    print_success "MySQL Exporter installed successfully"
}

# Function to create configuration
create_config() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local database=$5
    local mysql_user=$6
    
    print_info "Creating configuration file..."
    
    # Create config directory
    mkdir -p /etc/mysql_exporter
    
    # Create MySQL configuration file
    cat > $DEFAULT_CONFIG_FILE << EOF
[client]
host=${host}
port=${port}
user=${user}
password=${password}
EOF
    
    # Set proper permissions
    chmod 600 $DEFAULT_CONFIG_FILE
    chown $DEFAULT_USER:$DEFAULT_USER $DEFAULT_CONFIG_FILE
    chown -R $DEFAULT_USER:$DEFAULT_USER /etc/mysql_exporter
    
    print_success "Configuration file created at $DEFAULT_CONFIG_FILE"
}

# Function to create systemd service
create_systemd_service() {
    local listen_address=$1
    
    print_info "Creating systemd service..."
    
    cat > /etc/systemd/system/mysql_exporter.service << EOF
[Unit]
Description=MySQL Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$DEFAULT_USER
Group=$DEFAULT_USER
Type=simple
ExecStart=/usr/local/bin/mysqld_exporter \\
  --config.my-cnf=$DEFAULT_CONFIG_FILE \\
  --web.listen-address=$listen_address \\
  --collect.info_schema.processlist \\
  --collect.info_schema.innodb_tablespaces \\
  --collect.info_schema.innodb_metrics \\
  --collect.perf_schema.tableiowaits \\
  --collect.perf_schema.indexiowaits \\
  --collect.perf_schema.tablelocks

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable mysql_exporter.service
    
    print_success "Systemd service created and enabled"
}

# Function to test MySQL connection
test_mysql_connection() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    
    print_info "Testing MySQL connection..."
    
    if command -v mysql &> /dev/null; then
        if mysql -h "$host" -P "$port" -u "$user" -p"$password" -e "SELECT 1;" &> /dev/null; then
            print_success "MySQL connection test passed"
            return 0
        else
            print_error "MySQL connection test failed"
            print_error "Please verify your MySQL credentials and connectivity"
            return 1
        fi
    else
        print_warning "MySQL client not found, skipping connection test"
        print_warning "Please manually verify your MySQL credentials"
        return 0
    fi
}

# Function to start and check service
start_service() {
    print_info "Starting MySQL Exporter service..."
    
    systemctl start mysql_exporter.service
    sleep 3
    
    if systemctl is-active --quiet mysql_exporter.service; then
        print_success "MySQL Exporter service started successfully"
        
        # Show service status
        print_info "Service status:"
        systemctl status mysql_exporter.service --no-pager -l
        
        return 0
    else
        print_error "Failed to start MySQL Exporter service"
        print_error "Service logs:"
        journalctl -u mysql_exporter.service --no-pager -l
        return 1
    fi
}

# Function to show final information
show_final_info() {
    local listen_address=$1
    
    cat << EOF

${GREEN}===============================================${NC}
${GREEN}    MySQL Exporter Installation Complete!${NC}
${GREEN}===============================================${NC}

Service Information:
  - Service Name: mysql_exporter.service  
  - Listen Address: $listen_address
  - Config File: $DEFAULT_CONFIG_FILE
  - Binary Location: /usr/local/bin/mysqld_exporter

Service Management:
  Start:   systemctl start mysql_exporter.service
  Stop:    systemctl stop mysql_exporter.service  
  Restart: systemctl restart mysql_exporter.service
  Status:  systemctl status mysql_exporter.service
  Logs:    journalctl -u mysql_exporter.service -f

Testing:
  curl http://localhost:$(echo $listen_address | cut -d':' -f2)/metrics

Prometheus Configuration:
  - job_name: 'mysql-exporter'
    static_configs:
      - targets: ['$listen_address']

Uninstall:
  $0 uninstall

${YELLOW}Note: Make sure port $(echo $listen_address | cut -d':' -f2) is accessible from your Prometheus server${NC}

EOF
}

# Function to uninstall MySQL Exporter
uninstall_mysql_exporter() {
    print_info "Starting MySQL Exporter uninstallation..."
    
    # Stop and disable service
    if systemctl is-active --quiet mysql_exporter.service 2>/dev/null; then
        print_info "Stopping MySQL Exporter service..."
        systemctl stop mysql_exporter.service
        print_success "Service stopped"
    fi
    
    if systemctl is-enabled --quiet mysql_exporter.service 2>/dev/null; then
        print_info "Disabling MySQL Exporter service..."
        systemctl disable mysql_exporter.service
        print_success "Service disabled"
    fi
    
    # Remove systemd service file
    if [ -f /etc/systemd/system/mysql_exporter.service ]; then
        print_info "Removing systemd service file..."
        rm -f /etc/systemd/system/mysql_exporter.service
        systemctl daemon-reload
        print_success "Systemd service file removed"
    fi
    
    # Remove binary
    if [ -f /usr/local/bin/mysqld_exporter ]; then
        print_info "Removing MySQL Exporter binary..."
        rm -f /usr/local/bin/mysqld_exporter
        print_success "Binary removed"
    fi
    
    # Remove configuration directory
    if [ -d /etc/mysql_exporter ]; then
        print_info "Removing configuration directory..."
        rm -rf /etc/mysql_exporter
        print_success "Configuration directory removed"
    fi
    
    # Remove system user
    if id "$DEFAULT_USER" &>/dev/null; then
        print_info "Removing system user: $DEFAULT_USER"
        userdel "$DEFAULT_USER" 2>/dev/null || true
        print_success "System user removed"
    fi
    
    print_success "MySQL Exporter uninstallation completed successfully!"
    
    cat << EOF

${GREEN}===============================================${NC}
${GREEN}    MySQL Exporter Uninstall Complete!${NC}
${GREEN}===============================================${NC}

The following items have been removed:
  - MySQL Exporter service (stopped and disabled)
  - Systemd service file: /etc/systemd/system/mysql_exporter.service
  - Binary file: /usr/local/bin/mysqld_exporter
  - Configuration directory: /etc/mysql_exporter/
  - System user: $DEFAULT_USER

${YELLOW}Note: MySQL server and data remain untouched${NC}

EOF
}

# Main function
main() {
    # Check for action parameter
    ACTION="install"
    if [[ $# -gt 0 ]]; then
        case $1 in
            install)
                ACTION="install"
                shift
                ;;
            uninstall)
                ACTION="uninstall"
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            -*)
                # If first argument starts with -, assume it's install with options
                ACTION="install"
                ;;
            *)
                print_error "Unknown action: $1"
                show_usage
                exit 1
                ;;
        esac
    fi
    
    # Handle uninstall action
    if [ "$ACTION" = "uninstall" ]; then
        check_root
        uninstall_mysql_exporter
        exit 0
    fi
    
    # Default values for install action
    MYSQL_HOST="localhost"
    MYSQL_PORT="3306"
    MYSQL_USER=""
    MYSQL_PASSWORD=""
    MYSQL_MONITOR_USER="$DEFAULT_MYSQL_USER"
    MYSQL_DATABASE="mysql"
    EXPORTER_VERSION="$DEFAULT_EXPORTER_VERSION"
    LISTEN_ADDRESS="$DEFAULT_LISTEN_ADDRESS"
    
    # Parse command line arguments for install action
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--host)
                MYSQL_HOST="$2"
                shift 2
                ;;
            -P|--port)
                MYSQL_PORT="$2"
                shift 2
                ;;
            -u|--user)
                MYSQL_USER="$2"
                shift 2
                ;;
            -p|--password)
                MYSQL_PASSWORD="$2"
                shift 2
                ;;
            -m|--mysql-user)
                MYSQL_MONITOR_USER="$2"
                shift 2
                ;;
            -d|--database)
                MYSQL_DATABASE="$2"
                shift 2
                ;;
            -v|--version)
                EXPORTER_VERSION="$2"
                shift 2
                ;;
            -l|--listen)
                LISTEN_ADDRESS="$2"
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters for install
    if [[ -z "$MYSQL_USER" || -z "$MYSQL_PASSWORD" ]]; then
        print_error "MySQL username and password are required for installation"
        show_usage
        exit 1
    fi
    
    print_info "Starting MySQL Exporter installation..."
    print_info "MySQL Host: $MYSQL_HOST:$MYSQL_PORT"
    print_info "MySQL User: $MYSQL_USER"
    print_info "MySQL Monitor User: $MYSQL_MONITOR_USER"
    print_info "Exporter Version: $EXPORTER_VERSION"
    print_info "Listen Address: $LISTEN_ADDRESS"
    
    # Execute installation steps
    check_root
    detect_os
    install_dependencies
    create_user
    install_mysql_exporter "$EXPORTER_VERSION"
    create_config "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD" "$MYSQL_DATABASE" "$MYSQL_MONITOR_USER"
    create_systemd_service "$LISTEN_ADDRESS" "$MYSQL_MONITOR_USER"
    
    # Test MySQL connection (optional)
    test_mysql_connection "$MYSQL_HOST" "$MYSQL_PORT" "$MYSQL_USER" "$MYSQL_PASSWORD"
    
    # Start service
    if start_service; then
        show_final_info "$LISTEN_ADDRESS"
        exit 0
    else
        print_error "Installation completed but service failed to start"
        print_error "Please check the logs and configuration"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"