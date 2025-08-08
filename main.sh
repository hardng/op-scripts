#!/usr/bin/env bash
#
# Runner script for hardng/op-scripts
#

GITHUB_USER="hardng"
GITHUB_REPO="op-scripts"
BRANCH="main"
SCRIPTS_PATH="scripts"
BASE_RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/${SCRIPTS_PATH}"
API_URL="https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/${SCRIPTS_PATH}?ref=${BRANCH}"

# 获取脚本列表
get_scripts() {
    curl -s "$API_URL" | grep '"name"' | grep '\.sh' | cut -d '"' -f 4 | sed 's/\.sh$//'
}

# 列出所有脚本
list_scripts() {
    echo "Available scripts:"
    get_scripts | sed 's/^/  /'
}

# runner.sh 的帮助
show_usage() {
    cat <<EOF
Usage:
  runner.sh -l | -ls | --list           List all available scripts
  runner.sh -h | --help                 Show this help
  runner.sh <script> [args...]          Run <script> with given arguments

Examples:
  runner.sh deploy prod v1.2.3
  runner.sh backup daily
  runner.sh -l
EOF
}

# 参数判断
case "$1" in
    -l|-ls|--list)
        list_scripts
        exit 0
        ;;
    -h|--help)
        show_usage
        exit 0
        ;;
    "")
        echo "Error: No script name given."
        show_usage
        exit 1
        ;;
esac

SCRIPT_NAME="$1"
shift

# 检查脚本是否存在
if ! get_scripts | grep -qx "$SCRIPT_NAME"; then
    echo "Error: Script '$SCRIPT_NAME' not found."
    echo "Use -l or --list to see available scripts."
    exit 1
fi

# 执行对应脚本
# 如果没参数，让脚本自己输出 usage 或错误
curl -sL "${BASE_RAW_URL}/${SCRIPT_NAME}.sh" | bash -s -- "$@"
