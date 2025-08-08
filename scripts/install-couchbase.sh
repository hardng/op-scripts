#!/bin/bash
# Script to deploy and manage Couchbase Server Community Edition on Rocky Linux 9
# Supports single/multiple nodes on one server, initialization, and node addition
# Usage: ./deploy_couchbase_multi_node.sh [install|init|add|dual] [options]

# Exit on any error
set -e

# Default values
ADMIN_USER="Administrator"
ADMIN_PASS="password123"
CLUSTER_NAME="my_cluster"
SERVICES="data,query,index,fts"
LISTEN_IP=""
LOG_FILE="/var/log/couchbase_deployment.log"
COUCHBASE_VERSION="7.6.4"
NODE_IP=""
SECOND_NODE_IP=""
INSTANCE_COUNT=1
BASE_PORT=8091
SECOND_BASE_PORT=9091
DATA_PATH1="/opt/couchbase/var/lib/couchbase"
DATA_PATH2="/opt/couchbase2/var/lib/couchbase"

# Function to log messages
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: This script must be run as root."
        exit 1
    fi
}

# Function to check disk space
check_disk_space() {
    local path=$1
    local required_space=20  # GB
    local available_space=$(df -h "$path" | tail -1 | awk '{print $4}' | grep -oE '[0-9]+')
    if [[ -z "$available_space" || "$available_space" -lt "$required_space" ]]; then
        log "ERROR: Insufficient disk space at $path. Required: ${required_space}GB, Available: ${available_space}GB."
        exit 1
    fi
    log "SUCCESS: Sufficient disk space at $path (Available: ${available_space}GB)."
}

# Function to check if port is listening
check_port() {
    local ip=$1
    local port=$2
    local max_attempts=6  # 30 seconds total (6 * 5 seconds)
    local attempt=1

    log "Checking if port ${ip}:${port} is listening..."
    while [[ $attempt -le $max_attempts ]]; do
        log "Attempt $attempt/$max_attempts: Checking port ${ip}:${port}..."
        if netstat -tuln | grep -q "${ip}:${port}"; then
            log "SUCCESS: Port ${ip}:${port} is listening."
            return 0
        fi
        log "Port ${ip}:${port} not yet listening, waiting..."
        sleep 5
        ((attempt++))
    done

    log "ERROR: Port ${ip}:${port} is not listening after $max_attempts attempts."
    lsof -i :${port} >> "$LOG_FILE" 2>&1 || log "No process found using port ${port}."
    return 1
}

# Function to install Couchbase Server
install_couchbase() {
    local instance_num=$1
    local data_path=$2
    local base_port=$3
    local install_dir="/opt/couchbase${instance_num:+_$instance_num}"
    local service_name="couchbase-server${instance_num:+_$instance_num}"
    local rpm_file="couchbase-release-1.0-x86_64.rpm"

    log "Starting installation of Couchbase Server instance $instance_num to $install_dir..."

    # Check disk space
    check_disk_space "/opt"

    # Update system
    log "Updating system packages..."
    if dnf update -y; then
        log "SUCCESS: System packages updated."
    else
        log "ERROR: System update failed."
        exit 1
    fi

    # Install dependencies
    log "Installing dependencies (bzip2, ncurses-compat-libs, curl)..."
    if dnf install -y bzip2 ncurses-compat-libs curl; then
        log "SUCCESS: Dependencies installed."
    else
        log "ERROR: Dependency installation failed."
        exit 1
    fi

    # Disable Transparent Huge Pages (THP)
    log "Disabling Transparent Huge Pages..."
    cat > /etc/systemd/system/disable_thp.service << 'EOL'
[Unit]
Description=Disable Kernel Support for Transparent Huge Pages (THP)
[Service]
Type=simple
ExecStart=/bin/sh -c "echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled && echo 'never' > /sys/kernel/mm/transparent_hugepage/defrag"
[Install]
WantedBy=multi-user.target
EOL
    if systemctl enable disable_thp.service && systemctl start disable_thp.service; then
        log "SUCCESS: Transparent Huge Pages disabled."
    else
        log "ERROR: Failed to disable Transparent Huge Pages."
        exit 1
    fi

    # Download Couchbase release meta package
    log "Downloading Couchbase release meta package ($rpm_file)..."
    if curl -f -O https://packages.couchbase.com/releases/couchbase-release/couchbase-release-1.0-x86_64.rpm; then
        log "SUCCESS: Downloaded $rpm_file."
    else
        log "ERROR: Failed to download $rpm_file. Check network or URL."
        exit 1
    fi

    # Install Couchbase release meta package
    log "Installing $rpm_file..."
    if dnf install -y "./$rpm_file"; then
        log "SUCCESS: Installed $rpm_file."
    else
        log "ERROR: Failed to install $rpm_file."
        rm -f "$rpm_file" 2>/dev/null || true
        exit 1
    fi

    # Clean up RPM file
    log "Cleaning up $rpm_file..."
    if rm -f "$rpm_file" 2>/dev/null; then
        log "SUCCESS: Removed $rpm_file."
    else
        log "WARNING: Could not remove $rpm_file, file may not exist."
    fi

    # Install Couchbase Server Community Edition
    log "Installing Couchbase Server Community Edition version ${COUCHBASE_VERSION}..."
    if dnf install -y couchbase-server-community-${COUCHBASE_VERSION}; then
        log "SUCCESS: Couchbase Server Community Edition installed."
    else
        log "ERROR: Couchbase installation failed."
        exit 1
    fi

    # Configure data path for instance
    if [[ $instance_num -gt 1 ]]; then
        log "Configuring data path for instance $instance_num at $data_path..."
        mkdir -p "$data_path"
        chown -R couchbase:couchbase "$data_path"
        mv /opt/couchbase /opt/couchbase${instance_num:+_$instance_num}
        sed -i "s|/opt/couchbase/var/lib/couchbase|$data_path|g" /opt/couchbase${instance_num:+_$instance_num}/etc/couchbase/static_config
        log "SUCCESS: Data path configured for instance $instance_num."
    fi

    # Configure custom ports
    if [[ $base_port -ne 8091 ]]; then
        log "Configuring custom ports starting at $base_port for instance $instance_num..."
        cat > /opt/couchbase${instance_num:+_$instance_num}/etc/couchbase/static_config << EOL
{rest_port, $base_port}.
{mccouch_port, $((base_port + 1))}.
{query_port, $((base_port + 2))}.
{ssl_rest_port, $((base_port + 1000))}.
{ssl_capi_port, $((base_port + 1001))}.
{ssl_query_port, $((base_port + 1002))}.
{memcached_port, $((base_port + 3100))}.
EOL
        log "SUCCESS: Custom ports configured."
    fi

    # Create systemd service for additional instance
    if [[ $instance_num -gt 1 ]]; then
        log "Creating systemd service for instance $instance_num..."
        cp /usr/lib/systemd/system/couchbase-server.service /etc/systemd/system/couchbase-server_${instance_num}.service
        sed -i "s|/opt/couchbase|/opt/couchbase_${instance_num}|g" /etc/systemd/system/couchbase-server_${instance_num}.service
        systemctl daemon-reload
        log "SUCCESS: Systemd service created for instance $instance_num."
    else
        service_name="couchbase-server"
    fi

    # Start Couchbase Server
    log "Starting Couchbase Server instance $instance_num..."
    if systemctl enable "$service_name" && systemctl start "$service_name"; then
        log "SUCCESS: Couchbase Server instance $instance_num started."
    else
        log "ERROR: Failed to start Couchbase Server instance $instance_num. Check logs in $data_path/logs."
        journalctl -u "$service_name" >> "$LOG_FILE" 2>&1
        exit 1
    fi

    # Verify installation
    if systemctl is-active --quiet "$service_name"; then
        log "SUCCESS: Couchbase Server instance $instance_num is running."
        # Check if port is listening
        check_port "${LISTEN_IP:-127.0.0.1}" "$base_port" || {
            log "ERROR: Failed to verify port $base_port. Check network or service configuration."
            journalctl -u "$service_name" >> "$LOG_FILE" 2>&1
            exit 1
        }
    else
        log "ERROR: Couchbase Server instance $instance_num failed to start. Check logs in $data_path/logs."
        journalctl -u "$service_name" >> "$LOG_FILE" 2>&1
        exit 1
    fi
}

# Function to initialize first node
init_cluster() {
    if [[ -z "$LISTEN_IP" ]]; then
        log "ERROR: Listen IP must be specified for cluster initialization."
        exit 1
    fi

    local base_port=$1
    local instance_num=$2
    local data_path=$3
    local max_attempts=12  # 60 seconds total (12 * 5 seconds)
    local attempt=1

    log "Initializing first node on ${LISTEN_IP}:${base_port} instance $instance_num..."

    # Wait for Couchbase to be ready
    while [[ $attempt -le $max_attempts ]]; do
        log "Attempt $attempt/$max_attempts: Checking if Couchbase is ready at http://${LISTEN_IP}:${base_port}..."
        if curl -s -o /dev/null http://${LISTEN_IP}:${base_port}; then
            log "SUCCESS: Couchbase is ready on ${LISTEN_IP}:${base_port}."
            break
        fi
        log "Waiting for Couchbase to be ready..."
        sleep 5
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        log "ERROR: Timeout waiting for Couchbase to be ready on ${LISTEN_IP}:${base_port}."
        log "Checking service status..."
        systemctl status "couchbase-server${instance_num:+_$instance_num}" >> "$LOG_FILE" 2>&1
        log "Checking port ${LISTEN_IP}:${base_port}..."
        netstat -tuln | grep "${base_port}" >> "$LOG_FILE" 2>&1 || log "No process listening on port ${base_port}."
        log "Check logs in $data_path/logs for details."
        exit 1
    fi

    # Initialize cluster
    log "Running cluster initialization..."
    if [[ $instance_num -gt 1 ]]; then
        if /opt/couchbase${instance_num:+_$instance_num}/bin/couchbase-cli cluster-init -c ${LISTEN_IP}:${base_port} \
            --cluster-username "${ADMIN_USER}" \
            --cluster-password "${ADMIN_PASS}" \
            --cluster-name "${CLUSTER_NAME}" \
            --services "${SERVICES}" \
            --cluster-ramsize 1024 \
            --cluster-index-ramsize 256 \
            --cluster-fts-ramsize 256; then
            log "SUCCESS: Cluster initialized successfully."
        else
            log "ERROR: Cluster initialization failed."
            exit 1
        fi
    else
         if /opt/couchbase/bin/couchbase-cli cluster-init -c ${LISTEN_IP}:${base_port} \
            --cluster-username "${ADMIN_USER}" \
            --cluster-password "${ADMIN_PASS}" \
            --cluster-name "${CLUSTER_NAME}" \
            --services "${SERVICES}" \
            --cluster-ramsize 1024 \
            --cluster-index-ramsize 256 \
            --cluster-fts-ramsize 256; then
            log "SUCCESS: Cluster initialized successfully."
        else
            log "ERROR: Cluster initialization failed."
            exit 1
        fi
    fi

    log "Cluster ready. Access at http://${LISTEN_IP}:${base_port}"
}

# Function to add a new node to the cluster
add_node() {
    if [[ -z "$NODE_IP" || -z "$SECOND_NODE_IP" ]]; then
        log "ERROR: Both primary node IP and new node IP must be specified."
        exit 1
    fi

    local primary_port=$1
    local second_port=$2
    local instance_num=$3
    local max_attempts=12
    local attempt=1

    log "Adding node ${SECOND_NODE_IP}:${second_port} to cluster at ${NODE_IP}:${primary_port}..."

    # Wait for new node to be ready
    while [[ $attempt -le $max_attempts ]]; do
        log "Attempt $attempt/$max_attempts: Checking if new node is ready at http://${SECOND_NODE_IP}:${second_port}..."
        if curl -s -o /dev/null http://${SECOND_NODE_IP}:${second_port}; then
            log "SUCCESS: New node is ready on ${SECOND_NODE_IP}:${second_port}."
            break
        fi
        log "Waiting for new node to be ready..."
        sleep 5
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        log "ERROR: Timeout waiting for new node on ${SECOND_NODE_IP}:${second_port}."
        exit 1
    fi

    # Add node to cluster
    log "Adding node to cluster..."
    if /opt/couchbase${instance_num:+_$instance_num}/bin/couchbase-cli server-add -c ${NODE_IP}:${primary_port} \
        --username "${ADMIN_USER}" \
        --password "${ADMIN_PASS}" \
        --server-add ${SECOND_NODE_IP}:${second_port}; then
        log "SUCCESS: Node added to cluster."
    else
        log "ERROR: Failed to add node."
        exit 1
    fi

    # Rebalance cluster
    log "Rebalancing cluster..."
    if /opt/couchbase${instance_num:+_$instance_num}/bin/couchbase-cli rebalance -c ${NODE_IP}:${primary_port} \
        --username "${ADMIN_USER}" \
        --password "${ADMIN_PASS}"; then
        log "SUCCESS: Cluster rebalanced successfully."
    else
        log "ERROR: Rebalance failed."
        exit 1
    fi

    log "Node ${SECOND_NODE_IP}:${second_port} added and cluster rebalanced successfully."
}

# Function to set up dual nodes on one server
setup_dual_nodes() {
    log "Setting up dual nodes on one server..."

    # Install first instance
    install_couchbase 1 "$DATA_PATH1" "$BASE_PORT"

    # Install second instance
    install_couchbase 2 "$DATA_PATH2" "$SECOND_BASE_PORT"

    # Initialize first node
    init_cluster "$BASE_PORT" 1 "$DATA_PATH1"

    # Add second node to cluster
    add_node "$BASE_PORT" "$SECOND_BASE_PORT" 1
}

# Function to display usage
usage() {
    echo "Usage: $0 [install|init|add|dual] [options]"
    echo "Commands:"
    echo "  install           Install Couchbase Server (single instance)"
    echo "  init              Initialize first node of the cluster"
    echo "  add               Add a new node to an existing cluster"
    echo "  dual              Install and configure two nodes on one server"
    echo "Options:"
    echo "  --listen-ip       IP address for the node to listen on (required for init/dual)"
    echo "  --node-ip         IP address of the primary node (required for add)"
    echo "  --second-node-ip  IP address of the new node to add (required for add)"
    echo "  --admin-user      Admin username (default: ${ADMIN_USER})"
    echo "  --admin-pass      Admin password (default: ${ADMIN_PASS})"
    echo "  --cluster-name    Cluster name (default: ${CLUSTER_NAME})"
    echo "  --services        Services to enable (default: ${SERVICES})"
    echo "  --base-port       Base port for first instance (default: ${BASE_PORT})"
    echo "  --second-base-port Base port for second instance (default: ${SECOND_BASE_PORT})"
    echo "Example:"
    echo "  $0 install"
    echo "  $0 init --listen-ip 192.168.1.10"
    echo "  $0 add --node-ip 192.168.1.10 --second-node-ip 192.168.1.11 --base-port 8091 --second-base-port 9091"
    echo "  $0 dual --listen-ip 192.168.1.10"
    exit 1
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    usage
fi

COMMAND="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --listen-ip) LISTEN_IP="$2"; shift 2 ;;
        --node-ip) NODE_IP="$2"; shift 2 ;;
        --second-node-ip) SECOND_NODE_IP="$2"; shift 2 ;;
        --admin-user) ADMIN_USER="$2"; shift 2 ;;
        --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --services) SERVICES="$2"; shift 2 ;;
        --base-port) BASE_PORT="$2"; shift 2 ;;
        --second-base-port) SECOND_BASE_PORT="$2"; shift 2 ;;
        *) log "ERROR: Unknown option $1"; usage ;;
    esac
done

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")"

# Check root privileges
check_root

# Execute command
case "$COMMAND" in
    install)
        install_couchbase 1 "$DATA_PATH1" "$BASE_PORT"
        ;;
    init)
        init_cluster "$BASE_PORT" 1 "$DATA_PATH1"
        ;;
    add)
        add_node "$BASE_PORT" "$SECOND_BASE_PORT" 1
        ;;
    dual)
        if [[ -z "$LISTEN_IP" ]]; then
            log "ERROR: Listen IP must be specified for dual mode."
            exit 1
        fi
        SECOND_NODE_IP="$LISTEN_IP"
        setup_dual_nodes
        ;;
    *)
        log "ERROR: Invalid command: $COMMAND"
        usage
        ;;
esac

log "Operation completed successfully."