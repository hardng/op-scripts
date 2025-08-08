#!/bin/bash
set -e

MONGODB_VERSION="6.0.6"
MONGODB_USER="mongod"
REPLICA_SET_NAME="rs0"
PRIMARY_PORT=27017
SECONDARY_PORT=27018
ARBITER_PORT=27019

MONGO_ADMIN_USER="admin"
MONGO_ADMIN_PASS="StrongAdminPass123"
MONGO_MON_USER="monitor"
MONGO_MON_PASS="StrongMonitorPass123"

EXPORTER_VERSION="0.40.0"
EXPORTER_BASE_PORT=9216

PID_DIR="/var/run/mongodb"

usage() {
    cat <<EOF
Usage: $0 <subcommand> [options]

Subcommands:
  install         Install MongoDB (and optionally multi-instance)
  init-replica    Initialize MongoDB replica set
  config-auth     Configure replica set authentication
  init-exporter   Install and configure Prometheus MongoDB Exporter

install options:
  --data-dir <path>               MongoDB data directory
  --mongodb-version <version>     MongoDB version (default: $MONGODB_VERSION)
  --multi-instance                Enable multi-instance mode on single host

Common options:
  --role <primary|secondary|arbiter>   Node role
  --primary-ip <IP>                    Primary node IP
  --secondary-ip <IP>                  Secondary node IP
  --arbiter-ip <IP>                     Arbiter node IP
EOF
    exit 1
}

install_mongodb() {
    echo "Installing MongoDB ${MONGODB_VERSION}..."
    apt-get update -y
    apt-get install -y gnupg wget curl tar
    wget -qO - https://pgp.mongodb.com/server-${MONGODB_VERSION%%.*}.asc | gpg --dearmor | tee /usr/share/keyrings/mongodb-server-${MONGODB_VERSION%%.*}.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_VERSION%%.*}.gpg] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/${MONGODB_VERSION%%.*} multiverse" \
        | tee /etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION%%.*}.list
    apt-get update -y
    apt-get install -y mongodb-org=${MONGODB_VERSION} \
                       mongodb-org-server=${MONGODB_VERSION} \
                       mongodb-org-shell=${MONGODB_VERSION} \
                       mongodb-org-mongos=${MONGODB_VERSION} \
                       mongodb-org-tools=${MONGODB_VERSION}
}

setup_keyfile() {
    local port=$1
    local keyfile="/etc/mongod-${port}.key"
    if [[ ! -f "$keyfile" ]]; then
        echo "Creating keyFile for port ${port}..."
        openssl rand -base64 756 > "$keyfile"
    fi
    chmod 400 "$keyfile"
    chown $MONGODB_USER:$MONGODB_USER "$keyfile"
}

configure_mongodb() {
    local port=$1
    local data_dir=$2
    local config_file="/etc/mongod-${port}.conf"
    local pid_file="$PID_DIR/mongod-${port}.pid"
    local log_dir="/var/log/mongodb-${port}"
    mkdir -p "$log_dir" "$PID_DIR" "$data_dir"
    chown -R $MONGODB_USER:$MONGODB_USER "$log_dir" "$PID_DIR" "$data_dir"
    chmod 750 "$data_dir"

    setup_keyfile "$port"

    cat > "$config_file" <<EOF
storage:
  dbPath: $data_dir
systemLog:
  destination: file
  logAppend: true
  path: $log_dir/mongod.log
net:
  port: $port
  bindIp: 0.0.0.0
replication:
  replSetName: $REPLICA_SET_NAME
security:
  authorization: enabled
  keyFile: /etc/mongod-${port}.key
processManagement:
  pidFilePath: $pid_file
EOF

    cat > "/etc/systemd/system/mongod-${port}.service" <<EOF
[Unit]
Description=MongoDB Database Server on port ${port}
After=network.target

[Service]
User=${MONGODB_USER}
ExecStart=/usr/bin/mongod --config ${config_file}
PIDFile=${pid_file}
Restart=always
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "mongod-${port}"
    systemctl start "mongod-${port}"
}

init_replica_set() {
    echo "Initializing replica set..."
    mongosh --quiet --port "$PRIMARY_PORT" <<EOF
rs.initiate({
  _id: "$REPLICA_SET_NAME",
  members: [
    { _id: 0, host: "${PRIMARY_IP}:${PRIMARY_PORT}" },
    { _id: 1, host: "${SECONDARY_IP}:${SECONDARY_PORT}" },
    { _id: 2, host: "${ARBITER_IP}:${ARBITER_PORT}", arbiterOnly: true }
  ]
})
EOF
}

enable_auth() {
    local cmd=$(command -v mongosh || command -v mongo)
    echo "Waiting for PRIMARY..."
    while true; do
        local primary_addr=$($cmd --quiet --port "$PRIMARY_PORT" --eval 'rs.status().members.filter(m => m.stateStr == "PRIMARY")[0]?.name' | tr -d '"')
        [[ -n "$primary_addr" ]] && break
        sleep 2
    done

    if [[ "$primary_addr" == *":$PRIMARY_PORT" ]]; then
        echo "Current node is PRIMARY, creating users..."
        $cmd --port $PRIMARY_PORT <<EOF
use admin
if (!db.getUser("${MONGO_ADMIN_USER}")) {
    db.createUser({ user: "${MONGO_ADMIN_USER}", pwd: "${MONGO_ADMIN_PASS}", roles: [ { role: "root", db: "admin" } ] })
}
if (!db.getUser("${MONGO_MON_USER}")) {
    db.createUser({
        user: "${MONGO_MON_USER}",
        pwd: "${MONGO_MON_PASS}",
        roles: [
            { role: "clusterMonitor", db: "admin" },
            { role: "readAnyDatabase", db: "admin" },
            { role: "read", db: "local" }
        ]
    })
}
EOF
    fi

    systemctl restart "mongod-${PRIMARY_PORT}"
}

install_exporter() {
    local port=$1
    local listen_port=$2
    local dir="/opt/mongodb_exporter"
    local bin="${dir}/mongodb_exporter"

    mkdir -p "$dir"
    echo "Downloading MongoDB Exporter ${EXPORTER_VERSION}..."
    curl -L "https://github.com/percona/mongodb_exporter/releases/download/v${EXPORTER_VERSION}/mongodb_exporter-${EXPORTER_VERSION}.linux-amd64.tar.gz" \
        -o /tmp/mongodb_exporter.tar.gz
    tar -xzf /tmp/mongodb_exporter.tar.gz -C /tmp
    mv /tmp/mongodb_exporter-${EXPORTER_VERSION}.linux-amd64/mongodb_exporter "$bin"
    chmod +x "$bin"

    cat > "/etc/systemd/system/mongodb_exporter-${port}.service" <<EOF
[Unit]
Description=MongoDB Exporter on port ${listen_port}
After=network.target

[Service]
ExecStart=${bin} --mongodb.uri="mongodb://${MONGO_MON_USER}:${MONGO_MON_PASS}@localhost:${port}/admin?authSource=admin" --web.listen-address=":${listen_port}"
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "mongodb_exporter-${port}"
    systemctl start "mongodb_exporter-${port}"
}

case "$1" in
    install)
        shift
        DATA_DIR="/var/lib/mongodb"
        MULTI_INSTANCE=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --data-dir) DATA_DIR="$2"; shift ;;
                --mongodb-version) MONGODB_VERSION="$2"; shift ;;
                --multi-instance) MULTI_INSTANCE=true ;;
                *) usage ;;
            esac
            shift
        done
        install_mongodb
        if $MULTI_INSTANCE; then
            configure_mongodb "$PRIMARY_PORT" "${DATA_DIR}-${PRIMARY_PORT}"
            configure_mongodb "$SECONDARY_PORT" "${DATA_DIR}-${SECONDARY_PORT}"
            configure_mongodb "$ARBITER_PORT" "${DATA_DIR}-${ARBITER_PORT}"
        else
            configure_mongodb "$PRIMARY_PORT" "$DATA_DIR"
        fi
        ;;
    init-replica)
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --primary-ip) PRIMARY_IP="$2"; shift ;;
                --secondary-ip) SECONDARY_IP="$2"; shift ;;
                --arbiter-ip) ARBITER_IP="$2"; shift ;;
                *) usage ;;
            esac
            shift
        done
        init_replica_set
        ;;
    config-auth)
        enable_auth
        ;;
    init-exporter)
        shift
        MULTI_INSTANCE=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --multi-instance) MULTI_INSTANCE=true ;;
                *) usage ;;
            esac
            shift
        done
        if $MULTI_INSTANCE; then
            install_exporter "$PRIMARY_PORT" "$EXPORTER_BASE_PORT"
            install_exporter "$SECONDARY_PORT" "$((EXPORTER_BASE_PORT+1))"
            install_exporter "$ARBITER_PORT" "$((EXPORTER_BASE_PORT+2))"
        else
            install_exporter "$PRIMARY_PORT" "$EXPORTER_BASE_PORT"
        fi
        ;;
    *)
        usage
        ;;
esac