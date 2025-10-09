#!/bin/bash

# MongoDB Replica Set Installation Script with Prometheus Exporter and Authentication
# Supports Debian and CentOS-based systems, Prometheus exporter, systemd management
# Modified to support three instances on a single host or single instance per host or standalone mode

set -e

# Default values
MONGODB_VERSION="5.0"
DATA_DIR=""
ROLE=""
REPLICA_SET_NAME="rs0"
PRIMARY_PORT=27017
SECONDARY_PORT=27018
ARBITER_PORT=27019
CONFIG_FILE="/etc/mongod.conf"
SERVICE_FILE="/etc/systemd/system/mongod.service"
PROMETHEUS_EXPORTER_PORT=9216
PROMETHEUS_EXPORTER_VERSION="0.44.0"
MONGODB_USER="mongo"
MONGO_ADMIN_USER="admin"
MONGO_ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9')"
MONGO_MON_USER="exporter"
MONGO_MON_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9')"
PRIMARY_IP="127.0.0.1"  # Default to localhost for single host
SECONDARY_IP="127.0.0.1"
ARBITER_IP="127.0.0.1"
PID_DIR="/var/run/mongodb"
PID_FILE="$PID_DIR/mongod.pid"
MULTI_INSTANCE=false  # New flag to enable multi-instance on single host
INSTANCE_NAME=""      # Instance-specific name for multi-instance mode
STANDALONE=false      # New flag for standalone mode (no replica set)
STANDALONE_PORT=27017 # Default port for standalone mode
EXPORTER_INSTALL_DIR="/usr/share/mongodb_exporter"
EXPORTER_TEMP_DIR="/tmp/mongodb_exporter"

usage() {
    echo "Usage: $0 <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  install        Install MongoDB and Prometheus exporter"
    echo "  init-replica   Initialize MongoDB replica set"
    echo "  config-auth    Configure replica set authentication"
    echo "  exporter       Manage Prometheus exporter (install|uninstall|upgrade)"
    echo ""
    echo "install options:"
    echo "  --data-dir <path>                   Data directory path"
    echo "  --mongodb-version <version>         MongoDB version (default: $MONGODB_VERSION)"
    echo "  --multi-instance                    Enable multi-instance mode on single host"
    echo "  --standalone                        Deploy standalone mode (no replica set)"
    echo "  --port <port>                       Port for standalone mode (default: $STANDALONE_PORT)"
    echo ""
    echo "init-replica, config-auth and install options:"
    echo "  --role <primary|secondary|arbiter>  Specify node role (not needed for standalone)"
    echo "  --data-dir <path>                   Data directory path"
    echo "  --primary-ip <IP>                   Primary node IP (default: $PRIMARY_IP)"
    echo "  --secondary-ip <IP>                 Secondary node IP (default: $SECONDARY_IP)"
    echo "  --arbiter-ip <IP>                   Arbiter node IP (default: $ARBITER_IP)"
    echo ""
    echo "exporter subcommand:"
    echo "  $0 exporter install [--primary-ip <IP>] [--secondary-ip <IP>] [--port <port>]"
    echo "  $0 exporter uninstall"
    echo "  $0 exporter upgrade [--version <version>]"
    echo ""
    echo "Examples:"
    echo "  # Deploy standalone MongoDB"
    echo "  $0 install --standalone --data-dir /data/mongodb"
    echo ""
    echo "  # Deploy replica set primary node"
    echo "  $0 install --role primary --data-dir /data/mongodb --primary-ip 192.168.1.10 --secondary-ip 192.168.1.11 --arbiter-ip 192.168.1.12"
    echo ""
    echo "  # Install MongoDB exporter"
    echo "  $0 exporter install --primary-ip 192.168.1.10 --secondary-ip 192.168.1.11"
    echo ""
    echo "  # Uninstall MongoDB exporter"
    echo "  $0 exporter uninstall"
    echo ""
    echo "  # Upgrade MongoDB exporter"
    echo "  $0 exporter upgrade --version 0.45.0"
    exit 1
}

check_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    else
        echo "Error: Unsupported operating system"
        exit 1
    fi
}

create_mongodb_user() {
    if ! id "$MONGODB_USER" >/dev/null 2>&1; then
        echo "Creating MongoDB user..."
        if [[ "$OS" == "debian" ]]; then
            useradd -r -s /bin/false -M "$MONGODB_USER"
        else
            useradd -r -s /sbin/nologin -M "$MONGODB_USER"
        fi
    fi
}

install_mongodb() {
    echo "Installing MongoDB ${MONGODB_VERSION}..."
    if [[ "$OS" == "debian" ]]; then
        apt-get update
        apt-get install -y gnupg wget
        wget -qO - https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc | apt-key add -
        echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/debian $(lsb_release -sc)/mongodb-org/${MONGODB_VERSION} main" \
            > /etc/apt/sources.list.d/mongodb-org.list
        apt-get update
        apt-get install -y mongodb-org=${MONGODB_VERSION}*
    else
        # Detect system version
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            RHEL_VERSION=${VERSION_ID%%.*}
            OS_NAME=${ID}
        else
            RHEL_VERSION=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
            OS_NAME="rhel"
        fi
        
        echo "System: ${OS_NAME} ${RHEL_VERSION}"
        
        # MongoDB repository path mapping
        # Rocky/Alma 9 and other RHEL 9 use RHEL 8 repository
        REPO_VERSION=$RHEL_VERSION
        if [[ "$RHEL_VERSION" == "9" ]]; then
            if [[ "$MONGODB_VERSION" == "5.0" || "$MONGODB_VERSION" == "6.0" ]]; then
                REPO_VERSION="8"
                echo "Note: MongoDB ${MONGODB_VERSION} uses RHEL 8 compatible repository"
            fi
        fi
        
        # Configure MongoDB repository
        cat > /etc/yum.repos.d/mongodb-org.repo <<EOF
[mongodb-org-${MONGODB_VERSION}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/${REPO_VERSION}/mongodb-org/${MONGODB_VERSION}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc
EOF
        
        echo "Repository configuration: https://repo.mongodb.org/yum/redhat/${REPO_VERSION}/mongodb-org/${MONGODB_VERSION}/x86_64/"
        
        yum clean all
        yum makecache
        
        echo "Starting MongoDB installation..."
        
        INSTALL_SUCCESS=false
        
        # Strategy 1: Try installing main package mongodb-org
        echo "Attempting method 1: installing mongodb-org..."
        if yum install -y mongodb-org mongodb-org-server mongodb-org-mongos mongodb-org-tools 2>/dev/null; then
            INSTALL_SUCCESS=true
            echo "✓ Method 1 successful"
        fi
        
        # Strategy 2: Try packages with specific version
        if [[ "$INSTALL_SUCCESS" == "false" ]]; then
            echo "Attempting method 2: installing packages with version..."
            AVAILABLE_VERSION=$(yum list available mongodb-org-server 2>/dev/null | grep mongodb-org-server | tail -1 | awk '{print $2}')
            if [[ -n "$AVAILABLE_VERSION" ]]; then
                echo "Found version: $AVAILABLE_VERSION"
                if yum install -y mongodb-org-server-${AVAILABLE_VERSION} mongodb-org-mongos-${AVAILABLE_VERSION} mongodb-org-tools-${AVAILABLE_VERSION} 2>/dev/null; then
                    INSTALL_SUCCESS=true
                    echo "✓ Method 2 successful"
                fi
            fi
        fi
        
        # Strategy 3: List all packages and try to install
        if [[ "$INSTALL_SUCCESS" == "false" ]]; then
            echo "Attempting method 3: finding and installing all available MongoDB packages..."
            MONGO_PACKAGES=$(yum list available 2>/dev/null | grep "^mongodb-org" | grep -v "debuginfo\|devel" | awk '{print $1}' | tr '\n' ' ')
            if [[ -n "$MONGO_PACKAGES" ]]; then
                echo "Found packages: $MONGO_PACKAGES"
                if yum install -y $MONGO_PACKAGES 2>/dev/null; then
                    INSTALL_SUCCESS=true
                    echo "✓ Method 3 successful"
                fi
            fi
        fi
        
        if [[ "$INSTALL_SUCCESS" == "false" ]]; then
            echo ""
            echo "❌ Error: All installation methods failed"
            echo ""
            echo "Available MongoDB packages in repository:"
            yum search mongodb-org 2>/dev/null | grep "^mongodb-org"
            echo ""
            echo "Please check:"
            echo "1. Repository URL: https://repo.mongodb.org/yum/redhat/${REPO_VERSION}/mongodb-org/${MONGODB_VERSION}/x86_64/"
            echo "2. Network connection: curl -I https://repo.mongodb.org"
            echo "3. Try manual installation: yum install -y mongodb-org"
            exit 1
        fi
        
        # Install shell client
        echo "Installing MongoDB shell..."
        if yum list available mongodb-mongosh >/dev/null 2>&1; then
            yum install -y mongodb-mongosh 2>/dev/null || yum install -y mongodb-org-shell 2>/dev/null || echo "Note: shell client installation failed"
        else
            yum install -y mongodb-org-shell 2>/dev/null || echo "Note: shell client installation failed"
        fi
    fi
    
    # Verify installation
    if ! command -v mongod >/dev/null 2>&1; then
        echo "❌ Error: mongod installation failed"
        exit 1
    fi
    
    echo "✓ MongoDB installation successful"
    mongod --version | head -1
    
    if command -v mongosh >/dev/null 2>&1; then
        echo "✓ Shell: mongosh"
    elif command -v mongo >/dev/null 2>&1; then
        echo "✓ Shell: mongo"
    fi
}

check_exporter_installed() {
    local installed=false
    local checks_passed=0
    local total_checks=5
    
    echo "Checking if MongoDB exporter is already installed..."
    
    # Check 1: Binary exists
    if [[ -f "$EXPORTER_INSTALL_DIR/mongodb_exporter" ]]; then
        echo "  ✓ Binary found at $EXPORTER_INSTALL_DIR/mongodb_exporter"
        ((checks_passed++))
    else
        echo "  ✗ Binary not found at $EXPORTER_INSTALL_DIR/mongodb_exporter"
    fi
    
    # Check 2: Binary is executable
    if [[ -x "$EXPORTER_INSTALL_DIR/mongodb_exporter" ]]; then
        echo "  ✓ Binary is executable"
        ((checks_passed++))
    else
        echo "  ✗ Binary is not executable"
    fi
    
    # Check 3: Service file exists
    local service_exists=false
    if [[ -f "/etc/systemd/system/mongodb-exporter.service" ]]; then
        echo "  ✓ Service file found: mongodb-exporter.service"
        ((checks_passed++))
        service_exists=true
    elif ls /etc/systemd/system/mongodb-exporter*.service >/dev/null 2>&1; then
        echo "  ✓ Service file(s) found: $(ls /etc/systemd/system/mongodb-exporter*.service | xargs basename -a | tr '\n' ' ')"
        ((checks_passed++))
        service_exists=true
    else
        echo "  ✗ Service file not found"
    fi
    
    # Check 4: Service is enabled
    if [[ "$service_exists" == "true" ]]; then
        if systemctl is-enabled mongodb-exporter >/dev/null 2>&1 || systemctl is-enabled mongodb-exporter-* >/dev/null 2>&1; then
            echo "  ✓ Service is enabled"
            ((checks_passed++))
        else
            echo "  ✗ Service is not enabled"
        fi
    fi
    
    # Check 5: Process is running
    if pgrep -f "mongodb_exporter" >/dev/null; then
        echo "  ✓ Exporter process is running"
        ((checks_passed++))
        local pid=$(pgrep -f "mongodb_exporter")
        local port=$(netstat -tlnp 2>/dev/null | grep "$pid" | awk '{print $4}' | grep -o '[0-9]*$' | head -1)
        if [[ -n "$port" ]]; then
            echo "    Running on port: $port"
        fi
    else
        echo "  ✗ Exporter process is not running"
    fi
    
    # Check version if binary exists
    if [[ -x "$EXPORTER_INSTALL_DIR/mongodb_exporter" ]]; then
        local version=$("$EXPORTER_INSTALL_DIR/mongodb_exporter" --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1)
        if [[ -n "$version" ]]; then
            echo "  Current version: $version"
        fi
    fi
    
    echo ""
    echo "Installation check: $checks_passed/$total_checks checks passed"
    
    if [[ $checks_passed -ge 3 ]]; then
        echo "Result: MongoDB exporter appears to be installed"
        return 0
    else
        echo "Result: MongoDB exporter is not properly installed"
        return 1
    fi
}

install_exporter() {
    local FORCE_INSTALL=false
    
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --primary-ip) PRIMARY_IP="$2"; shift ;;
            --secondary-ip) SECONDARY_IP="$2"; shift ;;
            --port) STANDALONE_PORT="$2"; shift ;;
            --standalone) STANDALONE=true ;;
            --force) FORCE_INSTALL=true ;;
            --version) PROMETHEUS_EXPORTER_VERSION="$2"; shift ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
        shift
    done
    
    # Check if already installed
    if check_exporter_installed; then
        if [[ "$FORCE_INSTALL" == "false" ]]; then
            echo ""
            echo "MongoDB exporter is already installed."
            echo "Use '$0 exporter upgrade' to upgrade or add --force to reinstall"
            return 0
        else
            echo ""
            echo "Force reinstall requested..."
        fi
    fi
    
    # Validate parameters for non-standalone mode
    if [[ "$STANDALONE" == "false" ]]; then
        if [[ -z "$PRIMARY_IP" || -z "$SECONDARY_IP" ]]; then
            echo "Error: exporter install requires --primary-ip and --secondary-ip for replica set mode"
            echo "Or use --standalone --port <port> for standalone mode"
            usage
        fi
    fi

    echo "Installing MongoDB exporter version ${PROMETHEUS_EXPORTER_VERSION}..."
    
    # Clean up old temp directory if exists
    if [[ -d "$EXPORTER_TEMP_DIR" ]]; then
        rm -rf "$EXPORTER_TEMP_DIR"
    fi
    
    mkdir -p "$EXPORTER_TEMP_DIR"
    cd "$EXPORTER_TEMP_DIR"
    
    # Download exporter
    echo "Downloading exporter..."
    if ! wget -q "https://github.com/percona/mongodb_exporter/releases/download/v${PROMETHEUS_EXPORTER_VERSION}/mongodb_exporter-${PROMETHEUS_EXPORTER_VERSION}.linux-amd64.tar.gz"; then
        echo "Error: Failed to download MongoDB exporter version ${PROMETHEUS_EXPORTER_VERSION}"
        echo "Please check if the version exists at: https://github.com/percona/mongodb_exporter/releases"
        rm -rf "$EXPORTER_TEMP_DIR"
        exit 1
    fi
    
    echo "Extracting exporter..."
    tar -xzf "mongodb_exporter-${PROMETHEUS_EXPORTER_VERSION}.linux-amd64.tar.gz" --strip-components=1
    
    # Create install directory if not exists
    if [[ ! -d "$EXPORTER_INSTALL_DIR" ]]; then
        mkdir -p "$EXPORTER_INSTALL_DIR"
    fi
    
    # Copy binary
    echo "Installing binary..."
    cp mongodb_exporter "$EXPORTER_INSTALL_DIR/"
    chmod +x "$EXPORTER_INSTALL_DIR/mongodb_exporter"
    id ${MONGODB_USER} || useradd ${MONGODB_USER} -s /sbin/nologin -M
    chown -R ${MONGODB_USER}:${MONGODB_USER} "$EXPORTER_INSTALL_DIR"
    
    # Clean up temp directory
    cd /
    rm -rf "$EXPORTER_TEMP_DIR"
    
    # Configure and start service
    configure_exporter_systemd
    
    echo ""
    echo "✓ MongoDB exporter installation completed"
    echo "  Version: ${PROMETHEUS_EXPORTER_VERSION}"
    echo "  Binary: $EXPORTER_INSTALL_DIR/mongodb_exporter"
    echo "  Port: $PROMETHEUS_EXPORTER_PORT"
    
    # Show service status
    local service_name="mongodb-exporter"
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        service_name="mongodb-exporter-${INSTANCE_NAME}"
    fi
    
    if systemctl is-active "$service_name" >/dev/null 2>&1; then
        echo "  Status: Running"
    else
        echo "  Status: Failed to start - check logs with: journalctl -u $service_name"
    fi
}

uninstall_exporter() {
    echo "Uninstalling MongoDB exporter..."
    
    # Check if installed
    if ! check_exporter_installed; then
        echo "MongoDB exporter is not installed or already uninstalled"
        return 0
    fi
    
    # Stop and disable all exporter services
    echo "Stopping and disabling services..."
    for service_file in /etc/systemd/system/mongodb-exporter*.service; do
        if [[ -f "$service_file" ]]; then
            local service_name=$(basename "$service_file")
            echo "  Stopping $service_name..."
            systemctl stop "$service_name" 2>/dev/null || true
            systemctl disable "$service_name" 2>/dev/null || true
            rm -f "$service_file"
            echo "  ✓ Removed $service_name"
        fi
    done
    
    # Remove binary and directory
    if [[ -d "$EXPORTER_INSTALL_DIR" ]]; then
        echo "Removing installation directory..."
        rm -rf "$EXPORTER_INSTALL_DIR"
        echo "  ✓ Removed $EXPORTER_INSTALL_DIR"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    echo ""
    echo "✓ MongoDB exporter uninstallation completed"
}

upgrade_exporter() {
    local NEW_VERSION=""
    
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --version) NEW_VERSION="$2"; shift ;;
            --primary-ip) PRIMARY_IP="$2"; shift ;;
            --secondary-ip) SECONDARY_IP="$2"; shift ;;
            --port) STANDALONE_PORT="$2"; shift ;;
            --standalone) STANDALONE=true ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
        shift
    done
    
    # Check if currently installed
    if ! check_exporter_installed; then
        echo ""
        echo "MongoDB exporter is not installed. Please install it first using:"
        echo "  $0 exporter install"
        exit 1
    fi
    
    # Get current version
    local current_version=""
    if [[ -x "$EXPORTER_INSTALL_DIR/mongodb_exporter" ]]; then
        current_version=$("$EXPORTER_INSTALL_DIR/mongodb_exporter" --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1)
    fi
    
    if [[ -z "$NEW_VERSION" ]]; then
        echo "Current version: ${current_version:-unknown}"
        echo "No version specified. Please use --version <version>"
        echo "Example: $0 exporter upgrade --version 0.45.0"
        exit 1
    fi
    
    if [[ "$current_version" == "$NEW_VERSION" ]]; then
        echo "MongoDB exporter is already at version $NEW_VERSION"
        echo "Use --force with install to reinstall"
        return 0
    fi
    
    echo "Upgrading MongoDB exporter from ${current_version:-unknown} to $NEW_VERSION..."
    
    # Stop service before upgrade
    echo "Stopping exporter service..."
    for service_file in /etc/systemd/system/mongodb-exporter*.service; do
        if [[ -f "$service_file" ]]; then
            local service_name=$(basename "$service_file")
            systemctl stop "$service_name" 2>/dev/null || true
        fi
    done
    
    # Backup current binary
    if [[ -f "$EXPORTER_INSTALL_DIR/mongodb_exporter" ]]; then
        cp "$EXPORTER_INSTALL_DIR/mongodb_exporter" "$EXPORTER_INSTALL_DIR/mongodb_exporter.backup"
        echo "Backed up current binary"
    fi
    
    # Install new version
    PROMETHEUS_EXPORTER_VERSION="$NEW_VERSION"
    
    # Clean up temp directory
    if [[ -d "$EXPORTER_TEMP_DIR" ]]; then
        rm -rf "$EXPORTER_TEMP_DIR"
    fi
    
    mkdir -p "$EXPORTER_TEMP_DIR"
    cd "$EXPORTER_TEMP_DIR"
    
    echo "Downloading version $NEW_VERSION..."
    if ! wget -q "https://github.com/percona/mongodb_exporter/releases/download/v${NEW_VERSION}/mongodb_exporter-${NEW_VERSION}.linux-amd64.tar.gz"; then
        echo "Error: Failed to download version $NEW_VERSION"
        if [[ -f "$EXPORTER_INSTALL_DIR/mongodb_exporter.backup" ]]; then
            echo "Restoring backup..."
            mv "$EXPORTER_INSTALL_DIR/mongodb_exporter.backup" "$EXPORTER_INSTALL_DIR/mongodb_exporter"
        fi
        rm -rf "$EXPORTER_TEMP_DIR"
        exit 1
    fi
    
    echo "Extracting..."
    tar -xzf "mongodb_exporter-${NEW_VERSION}.linux-amd64.tar.gz" --strip-components=1
    
    echo "Installing new binary..."
    cp mongodb_exporter "$EXPORTER_INSTALL_DIR/"
    chmod +x "$EXPORTER_INSTALL_DIR/mongodb_exporter"
    chown -R ${MONGODB_USER}:${MONGODB_USER} "$EXPORTER_INSTALL_DIR"
    
    # Clean up
    cd /
    rm -rf "$EXPORTER_TEMP_DIR"
    
    # Remove backup if successful
    if [[ -f "$EXPORTER_INSTALL_DIR/mongodb_exporter.backup" ]]; then
        rm -f "$EXPORTER_INSTALL_DIR/mongodb_exporter.backup"
    fi
    
    # Restart services
    echo "Restarting services..."
    for service_file in /etc/systemd/system/mongodb-exporter*.service; do
        if [[ -f "$service_file" ]]; then
            local service_name=$(basename "$service_file")
            systemctl start "$service_name"
            echo "  ✓ Restarted $service_name"
        fi
    done
    
    echo ""
    echo "✓ MongoDB exporter upgrade completed"
    echo "  Previous version: ${current_version:-unknown}"
    echo "  Current version: $NEW_VERSION"
    
    # Verify new version
    local verified_version=$("$EXPORTER_INSTALL_DIR/mongodb_exporter" --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1)
    if [[ "$verified_version" == "$NEW_VERSION" ]]; then
        echo "  Verification: ✓ Success"
    else
        echo "  Verification: ✗ Version mismatch (got: $verified_version)"
    fi
}

manage_exporter() {
    if [[ $# -lt 1 ]]; then
        echo "Error: exporter subcommand requires an action"
        echo "Usage: $0 exporter <install|uninstall|upgrade> [options]"
        exit 1
    fi
    
    local action=$1
    shift
    
    case $action in
        install)
            install_exporter "$@"
            ;;
        uninstall)
            uninstall_exporter "$@"
            ;;
        upgrade)
            upgrade_exporter "$@"
            ;;
        *)
            echo "Unknown exporter action: $action"
            echo "Valid actions: install, uninstall, upgrade"
            usage
            ;;
    esac
}

configure_mongodb() {
    echo "Configuring MongoDB..."
    # For multi-instance, append instance name to config and PID files
    local config_file=$CONFIG_FILE
    local pid_file=$PID_FILE
    local log_dir="/var/log/mongodb"
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        config_file="/etc/mongod-${INSTANCE_NAME}.conf"
        pid_file="$PID_DIR/mongod-${INSTANCE_NAME}.pid"
        log_dir="/var/log/mongodb-${INSTANCE_NAME}"
    fi
    mkdir -p "$log_dir"
    mkdir -p "$PID_DIR"
    
    # Different configuration for standalone vs replica set
    if [[ "$STANDALONE" == "true" ]]; then
        cat > "$config_file" <<EOF
storage:
  dbPath: $DATA_DIR
systemLog:
  destination: file
  logAppend: true
  path: $log_dir/mongod.log
net:
  port: $PORT
  bindIp: 0.0.0.0
security:
  authorization: enabled
processManagement:
  pidFilePath: $pid_file
EOF
    else
        cat > "$config_file" <<EOF
storage:
  dbPath: $DATA_DIR
systemLog:
  destination: file
  logAppend: true
  path: $log_dir/mongod.log
net:
  port: $PORT
  bindIp: 0.0.0.0
replication:
  replSetName: $REPLICA_SET_NAME
security:
  authorization: enabled
  keyFile: /etc/mongod.key
processManagement:
  pidFilePath: $pid_file
EOF
    fi
    
    chown -R $MONGODB_USER:$MONGODB_USER "$log_dir"
    chown -R $MONGODB_USER:$MONGODB_USER "$PID_DIR"
    chown -R $MONGODB_USER:$MONGODB_USER "$DATA_DIR"
    chmod 750 "$DATA_DIR"
}

configure_systemd() {
    echo "Setting up systemd for MongoDB..."
    local service_file=$SERVICE_FILE
    local config_file=$CONFIG_FILE
    local pid_file=$PID_FILE
    
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        service_file="/etc/systemd/system/mongod-${INSTANCE_NAME}.service"
        config_file="/etc/mongod-${INSTANCE_NAME}.conf"
        pid_file="$PID_DIR/mongod-${INSTANCE_NAME}.pid"
    fi
    
    local description="MongoDB Database Server"
    if [[ "$STANDALONE" == "true" ]]; then
        description="MongoDB Database Server (Standalone)"
    elif [[ -n "$ROLE" ]]; then
        description="MongoDB Database Server ($ROLE)"
    fi
    
    cat > "$service_file" <<EOF
[Unit]
Description=$description
After=network.target
[Service]
User=$MONGODB_USER
Group=$MONGODB_USER
ExecStart=/usr/bin/mongod --config ${config_file}
PIDFile=${pid_file}
LimitNOFILE=64000
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$(basename $service_file)"
    systemctl start "$(basename $service_file)"
}

setup_keyfile() {
    # Keyfile is only needed for replica sets
    if [[ "$STANDALONE" == "true" ]]; then
        echo "Standalone mode, skipping keyFile creation..."
        return
    fi
    
    if [[ ! -f /etc/mongod.key ]]; then
        echo "Creating MongoDB keyFile..."
        openssl rand -base64 756 > /etc/mongod.key
    fi
    chmod 400 /etc/mongod.key
    chown $MONGODB_USER:$MONGODB_USER /etc/mongod.key
}

init_replica_set() {
    if [[ "$ROLE" == "primary" ]]; then
        echo "Initializing replica set..."
        sleep 5
        CMD=$(command -v mongosh || command -v mongo)
        $CMD --port $PRIMARY_PORT <<EOF
rs.initiate({
  _id: "$REPLICA_SET_NAME",
  members: [
    { _id: 0, host: "$PRIMARY_IP:$PRIMARY_PORT" },
    { _id: 1, host: "$SECONDARY_IP:$SECONDARY_PORT" },
    { _id: 2, host: "$ARBITER_IP:$ARBITER_PORT", arbiterOnly: true }
  ]
})
EOF
    fi
}

enable_auth_standalone() {
    echo "Configuring standalone authentication..."
    CMD=$(command -v mongosh || command -v mongo)
    
    # Wait for MongoDB to start
    sleep 3
    
    # Create users in standalone mode
    $CMD --port $PORT <<EOF
use admin
db.createUser({
  user: "${MONGO_ADMIN_USER}",
  pwd: "${MONGO_ADMIN_PASS}",
  roles: [ { role: "root", db: "admin" } ]
})
db.createUser({
  user: "${MONGO_MON_USER}",
  pwd: "${MONGO_MON_PASS}",
  roles: [
    { role: "clusterMonitor", db: "admin" },
    { role: "readAnyDatabase", db: "admin" }
  ]
})
exit
EOF

    # Restart service after enabling auth
    local service_name="mongod"
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        service_name="mongod-${INSTANCE_NAME}"
    fi
    
    echo "Restarting MongoDB service to enable authentication..."
    systemctl restart "$service_name"
    echo "Standalone authentication configuration completed."
}

enable_auth() {
    # For standalone mode, use simpler auth setup
    if [[ "$STANDALONE" == "true" ]]; then
        enable_auth_standalone
        return
    fi
    
    CMD=$(command -v mongosh || command -v mongo)

    echo "Waiting for replica set to elect primary..."

    PRIMARY_ADDR=""
    while true; do
        PRIMARY_ADDR=$($CMD --quiet --port "$PRIMARY_PORT" --eval 'rs.status().members.filter(m => m.stateStr == "PRIMARY")[0]?.name' | tr -d '"')
        if [[ -n "$PRIMARY_ADDR" ]]; then
            echo "Primary elected: $PRIMARY_ADDR"
            break
        else
            echo "Waiting for primary election..."
            sleep 2
        fi
    done

    LOCAL_ADDR=$(hostname -i 2>/dev/null | awk '{print $1}')
    if [[ -z "$LOCAL_ADDR" ]]; then
        LOCAL_ADDR=$(hostname)
    fi

    echo "Local address: $LOCAL_ADDR"

    if echo "$PRIMARY_ADDR" | grep -q "^$LOCAL_ADDR:"; then
        echo "✅ Current node is primary, creating admin users..."
        $CMD --port $PRIMARY_PORT <<EOF
use admin
db.createUser({
  user: "${MONGO_MON_USER}",
  pwd: "${MONGO_MON_PASS}",
  roles: [
    { role: "clusterMonitor", db: "admin" },
    { role: "readAnyDatabase", db: "admin" },
    { role: "read", db: "local" }
  ]
})
db.createUser({
  user: "${MONGO_ADMIN_USER}",
  pwd: "${MONGO_ADMIN_PASS}",
  roles: [ { role: "root", db: "admin" } ]
})
exit
EOF
    else
        echo "⚠️ Current node is not primary (primary is $PRIMARY_ADDR), skipping user creation..."
    fi

    # Restart service after enabling auth
    local service_name="mongod"
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        service_name="mongod-${INSTANCE_NAME}"
    fi
    systemctl restart "$service_name"
}

configure_exporter_systemd() {
    echo "Configuring exporter service..."
    local exporter_port=$PROMETHEUS_EXPORTER_PORT
    local service_name="mongodb-exporter"
    local mongodb_uri=""
    local collector_params=""
    
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        exporter_port=$((PROMETHEUS_EXPORTER_PORT + $(echo "$INSTANCE_NAME" | grep -o '[0-9]*') ))
        service_name="mongodb-exporter-${INSTANCE_NAME}"
    fi
    
    # Different URI for standalone vs replica set
    if [[ "$STANDALONE" == "true" ]]; then
        mongodb_uri="mongodb://${MONGO_MON_USER}:${MONGO_MON_PASS}@127.0.0.1:${PORT}/admin"
        # Standalone mode: disable replica set specific collectors
        collector_params="--collector.replicasetstatus=false"
    else
        mongodb_uri="mongodb://${MONGO_MON_USER}:${MONGO_MON_PASS}@${PRIMARY_IP}:${PRIMARY_PORT},${SECONDARY_IP}:${SECONDARY_PORT}/admin?replicaSet=${REPLICA_SET_NAME}"
        # Replica set mode: enable replica set specific collectors
        collector_params="--collector.replicasetstatus=true \\
  --no-mongodb.direct-connect"
    fi
    
    # Common collectors for both standalone and replica set
    local common_collectors="--collector.dbstatsfreestorage=true \\
  --collector.currentopmetrics=true \\
  --collector.topmetrics=true \\
  --collector.diagnosticdata=true \\
  --collector.dbstats=true"
    
    # Sharding collector (can be enabled for both, but more relevant for sharded clusters)
    # Disabled by default for standalone, can be customized
    if [[ "$STANDALONE" == "true" ]]; then
        collector_params="$collector_params \\
  --collector.shards=false"
    else
        collector_params="$collector_params \\
  --collector.shards=true"
    fi
    
    cat > /etc/systemd/system/${service_name}.service <<EOF
[Unit]
Description=MongoDB Exporter
After=network.target
[Service]
User=${MONGODB_USER}
Group=${MONGODB_USER}
ExecStart=${EXPORTER_INSTALL_DIR}/mongodb_exporter \\
  --mongodb.uri="${mongodb_uri}" \\
  --web.listen-address=":${exporter_port}" \\
  ${collector_params} \\
  ${common_collectors} \\
  --mongodb.global-conn-pool
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl start "$service_name"
}

install() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --role) ROLE="$2"; shift ;;
            --data-dir) DATA_DIR="$2"; shift ;;
            --primary-ip) PRIMARY_IP="$2"; shift ;;
            --secondary-ip) SECONDARY_IP="$2"; shift ;;
            --arbiter-ip) ARBITER_IP="$2"; shift ;;
            --mongodb-version) MONGODB_VERSION="$2"; shift ;;
            --multi-instance) MULTI_INSTANCE=true ;;
            --standalone) STANDALONE=true ;;
            --port) STANDALONE_PORT="$2"; shift ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
        shift
    done
    
    # Validate parameters
    if [[ -z "$DATA_DIR" ]]; then
        echo "Error: install requires --data-dir"
        usage
    fi
    
    # Standalone and replica set are mutually exclusive
    if [[ "$STANDALONE" == "true" ]]; then
        if [[ -n "$ROLE" ]]; then
            echo "Warning: standalone mode does not need --role parameter, ignoring..."
        fi
        PORT=$STANDALONE_PORT
        ROLE="standalone"
        echo "Deploying standalone MongoDB on port: $PORT"
    else
        if [[ -z "$ROLE" ]]; then
            echo "Error: replica set mode requires --role parameter"
            usage
        fi
        if [[ "$ROLE" != "primary" && "$ROLE" != "secondary" && "$ROLE" != "arbiter" ]]; then
            echo "Error: role must be 'primary', 'secondary' or 'arbiter'"
            exit 1
        fi
        case $ROLE in
            primary) PORT=$PRIMARY_PORT; INSTANCE_NAME="primary" ;;
            secondary) PORT=$SECONDARY_PORT; INSTANCE_NAME="secondary" ;;
            arbiter) PORT=$ARBITER_PORT; INSTANCE_NAME="arbiter" ;;
        esac
    fi
    
    if [[ ! -d "$DATA_DIR" ]]; then
        mkdir -p "$DATA_DIR"
    fi
    
    # Adjust config and PID file paths for multi-instance
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        CONFIG_FILE="/etc/mongod-${INSTANCE_NAME}.conf"
        PID_FILE="$PID_DIR/mongod-${INSTANCE_NAME}.pid"
    fi
    
    check_os
    create_mongodb_user
    install_mongodb
    setup_keyfile
    configure_mongodb
    configure_systemd
    
    # For standalone, enable auth immediately after installation
    if [[ "$STANDALONE" == "true" ]]; then
        enable_auth
        configure_exporter_systemd
        echo "Standalone MongoDB installation completed on port: $PORT"
        echo "Admin user: ${MONGO_ADMIN_USER}"
        echo "Admin password: ${MONGO_ADMIN_PASS}"
        echo "Prometheus exporter port: $PROMETHEUS_EXPORTER_PORT"
    else
        echo "MongoDB installation completed, node role: $ROLE."
    fi
}

init_replica() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --role) ROLE="$2"; shift ;;
            --primary-ip) PRIMARY_IP="$2"; shift ;;
            --secondary-ip) SECONDARY_IP="$2"; shift ;;
            --arbiter-ip) ARBITER_IP="$2"; shift ;;
            --multi-instance) MULTI_INSTANCE=true ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
        shift
    done
    if [[ -z "$ROLE" || -z "$PRIMARY_IP" || -z "$SECONDARY_IP" || -z "$ARBITER_IP" ]]; then
        echo "Error: init-replica requires --role, --primary-ip, --secondary-ip and --arbiter-ip"
        usage
    fi
    if [[ "$ROLE" != "primary" && "$ROLE" != "secondary" && "$ROLE" != "arbiter" ]]; then
        echo "Error: role must be 'primary', 'secondary' or 'arbiter'"
        exit 1
    fi
    case $ROLE in
        primary) PORT=$PRIMARY_PORT; INSTANCE_NAME="primary" ;;
        secondary) PORT=$SECONDARY_PORT; INSTANCE_NAME="secondary" ;;
        arbiter) PORT=$ARBITER_PORT; INSTANCE_NAME="arbiter" ;;
    esac
    init_replica_set
    echo "Replica set initialization completed, node role: $ROLE."
}

config_auth() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --role) ROLE="$2"; shift ;;
            --primary-ip) PRIMARY_IP="$2"; shift ;;
            --secondary-ip) SECONDARY_IP="$2"; shift ;;
            --multi-instance) MULTI_INSTANCE=true ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
        shift
    done
    if [[ -z "$ROLE" || -z "$PRIMARY_IP" || -z "$SECONDARY_IP" ]]; then
        echo "Error: config-auth requires --role, --primary-ip and --secondary-ip"
        usage
    fi
    if [[ "$ROLE" != "primary" && "$ROLE" != "secondary" && "$ROLE" != "arbiter" ]]; then
        echo "Error: role must be 'primary', 'secondary' or 'arbiter'"
        exit 1
    fi
    case $ROLE in
        primary) PORT=$PRIMARY_PORT; INSTANCE_NAME="primary" ;;
        secondary) PORT=$SECONDARY_PORT; INSTANCE_NAME="secondary" ;;
        arbiter) PORT=$ARBITER_PORT; INSTANCE_NAME="arbiter" ;;
    esac
    enable_auth
    configure_exporter_systemd
    echo "Authentication configuration completed, node role: $ROLE. Exporter running on port $PROMETHEUS_EXPORTER_PORT."
}

main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi
    SUBCOMMAND=$1
    shift
    case $SUBCOMMAND in
        install)
            install "$@"
            ;;
        init-replica)
            init_replica "$@"
            ;;
        config-auth)
            config_auth "$@"
            ;;
        exporter)
            manage_exporter "$@"
            ;;
        *)
            echo "Unknown subcommand: $SUBCOMMAND"
            usage
            ;;
    esac
}

main "$@"