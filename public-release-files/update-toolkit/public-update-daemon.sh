#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_TOOLKIT_DIR="${AGENT_TOOLKIT_DIR:-${SCRIPT_DIR}}"
QUEUE_DIR="${AGENT_TOOLKIT_DIR}/.queue"
COMMANDS_FILE="${QUEUE_DIR}/commands.json"
TRIGGER_FILE="${QUEUE_DIR}/.trigger"
PID_FILE="${AGENT_TOOLKIT_DIR}/.daemon.pid"
LOG_DIR="${AGENT_TOOLKIT_DIR}/logs"
DAEMON_LOG="${LOG_DIR}/public-update-daemon.log"
UPDATE_SCRIPT="${AGENT_TOOLKIT_DIR}/public-update.sh"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${CYAN}[INFO]${NC} ${timestamp} $*" | tee -a "${DAEMON_LOG}"
}

log_warn() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${YELLOW}[WARN]${NC} ${timestamp} $*" | tee -a "${DAEMON_LOG}"
}

log_error() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${RED}[ERROR]${NC} ${timestamp} $*" | tee -a "${DAEMON_LOG}" >&2
}

ensure_runtime_files() {
    mkdir -p "${QUEUE_DIR}" "${LOG_DIR}"

    if [ ! -f "${COMMANDS_FILE}" ]; then
        printf '%s\n' '{"commands":[],"processing":false}' > "${COMMANDS_FILE}"
    fi

    if [ ! -f "${TRIGGER_FILE}" ]; then
        : > "${TRIGGER_FILE}"
    fi
}

cleanup() {
    rm -f "${PID_FILE}"
}

read_trigger_command_id() {
    tr -d '\r\n[:space:]' < "${TRIGGER_FILE}"
}

process_trigger() {
    local command_id

    if [ ! -s "${TRIGGER_FILE}" ]; then
        return 0
    fi

    command_id="$(read_trigger_command_id)"
    if [ -z "${command_id}" ]; then
        log_warn "检测到空 trigger，已清理。"
        : > "${TRIGGER_FILE}"
        return 0
    fi

    if [ ! -x "${UPDATE_SCRIPT}" ] && [ ! -f "${UPDATE_SCRIPT}" ]; then
        log_error "更新脚本不存在: ${UPDATE_SCRIPT}"
        : > "${TRIGGER_FILE}"
        return 1
    fi

    log_info "收到公开版更新命令: ${command_id}"

    if bash "${UPDATE_SCRIPT}" "${command_id}"; then
        log_info "公开版更新命令执行成功: ${command_id}"
    else
        log_error "公开版更新命令执行失败: ${command_id}"
    fi

    : > "${TRIGGER_FILE}"
    return 0
}

main() {
    ensure_runtime_files
    trap cleanup EXIT
    printf '%s\n' "$$" > "${PID_FILE}"

    log_info "公开版更新守护进程已启动"
    log_info "队列目录: ${QUEUE_DIR}"
    log_info "轮询间隔: ${POLL_INTERVAL}s"

    while true; do
        process_trigger || true
        sleep "${POLL_INTERVAL}"
    done
}

main "$@"
