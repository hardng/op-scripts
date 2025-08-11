#!/bin/bash

# Check if running in Bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: Please use bash to execute this script (bash $0 or ./$0)"
    exit 1
fi

# Constants
REDIS_HOME="/usr/local/redis"
CONFIG_DIR="/etc/redis"
REDIS_IP="127.0.0.1"

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [options]

Options:
  -t, --type <single|single-cluster|multi-cluster>  Deployment type
  -p, --ports <port1,port2,...>                    Redis ports (comma-separated)
  -h, --help                                       Display this help message

Examples:
  # Initialize single Redis instance on port 6379
  $0 -t single -p 6379

  # Initialize single node cluster on ports 6379,6380
  $0 -t single-cluster -p 6379,6380

  # Initialize multi-node cluster
  $0 -t multi-cluster -p 6379,6380,6381
EOF
    exit 0
}

# Function to validate installation
validate_installation() {
    local deploy_type=$1
    local ports=("${@:2}")

    # Check if Redis is installed
    if [ ! -x "$REDIS_HOME/bin/redis-server" ]; then
        echo "Error: Redis not installed. Please run install_redis.sh first"
        exit 1
    fi

    # Check if config files exist for all specified ports
    for port in "${ports[@]}"; do
        if [ ! -f "$CONFIG_DIR/redis-$port.conf" ]; then
            echo "Error: Configuration file for port $port not found. Ensure install_redis.sh was run with the same parameters"
            exit 1
        fi
    done

    # Verify cluster-enabled setting matches deployment type
    if [ "$deploy_type" = "single" ]; then
        if [ ${#ports[@]} -ne 1 ]; then
            echo "Error: Single deployment requires exactly one port"
            exit 1
        fi
        if grep -q "cluster-enabled yes" "$CONFIG_DIR/redis-${ports[0]}.conf"; then
            echo "Error: Configuration for port ${ports[0]} has cluster-enabled set, but single deployment was specified"
            exit 1
        fi
    else
        for port in "${ports[@]}"; do
            if ! grep -q "cluster-enabled yes" "$CONFIG_DIR/redis-$port.conf"; then
                echo "Error: Configuration for port $port does not have cluster-enabled set, but cluster deployment was specified"
                exit 1
            fi
        done
    fi
}

# Function to initialize Redis cluster
initialize_cluster() {
    local deploy_type=$1
    local ports=("${@:2}")
    local cluster_nodes=""

    # Get password from first config file
    local password=$(grep "requirepass" "$CONFIG_DIR/redis-${ports[0]}.conf" | awk '{print $2}')

    # For single instance, no cluster initialization needed
    if [ "$deploy_type" = "single" ]; then
        echo "Single instance deployment, no cluster initialization required"
        return 0
    fi

    # Build cluster nodes string
    for port in "${ports[@]}"; do
        cluster_nodes="$cluster_nodes $REDIS_IP:$port"
    done

    # Initialize cluster
    echo "Initializing Redis cluster..."
    "$REDIS_HOME/bin/redis-cli" --pass "$password" --cluster create $cluster_nodes --cluster-replicas 0 -y
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

    # Validate installation matches configuration
    validate_installation "$deploy_type" "${ports[@]}"

    # Initialize cluster
    initialize_cluster "$deploy_type" "${ports[@]}"

    # Output password
    local password=$(grep "requirepass" "$CONFIG_DIR/redis-${ports[0]}.conf" | awk '{print $2}')
    echo -e "\033[32m############### Redis cluster initialization completed ###############\033[0m"
    echo "Redis password: $password"
}

# Execute main function
main "$@"