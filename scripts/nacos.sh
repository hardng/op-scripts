#!/bin/bash
set -e

# Usage function
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help         Display this help message"
    echo "  -v, --version      Specify Nacos version (e.g., 2.5.1). If not provided, fetches latest version."
    echo "  -p, --enable-prometheus  Enable built-in Prometheus metrics (exposes /nacos/actuator/prometheus endpoint)."
    echo ""
    echo "This script installs Docker, Docker Compose, and Nacos with MySQL persistence."
    echo "It generates random passwords for MySQL root and Nacos user, and outputs them at the end."
    echo "Supported OS: CentOS/RedHat or Ubuntu/Debian."
    exit 0
}

# Function to download file if it doesn't exist
download_if_not_exists() {
    local url="$1"
    local file_path="$2"
    
    if [ -f "$file_path" ]; then
        echo -e "\033[32mFile $file_path already exists. Skipping download.\033[0m"
        return 0
    fi
    
    echo -e "\033[32mDownloading $file_path...\033[0m"
    if ! wget "$url" -O "$file_path" && ! curl -o "$file_path" "$url"; then
        echo -e "\033[31mFailed to download $file_path.\033[0m"
        exit 1
    fi
    echo -e "\033[32mFile $file_path downloaded successfully.\033[0m"
}

# Main function
main() {
    # Parse command line arguments
    NACOS_VERSION=""
    ENABLE_PROMETHEUS=true
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -v|--version)
                NACOS_VERSION="$2"
                shift 2
                ;;
            -p|--enable-prometheus)
                ENABLE_PROMETHEUS=true
                shift
                ;;
            *)
                echo -e "\033[31mUnknown option: $1\033[0m"
                usage
                ;;
        esac
    done

    # Define variables
    NACOS_DIR="/opt/nacos-docker"
    NACOS_CONF_DIR="$NACOS_DIR/example/nacos-conf"
    NACOS_DATA_DIR="$NACOS_DIR/example/nacos-data"
    DOCKER_COMPOSE_VERSION="v2.23.3"
    TEMP_DIR="/tmp/nacos-install"

    # Generate random passwords
    MYSQL_ROOT_PASSWORD=$(openssl rand -base64 16)
    NACOS_MYSQL_PASSWORD=$(openssl rand -base64 16)

    # Fetch latest Nacos version if not specified
    if [ -z "$NACOS_VERSION" ]; then
        echo -e "\033[32m#################### Fetching latest Nacos version... ####################\033[0m"
        NACOS_VERSION=$(curl -s https://api.github.com/repos/alibaba/nacos/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
        if [ -z "$NACOS_VERSION" ]; then
            echo -e "\033[31mFailed to fetch latest Nacos version. Please specify version with -v option.\033[0m"
            exit 1
        fi
        echo -e "\033[32mLatest Nacos version: $NACOS_VERSION\033[0m"
    fi

    # Validate Nacos version
    if ! curl -s https://github.com/alibaba/nacos/releases/tag/$NACOS_VERSION >/dev/null; then
        echo -e "\033[31mInvalid Nacos version: $NACOS_VERSION. Please check available versions at https://github.com/alibaba/nacos/releases.\033[0m"
        exit 1
    fi

    # Check if version supports Prometheus (0.8.0+)
    if [[ "$NACOS_VERSION" < "0.8.0" && "$ENABLE_PROMETHEUS" = true ]]; then
        echo -e "\033[33mWarning: Nacos version $NACOS_VERSION may not support Prometheus metrics. Proceeding anyway.\033[0m"
    fi

    # Detect OS type
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="redhat"
        PKG_MANAGER="yum"
    elif [ -f /etc/debian_version ] || grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
        OS_TYPE="debian"
        PKG_MANAGER="apt"
    else
        echo -e "\033[31mUnsupported OS. Only CentOS/RedHat and Ubuntu/Debian are supported.\033[0m"
        exit 1
    fi

    # Install dependencies
    echo -e "\033[32m#################### Installing dependencies... ####################\033[0m"
    if [ "$OS_TYPE" = "redhat" ]; then
        $PKG_MANAGER remove docker-common -y || true
        $PKG_MANAGER -y install git wget telnet tar zip unzip
    elif [ "$OS_TYPE" = "debian" ]; then
        $PKG_MANAGER update
        $PKG_MANAGER -y install git wget telnet tar zip unzip curl apt-transport-https ca-certificates gnupg lsb-release
    fi

    # Install Docker
    echo -e "\033[32m#################### Installing Docker... ####################\033[0m"
    if [ "$OS_TYPE" = "redhat" ]; then
        if ! rpm -q docker-ce docker-ce-cli containerd.io >/dev/null 2>&1; then
            DOCKER_REPO_URL="http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo"
            download_if_not_exists "$DOCKER_REPO_URL" "/etc/yum.repos.d/docker-ce.repo"
            $PKG_MANAGER -y install docker-ce docker-ce-cli containerd.io
        else
            echo -e "\033[32mDocker (docker-ce, docker-ce-cli, containerd.io) already installed. Skipping installation.\033[0m"
        fi
    elif [ "$OS_TYPE" = "debian" ]; then
        if ! dpkg -l | grep -q docker-ce; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            $PKG_MANAGER update
            $PKG_MANAGER -y install docker-ce docker-ce-cli containerd.io
        else
            echo -e "\033[32mDocker (docker-ce, docker-ce-cli, containerd.io) already installed. Skipping installation.\033[0m"
        fi
    fi
    systemctl enable --now docker

    # Install Docker Compose
    echo -e "\033[32m#################### Installing Docker Compose... ####################\033[0m"
    if [ ! -f "/usr/local/bin/docker-compose" ]; then
        DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64"
        download_if_not_exists "$DOCKER_COMPOSE_URL" "/usr/local/bin/docker-compose"
        chmod +x /usr/local/bin/docker-compose
    else
        echo -e "\033[32mDocker Compose already installed. Skipping installation.\033[0m"
    fi
    if [ ! -f "/usr/bin/docker-compose" ]; then
        ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    else
        echo -e "\033[32mDocker Compose symbolic link already exists. Skipping creation.\033[0m"
    fi

    echo -e "\033[32m#################### Docker and Docker Compose installed successfully ####################\033[0m"

    # Install Nacos
    echo -e "\033[32m#################### Starting Nacos installation... ####################\033[0m"
    mkdir -p $TEMP_DIR
    cd /opt/
    git clone https://github.com/nacos-group/nacos-docker.git || (cd nacos-docker && git pull)

    # Create persistence directories
    mkdir -p $NACOS_DATA_DIR $NACOS_CONF_DIR
    chmod -R 777 $NACOS_DATA_DIR $NACOS_CONF_DIR
    echo -e "\033[32m#################### Nacos persistence directories and permissions set ####################\033[0m"

    # Copy Nacos config to host
    echo -e "\033[32m#################### Copying Nacos config to host... ####################\033[0m"
    docker run --rm -d --name temp-nacos nacos/nacos-server:$NACOS_VERSION
    sleep 5
    docker cp temp-nacos:/home/nacos/conf/. $NACOS_CONF_DIR
    docker stop temp-nacos
    echo -e "\033[32m#################### Nacos config copied successfully ####################\033[0m"

    # Modify configurations
    if ! grep -q "./nacos-data:/home/nacos/data" $NACOS_DIR/example/standalone-mysql.yaml; then
        sed -i "/- \.\/standalone-logs\/:\/home\/nacos\/logs/a \      - ./nacos-data:/home/nacos/data\n      - ./nacos-conf:/home/nacos/conf" $NACOS_DIR/example/standalone-mysql.yaml
    else
        echo -e "\033[32mNacos volume mounts already configured in standalone-mysql.yaml. Skipping modification.\033[0m"
    fi
    sed -i "s/\${NACOS_VERSION}/$NACOS_VERSION/g" $NACOS_DIR/example/standalone-mysql.yaml
    sed -i "s/root/$MYSQL_ROOT_PASSWORD/g" $NACOS_DIR/env/mysql.env
    sed -i "s/MYSQL_SERVICE_PASSWORD=nacos/MYSQL_SERVICE_PASSWORD=$NACOS_MYSQL_PASSWORD/g" $NACOS_DIR/env/nacos-standalone-mysql.env
    echo -e "\033[32m#################### Nacos configurations modified ####################\033[0m"

    # Start containers
    cd $NACOS_DIR/example
    docker-compose -f standalone-mysql.yaml up -d

    # Wait for containers to be ready
    echo -e "\033[32m#################### Waiting for Nacos and MySQL containers to start... ####################\033[0m"
    for i in {1..60}; do
        if docker ps | grep -q "nacos-standalone-mysql" && docker ps | grep -q "mysql"; then
            echo -e "\033[32mContainers are up.\033[0m"
            break
        fi
        sleep 1
    done

    # Download MySQL schema
    echo -e "\033[32m#################### Downloading mysql-schema.sql... ####################\033[0m"
    cd $TEMP_DIR
    NACOS_SCHEMA_URL="https://raw.githubusercontent.com/alibaba/nacos/$NACOS_VERSION/distribution/conf/mysql-schema.sql"
    download_if_not_exists "$NACOS_SCHEMA_URL" "mysql-schema.sql"

    docker cp mysql-schema.sql mysql:/mysql-schema.sql
    echo -e "\033[32m#################### mysql-schema.sql copied to MySQL container ####################\033[0m"

    # Drop old DB, create new, and import schema
    docker exec -i mysql bash -c "
MYSQL_PWD='$MYSQL_ROOT_PASSWORD' mysql -uroot -e \"
    DROP DATABASE IF EXISTS nacos_devtest;
    CREATE DATABASE nacos_devtest DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    USE nacos_devtest;
    SOURCE /mysql-schema.sql;\"
"
    echo -e "\033[32m#################### mysql-schema.sql imported successfully ####################\033[0m"

    # Modify Nacos MySQL user password
    echo -e "\033[32m#################### Modifying Nacos MySQL user password... ####################\033[0m"
    docker exec -i mysql bash -c "
  MYSQL_PWD='$MYSQL_ROOT_PASSWORD' mysql -uroot -e \"
    ALTER USER 'nacos'@'%' IDENTIFIED BY '$NACOS_MYSQL_PASSWORD';
    FLUSH PRIVILEGES;
  \"
"
    echo -e "\033[32m#################### Nacos MySQL user password modified successfully ####################\033[0m"

    # Configure Nacos authentication
    docker exec -it nacos-standalone-mysql bash -c 'echo "
nacos.core.auth.enabled=true
nacos.core.auth.enable.userAgentAuthWhite=false
springdoc.api-docs.enabled=false
springdoc.swagger-ui.enabled=false" >> /home/nacos/conf/application.properties'
    echo -e "\033[32m#################### Nacos authentication configured ####################\033[0m"

    # Enable Prometheus metrics if specified
    if [ "$ENABLE_PROMETHEUS" = true ]; then
        echo -e "\033[32m#################### Enabling Prometheus metrics... ####################\033[0m"
        docker exec -it nacos-standalone-mysql bash -c '
        if ! grep -q "management.endpoints.web.exposure.include=" /home/nacos/conf/application.properties; then
            echo "management.endpoints.web.exposure.include=*" >> /home/nacos/conf/application.properties
        fi'
        echo -e "\033[32m#################### Prometheus metrics enabled ####################\033[0m"
    fi

    # Restart Nacos container
    docker restart nacos-standalone-mysql

    # Set up auto-start using systemd
    echo -e "\033[32m#################### Setting Nacos and MySQL to auto-start... ####################\033[0m"
    cat <<EOF > /etc/systemd/system/nacos.service
[Unit]
Description=Nacos with MySQL
After=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/docker-compose -f $NACOS_DIR/example/standalone-mysql.yaml up -d
ExecStop=/usr/bin/docker-compose -f $NACOS_DIR/example/standalone-mysql.yaml down
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nacos.service
    echo -e "\033[32m#################### Auto-start configured ####################\033[0m"

    # Clean up temporary files
    rm -rf $TEMP_DIR

    # Output completion and passwords
    echo -e "\033[32m#################### Nacos installation successful (Version: $NACOS_VERSION). Please log in to Nacos web page to set initial password. ####################\033[0m"
    if [ "$ENABLE_PROMETHEUS" = true ]; then
        echo -e "\033[32mPrometheus metrics enabled. Access at: http://<your-server-ip>:8848/nacos/actuator/prometheus\033[0m"
    fi
    echo -e "\033[32mMySQL Root Password: $MYSQL_ROOT_PASSWORD\033[0m"
    echo -e "\033[32mNacos MySQL User Password: $NACOS_MYSQL_PASSWORD\033[0m"
}

# Execute main function
main "$@"