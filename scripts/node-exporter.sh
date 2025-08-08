#!/bin/bash
################################################################################
# 跨平台 Node Exporter 安装脚本
# 支持系统：
#   - CentOS 7 / CentOS 9
#   - Rocky Linux 9
#   - Ubuntu / Debian
#
# Usage:
#   install [version]    安装 Node Exporter（默认 1.9.1）
#   uninstall            卸载 Node Exporter
#   status               查看运行状态
#   help                 显示帮助
################################################################################

set -euo pipefail

DEFAULT_VERSION="1.9.1"
INSTALL_DIR="/usr/local/node_exporter"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/node-exporter.service"

usage() {
    cat <<EOF
Usage: $0 {install [version]|uninstall|status|help}

Commands:
  install [version]  安装 Node Exporter，版本可选（默认 ${DEFAULT_VERSION}）
  uninstall          卸载 Node Exporter
  status             查看 Node Exporter 状态
  help               显示本帮助
EOF
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 必须使用 root 用户运行！"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=${VERSION_ID%%.*}
    else
        echo "❌ 无法检测操作系统版本"
        exit 1
    fi
}

install_deps() {
    echo "📦 安装必要依赖..."
    case "$OS" in
        centos|rocky|almalinux|rhel)
            yum install -y curl tar systemd
            ;;
        ubuntu|debian)
            apt-get update -y
            apt-get install -y curl tar systemd
            ;;
        *)
            echo "⚠️ 不支持的系统: $OS"
            exit 1
            ;;
    esac
}

install_node_exporter() {
    local version="${1:-$DEFAULT_VERSION}"
    local tar="node_exporter-${version}.linux-amd64.tar.gz"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${version}/${tar}"

    if [ -d "$INSTALL_DIR" ]; then
        echo "⚠️ Node Exporter 已安装在 $INSTALL_DIR"
        read -p "是否重新安装？(y/N): " yn
        [[ "$yn" =~ ^[Yy]$ ]] || exit 0
        systemctl stop node_exporter || true
        rm -rf "$INSTALL_DIR"
    fi

    echo "⬇️ 下载 Node Exporter v${version}..."
    cd /tmp || exit 1
    if ! curl -fLO "$url"; then
        echo "❌ 下载失败，请检查版本号或网络！"
        exit 1
    fi

    tar -xvf "$tar"
    mv "node_exporter-${version}.linux-amd64" "$INSTALL_DIR"
    rm -f "$tar"

    echo "⚙️ 创建 systemd 服务..."
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
  --web.listen-address=:9110 \\
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc|run)($|/),^/var/lib/(docker|containerd)($|/)" \\
  --collector.systemd.unit-whitelist=(docker|kubelet|kube-proxy|flanneld).service
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now node_exporter
    echo "✅ Node Exporter v${version} 安装完成！"
    systemctl status node_exporter --no-pager
}

uninstall_node_exporter() {
    if systemctl is-active --quiet node_exporter; then
        systemctl stop node_exporter
    fi
    systemctl disable node_exporter || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload
    echo "🗑 Node Exporter 已卸载"
}

status_node_exporter() {
    if systemctl list-units --type=service | grep -q node_exporter; then
        systemctl status node_exporter --no-pager
    else
        echo "⚠️ Node Exporter 未安装"
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
        *) echo "❌ 未知参数: $1"; usage; exit 1 ;;
    esac
}

main "$@"