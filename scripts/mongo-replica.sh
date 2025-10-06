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
MONGODB_USER="mongo"
MONGO_ADMIN_USER="admin"
MONGO_ADMIN_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9')"
MONGO_MON_USER="exporter"
MONGO_MON_PASS="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9')"
PRIMARY_IP="127.0.0.1"  # Default to localhost for single host
SECONDARY_IP="127.0.0.1"
ARBITER_IP="127.0.0.1"
PID_DIR="/data/mongodb"
PID_FILE="$PID_DIR/mongod.pid"
MULTI_INSTANCE=false  # New flag to enable multi-instance on single host
INSTANCE_NAME=""      # Instance-specific name for multi-instance mode
STANDALONE=false      # New flag for standalone mode (no replica set)
STANDALONE_PORT=27017 # Default port for standalone mode

usage() {
    echo "使用方法: $0 <子命令> [选项]"
    echo ""
    echo "子命令:"
    echo "  install        安装 MongoDB 和 Prometheus 导出器"
    echo "  init-replica   初始化 MongoDB 副本集"
    echo "  config-auth    配置副本集认证"
    echo "  init-exporter  在此节点上配置 Prometheus 导出器"
    echo ""
    echo "install 选项:"
    echo "  --data-dir <路径>                   数据目录路径"
    echo "  --mongodb-version <版本>            MongoDB 版本 (默认: $MONGODB_VERSION)"
    echo "  --multi-instance                    启用单主机多实例模式"
    echo "  --standalone                        部署单节点模式 (无副本集)"
    echo "  --port <端口>                       单节点模式的端口 (默认: $STANDALONE_PORT)"
    echo ""
    echo "init-replica、config-auth 和 install 的选项:"
    echo "  --role <primary|secondary|arbiter>  指定节点角色 (单节点模式不需要)"
    echo "  --data-dir <路径>                   数据目录路径"
    echo "  --primary-ip <IP>                   主节点 IP (默认: $PRIMARY_IP)"
    echo "  --secondary-ip <IP>                 从节点 IP (默认: $SECONDARY_IP)"
    echo "  --arbiter-ip <IP>                   仲裁节点 IP (默认: $ARBITER_IP)"
    echo ""
    echo "示例:"
    echo "  # 部署单节点 MongoDB"
    echo "  $0 install --standalone --data-dir /data/mongodb"
    echo ""
    echo "  # 部署副本集主节点"
    echo "  $0 install --role primary --data-dir /data/mongodb --primary-ip 192.168.1.10 --secondary-ip 192.168.1.11 --arbiter-ip 192.168.1.12"
    exit 1
}

check_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    else
        echo "错误: 不支持的操作系统"
        exit 1
    fi
}

create_mongodb_user() {
    if ! id "$MONGODB_USER" >/dev/null 2>&1; then
        echo "创建 MongoDB 用户..."
        if [[ "$OS" == "debian" ]]; then
            useradd -r -s /bin/false -M "$MONGODB_USER"
        else
            useradd -r -s /sbin/nologin -M "$MONGODB_USER"
        fi
    fi
}

install_mongodb() {
    echo "安装 MongoDB..."
    if [[ "$OS" == "debian" ]]; then
        apt-get update
        apt-get install -y gnupg wget
        wget -qO - https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc | apt-key add -
        echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/debian $(lsb_release -sc)/mongodb-org/${MONGODB_VERSION} main" \
            > /etc/apt/sources.list.d/mongodb-org.list
        apt-get update
        apt-get install -y mongodb-org=${MONGODB_VERSION}*
    else
        cat > /etc/yum.repos.d/mongodb-org.repo <<EOF
[mongodb-org-${MONGODB_VERSION}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/${MONGODB_VERSION}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc
EOF
        LATEST_MONGO_VERSION=$(yum --showduplicates list mongodb-org | grep "${MONGODB_VERSION}" | tail -n 1 | awk '{print $2}' | cut -d'-' -f1)
        PACKAGELIST=(mongodb-org-${LATEST_MONGO_VERSION} mongodb-org-database-${LATEST_MONGO_VERSION} mongodb-org-server-${LATEST_MONGO_VERSION} mongodb-org-mongos-${LATEST_MONGO_VERSION} mongodb-org-tools-${LATEST_MONGO_VERSION})
        for n in ${PACKAGELIST[@]}
        do
          rpm -q ${n} | grep -q "${n}" && yum install -y ${n}
        done
        LATEST_MONGOSHELL_VERSION=$(yum --showduplicates list mongodb-mongosh | grep "${MONGODB_VERSION}" | tail -n 1 | awk '{print $2}' | cut -d'-' -f1)
        rpm -q mongodb-mongosh-${LATEST_MONGOSHELL_VERSION} | grep -q "mongodb-mongosh" && yum install -y mongodb-mongosh-${LATEST_MONGOSHELL_VERSION}
    fi
}

install_exporter() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --primary-ip) PRIMARY_IP="$2"; shift ;;
            --secondary-ip) SECONDARY_IP="$2"; shift ;;
            *) echo "未知选项: $1"; usage ;;
        esac
        shift
    done
    if [[ -z "$PRIMARY_IP" || -z "$SECONDARY_IP" ]]; then
        echo "错误: init-exporter 需要 --primary-ip 和 --secondary-ip"
        usage
    fi

    echo "安装 MongoDB 导出器..."
    mkdir -p /tmp/mongodb_exporter
    cd /tmp/mongodb_exporter
    VERSION="0.44.0"
    wget -q https://github.com/percona/mongodb_exporter/releases/download/v$VERSION/mongodb_exporter-$VERSION.linux-amd64.tar.gz
    tar -xzf mongodb_exporter-$VERSION.linux-amd64.tar.gz --strip-components=1
    chown -R ${MONGODB_USER}:${MONGODB_USER} /tmp/mongodb_exporter
    mv -n /tmp/mongodb_exporter /usr/share/
    configure_exporter_systemd
    echo "MongoDB 导出器安装完成。"
}

configure_mongodb() {
    echo "配置 MongoDB..."
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
    echo "为 MongoDB 设置 systemd..."
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
        echo "单节点模式，跳过 keyFile 创建..."
        return
    fi
    
    if [[ ! -f /etc/mongod.key ]]; then
        echo "创建 MongoDB keyFile..."
        openssl rand -base64 756 > /etc/mongod.key
    fi
    chmod 400 /etc/mongod.key
    chown $MONGODB_USER:$MONGODB_USER /etc/mongod.key
}

init_replica_set() {
    if [[ "$ROLE" == "primary" ]]; then
        echo "初始化副本集..."
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
    echo "配置单节点认证..."
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
    
    echo "重启 MongoDB 服务以启用认证..."
    systemctl restart "$service_name"
    echo "单节点认证配置完成。"
}

enable_auth() {
    # For standalone mode, use simpler auth setup
    if [[ "$STANDALONE" == "true" ]]; then
        enable_auth_standalone
        return
    fi
    
    CMD=$(command -v mongosh || command -v mongo)

    echo "等待副本集选举主节点..."

    PRIMARY_ADDR=""
    while true; do
        PRIMARY_ADDR=$($CMD --quiet --port "$PRIMARY_PORT" --eval 'rs.status().members.filter(m => m.stateStr == "PRIMARY")[0]?.name' | tr -d '"')
        if [[ -n "$PRIMARY_ADDR" ]]; then
            echo "主节点已选举: $PRIMARY_ADDR"
            break
        else
            echo "等待主节点选举..."
            sleep 2
        fi
    done

    LOCAL_ADDR=$(hostname -i 2>/dev/null | awk '{print $1}')
    if [[ -z "$LOCAL_ADDR" ]]; then
        LOCAL_ADDR=$(hostname)
    fi

    echo "本地地址: $LOCAL_ADDR"

    if echo "$PRIMARY_ADDR" | grep -q "^$LOCAL_ADDR:"; then
        echo "✅ 当前节点是主节点，正在创建管理员用户..."
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
        echo "⚠️ 当前节点不是主节点（主节点是 $PRIMARY_ADDR），跳过创建用户..."
    fi

    # Restart service after enabling auth
    local service_name="mongod"
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        service_name="mongod-${INSTANCE_NAME}"
    fi
    systemctl restart "$service_name"
}

configure_exporter_systemd() {
    echo "配置导出器服务..."
    local exporter_port=$PROMETHEUS_EXPORTER_PORT
    local service_name="mongodb-exporter"
    local mongodb_uri=""
    
    if [[ "$MULTI_INSTANCE" == "true" ]]; then
        exporter_port=$((PROMETHEUS_EXPORTER_PORT + $(echo "$INSTANCE_NAME" | grep -o '[0-9]*') ))
        service_name="mongodb-exporter-${INSTANCE_NAME}"
    fi
    
    # Different URI for standalone vs replica set
    if [[ "$STANDALONE" == "true" ]]; then
        mongodb_uri="mongodb://${MONGO_MON_USER}:${MONGO_MON_PASS}@127.0.0.1:${PORT}/admin"
    else
        mongodb_uri="mongodb://${MONGO_MON_USER}:${MONGO_MON_PASS}@${PRIMARY_IP}:${PRIMARY_PORT},${SECONDARY_IP}:${SECONDARY_PORT}/admin?replicaSet=${REPLICA_SET_NAME}"
    fi
    
    cat > /etc/systemd/system/${service_name}.service <<EOF
[Unit]
Description=MongoDB Exporter
After=network.target
[Service]
User=${MONGODB_USER}
Group=${MONGODB_USER}
ExecStart=/usr/share/mongodb_exporter/mongodb_exporter \\
  --mongodb.uri="${mongodb_uri}" \\
  --web.listen-address=":${exporter_port}" \\
  --no-mongodb.direct-connect \\
  --collector.replicasetstatus=true \\
  --collector.dbstatsfreestorage=true \\
  --collector.shards=true \\
  --collector.currentopmetrics=true \\
  --collector.topmetrics=true \\
  --collector.diagnosticdata=true \\
  --collector.dbstats=true \\
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
            *) echo "未知选项: $1"; usage ;;
        esac
        shift
    done
    
    # Validate parameters
    if [[ -z "$DATA_DIR" ]]; then
        echo "错误: install 需要 --data-dir"
        usage
    fi
    
    # Standalone and replica set are mutually exclusive
    if [[ "$STANDALONE" == "true" ]]; then
        if [[ -n "$ROLE" ]]; then
            echo "警告: 单节点模式不需要 --role 参数，忽略..."
        fi
        PORT=$STANDALONE_PORT
        ROLE="standalone"
        echo "部署单节点 MongoDB，端口: $PORT"
    else
        if [[ -z "$ROLE" ]]; then
            echo "错误: 副本集模式需要 --role 参数"
            usage
        fi
        if [[ "$ROLE" != "primary" && "$ROLE" != "secondary" && "$ROLE" != "arbiter" ]]; then
            echo "错误: 角色必须是 'primary'、'secondary' 或 'arbiter'"
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
        echo "单节点 MongoDB 安装完成，端口: $PORT"
        echo "管理员用户: ${MONGO_ADMIN_USER}"
        echo "管理员密码: ${MONGO_ADMIN_PASS}"
        echo "Prometheus 导出器端口: $PROMETHEUS_EXPORTER_PORT"
    else
        echo "MongoDB 安装完成，节点角色: $ROLE。"
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
            *) echo "未知选项: $1"; usage ;;
        esac
        shift
    done
    if [[ -z "$ROLE" || -z "$PRIMARY_IP" || -z "$SECONDARY_IP" || -z "$ARBITER_IP" ]]; then
        echo "错误: init-replica 需要 --role、--primary-ip、--secondary-ip 和 --arbiter-ip"
        usage
    fi
    if [[ "$ROLE" != "primary" && "$ROLE" != "secondary" && "$ROLE" != "arbiter" ]]; then
        echo "错误: 角色必须是 'primary'、'secondary' 或 'arbiter'"
        exit 1
    fi
    case $ROLE in
        primary) PORT=$PRIMARY_PORT; INSTANCE_NAME="primary" ;;
        secondary) PORT=$SECONDARY_PORT; INSTANCE_NAME="secondary" ;;
        arbiter) PORT=$ARBITER_PORT; INSTANCE_NAME="arbiter" ;;
    esac
    init_replica_set
    echo "副本集初始化完成，节点角色: $ROLE。"
}

config_auth() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --role) ROLE="$2"; shift ;;
            --primary-ip) PRIMARY_IP="$2"; shift ;;
            --secondary-ip) SECONDARY_IP="$2"; shift ;;
            --multi-instance) MULTI_INSTANCE=true ;;
            *) echo "未知选项: $1"; usage ;;
        esac
        shift
    done
    if [[ -z "$ROLE" || -z "$PRIMARY_IP" || -z "$SECONDARY_IP" ]]; then
        echo "错误: config-auth 需要 --role、--primary-ip 和 --secondary-ip"
        usage
    fi
    if [[ "$ROLE" != "primary" && "$ROLE" != "secondary" && "$ROLE" != "arbiter" ]]; then
        echo "错误: 角色必须是 'primary'、'secondary' 或 'arbiter'"
        exit 1
    fi
    case $ROLE in
        primary) PORT=$PRIMARY_PORT; INSTANCE_NAME="primary" ;;
        secondary) PORT=$SECONDARY_PORT; INSTANCE_NAME="secondary" ;;
        arbiter) PORT=$ARBITER_PORT; INSTANCE_NAME="arbiter" ;;
    esac
    enable_auth
    configure_exporter_systemd
    echo "认证配置完成，节点角色: $ROLE。导出器运行在端口 $PROMETHEUS_EXPORTER_PORT。"
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
        init-exporter)
            install_exporter "$@"
            ;;
        *)
            echo "未知子命令: $SUBCOMMAND"
            usage
            ;;
    esac
}

main "$@"