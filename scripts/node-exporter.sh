#!/bin/bash
################################################################################
# Cross-platform Node Exporter Installation Script
# Supported Systems:
#   - CentOS 7 / CentOS 9
#   - Rocky Linux 9
#   - Ubuntu / Debian
#
# Usage:
#   install [version]    Install Node Exporter (default: 1.9.1)
#   uninstall            Uninstall Node Exporter
#   status               Check running status
#   help                 Display help
################################################################################

set -euo pipefail

DEFAULT_VERSION="1.9.1"
INSTALL_DIR="/usr/local/node_exporter"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/node-exporter.service"

usage() {
    cat <<EOF
Usage: $0 {install [version]|uninstall|status|help}

Commands:
  install [version]  Install Node Exporter with optional version (default: ${DEFAULT_VERSION})
  uninstall          Uninstall Node Exporter
  status             Check Node Exporter status
  help               Display this help
EOF
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ Must be run as root!"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=${VERSION_ID%%.*}
    else
        echo "❌ Unable to detect OS version"
        exit 1
    fi
}

install_deps() {
    echo "📦 Installing required dependencies..."
    case "$OS" in
        centos|rocky|almalinux|rhel)
            yum install -y curl tar systemd
            ;;
        ubuntu|debian)
            apt-get update -y
            apt-get install -y curl tar systemd
            ;;
        *)
            echo "⚠️ Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

install_node_exporter() {
    local version="${1:-$DEFAULT_VERSION}"
    local tar="node_exporter-${version}.linux-amd64.tar.gz"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${version}/${tar}"

    # Check for existing Node Exporter installation and related files in /usr/local
    local related_files
    related_files=$(find /usr/local -maxdepth 1 -type d -name "node_exporter*" 2>/dev/null)
    if [ -d "$INSTALL_DIR" ] || [ -n "$related_files" ]; then
        systemctl stop node-exporter.service || true
        rm -rf "$INSTALL_DIR"
        [ -n "$related_files" ] && rm -rf $related_files
    fi

    echo "⬇️ Downloading Node Exporter v${version}..."
    cd /tmp || exit 1
    if ! curl -fLO "$url"; then
        echo "❌ Download failed, check version or network!"
        exit 1
    fi

    tar -xvf "$tar"
    mv "node_exporter-${version}.linux-amd64" "$INSTALL_DIR"
    rm -f "$tar"

    echo "⚙️ Creating systemd service..."
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/node_exporter \\
  --collector.logind \\
  --collector.tcpstat \\
  --collector.netstat \\
  --collector.netdev \\
  --web.listen-address=:9100 \\
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc|run)($|/),^/var/lib/(docker|containerd)($|/)" \\
  --collector.systemd.unit-whitelist=(docker|kubelet|kube-proxy|flanneld).service
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now node-exporter.service
    echo "✅ Node Exporter v${version} installed successfully!"
    systemctl status node-exporter.service --no-pager
}

uninstall_node_exporter() {
    if systemctl is-active --quiet node-exporter.service; then
        systemctl stop node-exporter.service
    fi
    systemctl disable node-exporter.service || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    rm -rf "$INSTALL_DIR"
    # Clean up any other node_exporter directories in /usr/local
    find /usr/local -maxdepth 1 -type d -name "node_exporter*" -exec rm -rf {} \;
    systemctl daemon-reload
    echo "🗑 Node Exporter uninstalled"
}

status_node_exporter() {
    if systemctl list-units --type=service | grep -q node-exporter; then
        systemctl status node-exporter.service --no-pager
    else
        echo "⚠️ Node Exporter not installed"
    fi
}

main() {
    check_root
    detect_os

    case "${1:-}" in
        install)
            shift
            install_deps
            install_node_exporter "$@"
            ;;
        uninstall) uninstall_node_exporter ;;
        status) status_node_exporter ;;
        help|"") usage ;;
        *) echo "❌ Unknown argument: $1"; usage; exit 1 ;;
    esac
}

main "$@"