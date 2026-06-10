#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_TOOLKIT_DIR="${AGENT_TOOLKIT_DIR:-${SCRIPT_DIR}}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
QUEUE_DIR="${AGENT_TOOLKIT_DIR}/.queue"
LOG_DIR="${AGENT_TOOLKIT_DIR}/logs"
SERVICE_NAME="fenglianshop-public-update-daemon"
SERVICE_TEMPLATE="${SCRIPT_DIR}/public-update-daemon.service"
SERVICE_TARGET="/etc/systemd/system/${SERVICE_NAME}.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log_error "请使用 root 或 sudo 运行此脚本。"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "当前系统未安装 systemctl，无法安装守护进程。"
        exit 1
    fi

    if [ ! -d /run/systemd/system ]; then
        log_error "当前系统未启用 systemd，无法安装守护进程。"
        exit 1
    fi
}

create_runtime_layout() {
    log_info "创建公开版更新队列目录..."
    mkdir -p "${QUEUE_DIR}" "${LOG_DIR}"

    if [ ! -f "${QUEUE_DIR}/commands.json" ]; then
        printf '%s\n' '{"commands":[],"processing":false}' > "${QUEUE_DIR}/commands.json"
    fi

    : > "${QUEUE_DIR}/.trigger"
    : > "${LOG_DIR}/public-update-daemon.log"
    : > "${LOG_DIR}/public-update.log"

    chmod 2775 "${QUEUE_DIR}" "${LOG_DIR}"
    chmod 664 "${QUEUE_DIR}/commands.json" "${QUEUE_DIR}/.trigger"
    chmod 664 "${LOG_DIR}/public-update-daemon.log" "${LOG_DIR}/public-update.log"

    if chown root:33 "${QUEUE_DIR}" "${LOG_DIR}" "${QUEUE_DIR}/commands.json" "${QUEUE_DIR}/.trigger" "${LOG_DIR}/public-update-daemon.log" "${LOG_DIR}/public-update.log" 2>/dev/null; then
        log_info "已将更新目录权限绑定到 GID 33，容器内 www-data 可写。"
    else
        log_warn "无法设置 root:33，已保留当前属主。请确认容器内 www-data 组对目录有写权限。"
    fi
}

install_service_file() {
    local temp_service

    if [ ! -f "${SERVICE_TEMPLATE}" ]; then
        log_error "缺少 service 模板文件: ${SERVICE_TEMPLATE}"
        exit 1
    fi

    temp_service="$(mktemp)"
    sed \
        -e "s|__TOOLKIT_DIR__|${AGENT_TOOLKIT_DIR}|g" \
        -e "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
        "${SERVICE_TEMPLATE}" > "${temp_service}"

    cp "${temp_service}" "${SERVICE_TARGET}"
    rm -f "${temp_service}"
    chmod 644 "${SERVICE_TARGET}"

    log_info "已安装 systemd 服务文件: ${SERVICE_TARGET}"
}

enable_service() {
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}"

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "守护进程已启动并设置为开机自启。"
        return 0
    fi

    log_error "守护进程启动失败，请检查日志: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
    exit 1
}

main() {
    require_root
    check_systemd
    create_runtime_layout
    install_service_file
    enable_service

    echo ""
    echo "安装完成。"
    echo "查看状态: systemctl status ${SERVICE_NAME} --no-pager"
    echo "查看日志: journalctl -u ${SERVICE_NAME} -f"
}

main "$@"
