#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_TOOLKIT_DIR="${AGENT_TOOLKIT_DIR:-${SCRIPT_DIR}}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
QUEUE_DIR="${AGENT_TOOLKIT_DIR}/.queue"
COMMANDS_FILE="${QUEUE_DIR}/commands.json"
LOCK_DIR="${QUEUE_DIR}/.update-lock"
LOG_DIR="${AGENT_TOOLKIT_DIR}/logs"
UPDATE_LOG="${LOG_DIR}/public-update.log"
ENV_FILE="${PROJECT_DIR}/.env"
ENV_EXAMPLE_FILE="${PROJECT_DIR}/.env.example"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${CYAN}[INFO]${NC} ${timestamp} $*" | tee -a "${UPDATE_LOG}"
}

log_warn() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${YELLOW}[WARN]${NC} ${timestamp} $*" | tee -a "${UPDATE_LOG}"
}

log_error() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${RED}[ERROR]${NC} ${timestamp} $*" | tee -a "${UPDATE_LOG}" >&2
}

usage() {
    cat <<'EOF'
用法:
  bash public-update.sh <command_id>
EOF
}

ensure_runtime_files() {
    mkdir -p "${QUEUE_DIR}" "${LOG_DIR}"

    if [ ! -f "${COMMANDS_FILE}" ]; then
        printf '%s\n' '{"commands":[],"processing":false}' > "${COMMANDS_FILE}"
    fi
}

detect_json_backend() {
    if command -v jq >/dev/null 2>&1; then
        echo "jq"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi

    return 1
}

JSON_BACKEND="$(detect_json_backend || true)"

require_json_backend() {
    if [ -z "${JSON_BACKEND}" ]; then
        log_error "缺少 JSON 解析工具，请安装 jq 或 python3。"
        exit 1
    fi
}

json_get_command() {
    local command_id="$1"

    if [ "${JSON_BACKEND}" = "jq" ]; then
        jq -c --arg id "${command_id}" '.commands[] | select(.id == $id)' "${COMMANDS_FILE}"
        return 0
    fi

    python3 - "${COMMANDS_FILE}" "${command_id}" <<'PY'
import json
import sys

path, command_id = sys.argv[1], sys.argv[2]

try:
    with open(path, 'r', encoding='utf-8') as handle:
        data = json.load(handle)
except FileNotFoundError:
    sys.exit(1)

for command in data.get('commands', []):
    if command.get('id') == command_id:
        print(json.dumps(command, ensure_ascii=False, separators=(',', ':')))
        break
PY
}

json_read_field() {
    local json_payload="$1"
    local field_path="$2"

    if [ "${JSON_BACKEND}" = "jq" ]; then
        printf '%s' "${json_payload}" | jq -r ".${field_path} // empty"
        return 0
    fi

    python3 - "${field_path}" "${json_payload}" <<'PY'
import json
import sys

field_path = sys.argv[1].split('.')
payload = json.loads(sys.argv[2])
value = payload

for segment in field_path:
    if isinstance(value, dict) and segment in value:
        value = value[segment]
    else:
        value = None
        break

if value is None:
    sys.exit(0)

if isinstance(value, bool):
    print('true' if value else 'false')
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False, separators=(',', ':')))
else:
    print(value)
PY
}

json_read_image_field() {
    local json_payload="$1"
    local service_name="$2"

    if [ "${JSON_BACKEND}" = "jq" ]; then
        printf '%s' "${json_payload}" | jq -r --arg service "${service_name}" '.registry_context.images[$service] // empty'
        return 0
    fi

    python3 - "${service_name}" "${json_payload}" <<'PY'
import json
import sys

service_name = sys.argv[1]
payload = json.loads(sys.argv[2])
images = payload.get('registry_context', {}).get('images', {})
value = images.get(service_name)

if value is not None:
    print(value)
PY
}

json_update_command_status() {
    local command_id="$1"
    local status="$2"
    local message="$3"
    local timestamp
    local temp_file

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    temp_file="${COMMANDS_FILE}.tmp.$$"

    if [ "${JSON_BACKEND}" = "jq" ]; then
        jq \
            --arg id "${command_id}" \
            --arg status "${status}" \
            --arg message "${message}" \
            --arg timestamp "${timestamp}" \
            '
            .commands = [
                .commands[] |
                if .id == $id then
                    .status = $status
                    | .updated_at = $timestamp
                    | .status_message = $message
                    | if $status == "running" then
                        .started_at = $timestamp
                      elif $status == "completed" then
                        .completed_at = $timestamp
                        | .last_error = ""
                      elif $status == "failed" then
                        .failed_at = $timestamp
                        | .last_error = $message
                      else
                        .
                      end
                else
                    .
                end
            ]
            ' "${COMMANDS_FILE}" > "${temp_file}"
    else
        python3 - "${COMMANDS_FILE}" "${temp_file}" "${command_id}" "${status}" "${message}" "${timestamp}" <<'PY'
import json
import sys

source, target, command_id, status, message, timestamp = sys.argv[1:7]

with open(source, 'r', encoding='utf-8') as handle:
    payload = json.load(handle)

for command in payload.get('commands', []):
    if command.get('id') != command_id:
        continue
    command['status'] = status
    command['updated_at'] = timestamp
    command['status_message'] = message
    if status == 'running':
        command['started_at'] = timestamp
    elif status == 'completed':
        command['completed_at'] = timestamp
        command['last_error'] = ''
    elif status == 'failed':
        command['failed_at'] = timestamp
        command['last_error'] = message
    break

with open(target, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
PY
    fi

    mv "${temp_file}" "${COMMANDS_FILE}"
}

json_set_processing() {
    local processing="$1"
    local temp_file

    temp_file="${COMMANDS_FILE}.tmp.$$"

    if [ "${JSON_BACKEND}" = "jq" ]; then
        jq --argjson processing "${processing}" '.processing = $processing' "${COMMANDS_FILE}" > "${temp_file}"
    else
        python3 - "${COMMANDS_FILE}" "${temp_file}" "${processing}" <<'PY'
import json
import sys

source, target, processing = sys.argv[1], sys.argv[2], sys.argv[3]

with open(source, 'r', encoding='utf-8') as handle:
    payload = json.load(handle)

payload['processing'] = processing.lower() == 'true'

with open(target, 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
PY
    fi

    mv "${temp_file}" "${COMMANDS_FILE}"
}

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
        return 0
    fi

    log_error "未找到 docker compose 或 docker-compose。"
    return 1
}

sed_in_place() {
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

set_env_value() {
    local key="$1"
    local value="$2"
    local escaped_value

    escaped_value="$(printf '%s' "${value}" | sed 's/[\\/&]/\\&/g')"

    if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        sed_in_place "s|^${key}=.*|${key}=${escaped_value}|" "${ENV_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
    fi
}

validate_version() {
    local version="$1"

    if [[ "${version}" =~ ^v6\.[0-9]{8}\.[0-9]+$ ]]; then
        return 0
    fi

    if [[ "${version}" =~ ^v6\.[0-9]{8}\.[0-9]+(-(preview|rc)(\.[0-9]+)?)?$ ]]; then
        return 0
    fi

    log_error "版本号格式不正确: ${version}"
    log_error "允许格式: v6.YYYYMMDD.NNN 或 v6.YYYYMMDD.NNN-preview/rc"
    return 1
}

validate_registry_context() {
    local command_json="$1"
    local version="$2"
    local provider
    local namespace
    local requires_auth
    local service
    local image_name

    provider="$(json_read_field "${command_json}" "registry_context.registry_provider")"
    namespace="$(json_read_field "${command_json}" "registry_context.registry_namespace")"
    requires_auth="$(json_read_field "${command_json}" "registry_context.requires_auth")"

    if [ -n "${provider}" ] && [ "${provider}" != "dockerhub" ]; then
        log_error "公开版仅支持 Docker Hub，当前 provider=${provider}"
        return 1
    fi

    if [ -n "${namespace}" ] && [ "${namespace}" != "fenglianshop" ]; then
        log_error "公开版镜像命名空间必须为 fenglianshop，当前 namespace=${namespace}"
        return 1
    fi

    if [ -n "${requires_auth}" ] && [ "${requires_auth}" != "false" ]; then
        log_error "公开版不支持需要登录的镜像仓库。"
        return 1
    fi

    for service in api admin h5 nginx-api; do
        image_name="$(json_read_image_field "${command_json}" "${service}")"
        if [ -z "${image_name}" ]; then
            continue
        fi

        if [ "${image_name}" != "fenglianshop/${service}:${version}" ]; then
            log_error "镜像校验失败: ${service}=${image_name}"
            return 1
        fi
    done

    return 0
}

acquire_lock() {
    if mkdir "${LOCK_DIR}" >/dev/null 2>&1; then
        return 0
    fi

    log_warn "已有更新任务执行中，跳过本次命令。"
    return 1
}

release_lock() {
    rmdir "${LOCK_DIR}" >/dev/null 2>&1 || true
}

prepare_env_file() {
    if [ -f "${ENV_FILE}" ]; then
        return 0
    fi

    if [ ! -f "${ENV_EXAMPLE_FILE}" ]; then
        log_error ".env 不存在，且找不到 .env.example。"
        return 1
    fi

    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
    log_warn "未找到 .env，已从 .env.example 自动生成。"
}

run_deploy() {
    local version="$1"

    prepare_env_file

    set_env_value "VERSION" "${version}"
    set_env_value "APP_VERSION" "${version}"
    set_env_value "APP_EDITION" "single"
    set_env_value "DEPLOYMENT_MODE" "public_dockerhub"
    set_env_value "AGENT_TOOLKIT_DIR" "/host/public-update-toolkit"

    log_info "开始拉取 Docker Hub 镜像: ${version}"
    compose pull api admin h5 nginx-api

    log_info "开始重建四个公开版业务服务"
    compose up -d api nginx-api admin h5
}

main() {
    local command_id="${1:-}"
    local command_json
    local version
    local deployment_mode

    if [ -z "${command_id}" ]; then
        usage
        exit 1
    fi

    ensure_runtime_files
    require_json_backend

    if ! acquire_lock; then
        exit 1
    fi

    trap release_lock EXIT

    command_json="$(json_get_command "${command_id}" || true)"
    if [ -z "${command_json}" ]; then
        log_error "未找到命令: ${command_id}"
        exit 1
    fi

    version="$(json_read_field "${command_json}" "version")"
    deployment_mode="$(json_read_field "${command_json}" "deployment_mode")"

    if [ -z "${version}" ]; then
        json_update_command_status "${command_id}" "failed" "缺少目标版本号"
        exit 1
    fi

    if [ -n "${deployment_mode}" ] && [ "${deployment_mode}" != "public_dockerhub" ]; then
        json_update_command_status "${command_id}" "failed" "deployment_mode 必须为 public_dockerhub"
        exit 1
    fi

    if ! validate_version "${version}"; then
        json_update_command_status "${command_id}" "failed" "版本号格式不合法: ${version}"
        exit 1
    fi

    if ! validate_registry_context "${command_json}" "${version}"; then
        json_update_command_status "${command_id}" "failed" "镜像上下文校验失败"
        exit 1
    fi

    json_set_processing true
    json_update_command_status "${command_id}" "running" "开始执行公开版镜像更新"

    if run_deploy "${version}"; then
        json_update_command_status "${command_id}" "completed" "公开版镜像更新完成"
        json_set_processing false
        log_info "命令执行完成: ${command_id}"
        exit 0
    fi

    json_update_command_status "${command_id}" "failed" "Docker Compose 执行失败"
    json_set_processing false
    log_error "命令执行失败: ${command_id}"
    exit 1
}

main "$@"
