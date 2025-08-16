#!/bin/bash

# Check if running in Bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: Please use bash to execute this script (bash $0 or ./$0)"
    exit 1
fi

# Constants
REDIS_HOME="/usr/local/redis"
CONFIG_DIR="/etc/redis"
DATA_DIR="/data"
REDIS_VERSION="8.0.3"
REDIS_URL="https://github.com/redis/redis/archive/refs/tags/$REDIS_VERSION.tar.gz"
REDIS_CONF_URL="https://raw.githubusercontent.com/redis/redis/refs/tags/$REDIS_VERSION"

# Supported distributions
SUPPORTED_DISTROS=("ubuntu" "debian" "centos" "rhel" "rocky" "amzn")

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [options]

Options:
  -t, --type <single|single-cluster|multi-cluster>  Deployment type
  -p, --ports <port1,port2,...>                    Redis ports (comma-separated)
  -v, --version 6.0.0                              Redis version
  -h, --help                                       Display this help message

Examples:
  # Install single Redis instance on port 6379
  $0 -t single -p 6379

  # Install single node cluster on ports 6379,6380
  $0 -t single-cluster -p 6379,6380

  # Install multi-node cluster
  $0 -t multi-cluster -p 6379,6380,6381
EOF
    exit 0
}

# Function to check and install dependencies
install_dependencies() {
    local distro=$1
    echo "Installing dependencies for $distro..."

    case $distro in
        ubuntu|debian)
            apt-get update
            apt-get install -y gcc g++ tcl make tar wget
            ;;
        centos|rhel|rocky|amzn)
            yum -y install gcc gcc-c++ tcl make tar wget
            ;;
        *)
            echo "Error: Unsupported OS: $distro"
            exit 1
            ;;
    esac
}

# Function to optimize kernel parameters
optimize_kernel() {
    echo "Optimizing kernel parameters..."
    local config_lines=(
        "net.core.somaxconn = 511"
        "vm.overcommit_memory = 1"
    )

    for config in "${config_lines[@]}"; do
        grep -qxF "$config" /etc/sysctl.conf || echo "$config" | sudo tee -a /etc/sysctl.conf > /dev/null
    done
    sudo sysctl -p >/dev/null

    # Disable transparent huge pages
    grep -q "transparent_hugepage/enabled" /etc/rc.local || \
        echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" | sudo tee -a /etc/rc.local
}

# Function to install Redis
install_redis() {
    echo "Installing Redis..."
    mkdir -p /usr/local/src
    cd /usr/local/src || exit 1

    if [ -d "redis-$REDIS_VERSION" ] && [ -x "$REDIS_HOME/bin/redis-server" ]; then
        echo "Redis already installed."
        return 0
    fi

    wget -q "$REDIS_URL" -O redis-$REDIS_VERSION.tar.gz
    tar xf redis-$REDIS_VERSION.tar.gz
    cd redis-$REDIS_VERSION || exit 1
    make MALLOC=jemalloc
    make install PREFIX="$REDIS_HOME"
    cp redis.conf "$CONFIG_DIR/"
}

# Function to configure Redis services
configure_redis_services() {
    local deploy_type=$1
    local ports=("${@:2}")
    local redis_ip="127.0.0.1"
    local password=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9')
    local conf_file

    mkdir -p "$CONFIG_DIR"

    # Download appropriate config template
    if [ ${#ports[@]} -gt 1 ] || [ "$deploy_type" = "single-cluster" ] || [ "$deploy_type" = "multi-cluster" ]; then
        wget -q -O "$CONFIG_DIR/redis-demo.conf" "$REDIS_CONF_URL/redis.conf"
        # Enable cluster mode in config for cluster deployments
        for port in "${ports[@]}"; do
            conf_file="$CONFIG_DIR/redis-$port.conf"
            cp "$CONFIG_DIR/redis-demo.conf" "$conf_file"
            sed -i "s/bind 127.0.0.1 -::1/bind ${redis_ip}/g" "$conf_file"
            sed -i "s/port 6379/port ${port}/g" "$conf_file"
            sed -i "s/# requirepass foobared/requirepass ${password}/g" "$conf_file"
            sed -i "s/# cluster-enabled yes/cluster-enabled yes/g" "$conf_file"
            mkdir -p "$DATA_DIR/redis-$port"
        done
    else
        wget -q -O "$CONFIG_DIR/redis-demo.conf" "$REDIS_CONF_URL/redis.conf"
        conf_file="$CONFIG_DIR/redis-${ports[0]}.conf"
        cp "$CONFIG_DIR/redis-demo.conf" "$conf_file"
        sed -i "s/bind 127.0.0.1 -::1/bind ${redis_ip}/g" "$conf_file"
        sed -i "s/port 6379/port ${ports[0]}/g" "$conf_file"
        sed -i "s/# requirepass foobared/requirepass ${password}/g" "$conf_file"
        mkdir -p "$DATA_DIR/redis-${ports[0]}"
    fi
    rm -fr $CONFIG_DIR/redis-demo.conf
    echo "$password"
}

# Function to create systemd service
create_systemd_service() {
    local port=$1
    local deploy_type=$2
    local service_name="redis"
    local service_file

    # Use port in service name for cluster deployments
    if [ "$deploy_type" != "single" ]; then
        service_name="redis-$port"
    fi

    service_file="/etc/systemd/system/$service_name.service"
    
    echo "Creating systemd service for $service_name..."
    tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Redis server on port $port
After=syslog.target network.target

[Service]
Type=simple
ExecStart=$REDIS_HOME/bin/redis-server $CONFIG_DIR/redis-$port.conf
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl --now enable "$service_name"
    systemctl status "$service_name" --no-pager
}

# Function to setup environment variables
setup_environment() {
    echo "Setting up environment variables..."
    grep -qxF "export REDIS_HOME=$REDIS_HOME" /etc/profile || \
        echo "export REDIS_HOME=$REDIS_HOME" >> /etc/profile
    grep -qxF "export PATH=\$PATH:\$REDIS_HOME/bin" /etc/profile || \
        echo "export PATH=\$PATH:\$REDIS_HOME/bin" >> /etc/profile
    source /etc/profile
}

# Main function
main() {
    local deploy_type=""
    local ports=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--type)
                deploy_type="$2"
                shift 2
                ;;
            -p|--ports)
                IFS=',' read -ra ports <<< "$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            -v|--version)
                REDIS_VERSION="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown option $1"
                usage
                ;;
        esac
    done

    # Validate inputs
    if [ -z "$deploy_type" ] || [ ${#ports[@]} -eq 0 ]; then
        echo "Error: Deployment type and ports are required"
        usage
    fi

    if [[ ! "single single-cluster multi-cluster" =~ $deploy_type ]]; then
        echo "Error: Invalid deployment type. Must be single, single-cluster, or multi-cluster"
        exit 1
    fi

    # Get OS distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        distro=$ID
    else
        echo "Error: Cannot determine OS distribution"
        exit 1
    fi

    if [[ ! "${SUPPORTED_DISTROS[@]}" =~ $distro ]]; then
        echo "Error: Unsupported OS: $distro"
        exit 1
    fi

    # Execute installation steps
    install_dependencies "$distro"
    optimize_kernel
    install_redis
    password=$(configure_redis_services "$deploy_type" "${ports[@]}")
    for port in "${ports[@]}"; do
        create_systemd_service "$port" "$deploy_type"
    done
    setup_environment

    echo -e "\033[32m############### Redis installation completed ###############\033[0m"
    echo "Redis password: $password"
    echo "Run init_redis_cluster.sh with the same -t and -p options to initialize the cluster"
}

# Execute main function
main "$@"