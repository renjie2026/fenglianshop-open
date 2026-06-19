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

    chmod 666 "${COMMANDS_FILE}" 2>/dev/null || true
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

load_db_config() {
    if [[ -f "${ENV_FILE}" ]]; then
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            key=$(echo "$key" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$key" || "$key" =~ ^#.* ]] && continue
            value=$(echo "$value" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            case "$key" in
                DB_DATABASE) export DB_DATABASE="${value}" ;;
                DB_USERNAME) export DB_USERNAME="${value}" ;;
                DB_PASSWORD) export DB_PASSWORD="${value}" ;;
                MYSQL_ROOT_PASSWORD) export MYSQL_ROOT_PASSWORD="${value}" ;;
            esac
        done < "${ENV_FILE}"
    fi

    local compose_project_name
    compose_project_name=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' fenglianshop-api-1 2>/dev/null || echo "fenglianshop")
    COMPOSE_PROJECT="${compose_project_name}"

    MYSQL_CONTAINER="${COMPOSE_PROJECT}-mysql-1"
    API_CONTAINER="${COMPOSE_PROJECT}-api-1"
    MYSQL_DB="${DB_DATABASE:-xinshangcheng003}"
    MYSQL_USER="root"
    MYSQL_PASS="${MYSQL_ROOT_PASSWORD:-${DB_PASSWORD:-}}"
}

load_db_config

update_task_status() {
    local task_id="$1"
    local status="$2"
    local progress="${3:-0}"
    local step="${4:-}"
    local error="${5:-}"

    if ! docker ps --format "{{.Names}}" | grep -q "^${MYSQL_CONTAINER}$"; then
        log_warn "MySQL容器未运行，跳过数据库状态更新"
        return 1
    fi

    local step_escaped="${step//\'/\'\'}"
    local error_field=""
    if [[ -n "${error}" ]]; then
        local error_escaped="${error//\'/\'\'}"
        error_field=", error_message = '${error_escaped}'"
    fi

    local completed_at=""
    if [[ "${status}" == "success" ]] || [[ "${status}" == "failed" ]]; then
        completed_at=", completed_at = NOW()"
    fi

    local sql_output
    sql_output=$(docker exec "${MYSQL_CONTAINER}" mysql --default-character-set=utf8mb4 -u"${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}" -se "
        UPDATE update_tasks
        SET status = '${status}',
            progress = ${progress},
            current_step = '${step_escaped}'
            ${error_field}
            ${completed_at},
            updated_at = NOW()
        WHERE id = '${task_id}';
    " 2>&1)
    local sql_result=$?

    if [[ ${sql_result} -ne 0 ]]; then
        log_error "数据库状态更新失败 (exit: ${sql_result}): ${sql_output}"
        return 1
    fi

    log_info "任务状态已更新: ${task_id} -> ${status} (${progress}%) ${step}"
    return 0
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

    for service in api admin h5 nginx-api mp-upload-worker; do
        image_name="$(json_read_image_field "${command_json}" "${service}")"
        if [ -z "${image_name}" ]; then
            # mp-upload-worker 是阶段2新增服务，旧版下发JSON可能不含，跳过校验
            if [ "${service}" = "mp-upload-worker" ]; then
                continue
            fi
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
    local task_id="$2"

    update_task_status "${task_id}" "running" 5 "准备更新环境配置"

    prepare_env_file

    local current_app_key
    current_app_key=$(grep "^APP_KEY=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2- || true)
    if [[ -z "${current_app_key}" ]]; then
        local container_app_key
        container_app_key=$(docker exec "${API_CONTAINER}" sh -c "grep '^APP_KEY=' /var/www/html/.env 2>/dev/null | cut -d'=' -f2-" 2>/dev/null || true)
        if [[ -n "${container_app_key}" ]]; then
            set_env_value "APP_KEY" "${container_app_key}"
            log_info "已从容器同步 APP_KEY 到 .env: ${container_app_key}"
        fi
    fi

    set_env_value "VERSION" "${version}"
    set_env_value "APP_VERSION" "${version}"
    set_env_value "APP_EDITION" "single"
    set_env_value "DEPLOYMENT_MODE" "public_dockerhub"
    set_env_value "AGENT_TOOLKIT_DIR" "/host/public-update-toolkit"

    update_task_status "${task_id}" "running" 10 "开始拉取 Docker Hub 镜像 ${version}，请耐心等待..."

    log_info "开始拉取 Docker Hub 镜像: ${version}"

    set +e
    compose pull api admin h5 nginx-api caddy mp-upload-worker
    local pull_exit=$?
    set -e

    if [[ ${pull_exit} -ne 0 ]]; then
        log_warn "compose pull 失败(exit=${pull_exit})，开始串行重试拉取镜像..."
        log_warn "（常见原因：刚推送的镜像在 Docker Hub CDN 同步中，稍等即可）"
        local max_retries=3
        local retry_delay=30
        local images=(
            "fenglianshop/api:${version}"
            "fenglianshop/admin:${version}"
            "fenglianshop/h5:${version}"
            "fenglianshop/nginx-api:${version}"
            "fenglianshop/caddy:${version}"
            "fenglianshop/mp-upload-worker:${version}"
        )

        local pull_failed_images=()
        # 串行重试：每个镜像独立重试，失败则等待 retry_delay 秒后再试
        # 修复原bug：原代码并行拉取且 break 提前退出循环，导致重试无效
        # 🔴 不用 | tail 管道（会把 docker pull 的实时进度缓冲到结束才显示）
        for image in "${images[@]}"; do
            local success=false
            for ((n=1; n<=max_retries; n++)); do
                log_info "拉取镜像: ${image} (第 ${n}/${max_retries} 次)"
                set +e
                timeout 600 docker pull "${image}"
                local pull_code=$?
                set -e
                if [ ${pull_code} -eq 0 ]; then
                    success=true
                    break
                fi
                if [ $n -lt $max_retries ]; then
                    log_warn "  拉取失败，${retry_delay}秒后重试..."
                    sleep $retry_delay
                fi
            done
            if [ "${success}" != "true" ]; then
                log_error "镜像拉取失败: ${image}（已重试 ${max_retries} 次）"
                pull_failed_images+=("${image}")
            fi
        done

        if [[ ${#pull_failed_images[@]} -gt 0 ]]; then
            update_task_status "${task_id}" "failed" 20 "镜像拉取失败" "失败镜像: ${pull_failed_images[*]}"
            return 1
        fi
    fi

    log_info "所有镜像拉取完成"
    update_task_status "${task_id}" "running" 40 "镜像拉取完成，准备重启容器"

    log_info "开始重建公开版业务服务（含 mp-upload-worker）"
    update_task_status "${task_id}" "running" 50 "重启容器服务"

    set +e
    compose up -d api nginx-api admin h5 caddy mp-upload-worker
    local up_exit=$?
    set -e

    if [[ ${up_exit} -ne 0 ]]; then
        update_task_status "${task_id}" "failed" 50 "容器重启失败" "Docker Compose up 执行失败"
        return 1
    fi

    update_task_status "${task_id}" "running" 60 "容器已重启，等待服务就绪"

    log_info "等待 API 容器就绪..."
    local wait_seconds=0
    local max_wait_seconds=120
    local api_ready=false

    while [[ ${wait_seconds} -lt ${max_wait_seconds} ]]; do
        if docker ps --format '{{.Names}}' | grep -q "^${API_CONTAINER}$"; then
            local health_status
            health_status=$(docker inspect --format='{{.State.Health.Status}}' "${API_CONTAINER}" 2>/dev/null || true)
            if [[ "${health_status}" == "healthy" ]]; then
                log_info "API 容器已健康"
                api_ready=true
                break
            elif [[ "${health_status}" == "starting" ]]; then
                log_info "API 容器正在启动... (${wait_seconds}s/${max_wait_seconds}s)"
            elif [[ -z "${health_status}" || "${health_status}" == "none" ]]; then
                if docker exec "${API_CONTAINER}" pgrep php-fpm > /dev/null 2>&1; then
                    log_info "API 容器 PHP-FPM 进程已就绪"
                    api_ready=true
                    break
                fi
            fi
        fi
        sleep 2
        wait_seconds=$((wait_seconds + 2))
    done

    if [[ "${api_ready}" == "true" ]]; then
        log_info "API 服务已就绪 (${wait_seconds}秒)"
        sleep 3

        log_info "清空 OPcache..."
        docker exec "${API_CONTAINER}" sh -c "kill -USR2 \$(pgrep -o php-fpm)" 2>/dev/null && log_info "PHP-FPM 已重载，OPcache 已清空" || log_warn "OPcache 清空失败，如遇500错误请手动重启容器"

        # mp-upload-worker 受限 DB 账号创建/更新（API migrate 完成后调用，确保目标表已存在）
        log_info "配置 mp-upload-worker 受限 DB 账号..."
        ensure_mp_worker_db_account
    else
        log_warn "API 服务启动超时 (${wait_seconds}秒)，继续执行..."
    fi

    update_task_status "${task_id}" "running" 80 "执行健康检查"

    log_info "执行健康检查..."
    local services=("mysql" "redis" "api" "nginx-api" "admin" "h5" "caddy" "mp-upload-worker")
    local all_healthy=true

    for service in "${services[@]}"; do
        local container_name="${COMPOSE_PROJECT}-${service}-1"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            local health_status
            health_status=$(docker inspect --format='{{.State.Health.Status}}' "${container_name}" 2>/dev/null || true)
            if [[ "${health_status}" == "healthy" || -z "${health_status}" ]]; then
                log_info "服务 ${service} 健康"
            else
                log_warn "服务 ${service} 状态: ${health_status}"
                all_healthy=false
            fi
        else
            log_warn "服务 ${service} 容器未运行"
            all_healthy=false
        fi
    done

    if [[ "${all_healthy}" == "false" ]]; then
        update_task_status "${task_id}" "failed" 80 "健康检查失败" "部分服务健康检查未通过"
        return 1
    fi

    update_task_status "${task_id}" "running" 90 "清除Laravel配置缓存"

    log_info "清除Laravel配置缓存..."
    if docker ps --format "{{.Names}}" | grep -q "^${API_CONTAINER}$"; then
        docker exec "${API_CONTAINER}" sh -c "if [ -f /var/www/html/.env ]; then sed -i '/^APP_VERSION=/d' /var/www/html/.env; fi" 2>&1 || true
        docker exec "${API_CONTAINER}" sh -c "cd /var/www/html && php artisan config:clear" 2>&1 || true
        log_info "Laravel配置缓存已清除"
    fi

    update_task_status "${task_id}" "running" 95 "更新握手数据"

    log_info "更新握手数据中的版本号..."
    docker exec "${MYSQL_CONTAINER}" mysql --default-character-set=utf8mb4 -u"${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}" -e "
        UPDATE mall_settings
        SET \`value\` = JSON_SET(\`value\`, '$.client_version', '${version}'),
                    \`value\` = JSON_SET(\`value\`, '$.updated_at', NOW())
        WHERE \`key\` = 'update_mgmt_handshake'
    " 2>/dev/null || log_warn "握手数据更新失败（不影响升级结果）"

    update_task_status "${task_id}" "success" 100 "更新完成"

    log_info "清理旧镜像..."
    local image_types=("api" "admin" "h5" "nginx-api" "mp-upload-worker")
    for image_type in "${image_types[@]}"; do
        local image_prefix="fenglianshop/${image_type}"
        local all_tags
        all_tags=$(docker images --format "{{.Tag}}" "${image_prefix}" 2>/dev/null | sort -r || true)
        local tag_count=$(echo "${all_tags}" | wc -l | tr -d ' ')
        if [[ ${tag_count} -gt 2 ]]; then
            local delete_count=$((tag_count - 2))
            echo "${all_tags}" | tail -n ${delete_count} | while read -r tag; do
                local full_image="${image_prefix}:${tag}"
                local in_use=$(docker ps -a --format '{{.Image}}' 2>/dev/null | grep -c "^${full_image}$" || echo "0")
                if [[ ${in_use} -eq 0 ]]; then
                    docker rmi "${full_image}" 2>/dev/null || true
                fi
            done
        fi
    done

    log_info "版本更新完成: ${version}"
}

# ============================================
# 创建 mp-upload-worker 受限 DB 账号
# 必须在 api migrate 完成后调用（否则 GRANT 目标表不存在）
# 复用 .env 的 MYSQL_ROOT_PASSWORD 执行 GRANT，密码写入 .env 的 MP_WORKER_DB_PASSWORD
# ============================================
ensure_mp_worker_db_account() {
    local mysql_container="${COMPOSE_PROJECT}-mysql-1"
    # 兼容两种容器名格式（COMPOSE_PROJECT-name-1 或 COMPOSE_PROJECT_name）
    if ! docker ps --format '{{.Names}}' | grep -q "^${mysql_container}$"; then
        mysql_container="${COMPOSE_PROJECT}_mysql_1"
        if ! docker ps --format '{{.Names}}' | grep -q "^${mysql_container}$"; then
            # 再尝试无后缀格式
            mysql_container="${COMPOSE_PROJECT}_mysql"
            if ! docker ps --format '{{.Names}}' | grep -q "^${mysql_container}$"; then
                log_warn "MySQL 容器未找到，跳过 mp_worker 账号创建"
                return 0
            fi
        fi
    fi

    local db_name
    db_name=$(grep "^DB_DATABASE=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    db_name="${db_name:-xinshangcheng003}"

    local root_pass
    root_pass=$(grep "^MYSQL_ROOT_PASSWORD=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2-)
    if [[ -z "${root_pass}" ]]; then
        log_warn "MYSQL_ROOT_PASSWORD 未配置，跳过 mp_worker 账号创建"
        return 0
    fi

    # 密码优先读 .env，不存在则随机生成并回写（仅首次）
    local worker_pass
    worker_pass=$(grep "^MP_WORKER_DB_PASSWORD=" "${ENV_FILE}" 2>/dev/null | cut -d'=' -f2-)
    if [[ -z "${worker_pass}" ]]; then
        # 仅 [A-Za-z0-9]，杜绝特殊字符导致 SQL 注入
        worker_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)
        set_env_value "MP_WORKER_DB_PASSWORD" "${worker_pass}"
        log_info "已生成 mp_worker 密码并写入 .env"
    fi

    log_info "创建/更新受限 DB 账号 mp_worker（仅授权小程序上传相关表）..."

    # 🔴 不能用 heredoc + 管道 + grep（set -euo pipefail 下 grep 不匹配会终止脚本）
    # 改用：先执行 SQL（set +e 保护），再单独验证账号登录
    set +e
    docker exec "${mysql_container}" mysql -uroot -p"${root_pass}" --default-character-set=utf8mb4 -e "
CREATE USER IF NOT EXISTS 'mp_worker'@'%' IDENTIFIED BY '${worker_pass}';
ALTER USER 'mp_worker'@'%' IDENTIFIED BY '${worker_pass}';
GRANT SELECT, INSERT, UPDATE ON ${db_name}.miniprogram_ci_keys TO 'mp_worker'@'%';
GRANT SELECT, INSERT, UPDATE ON ${db_name}.miniprogram_upload_history TO 'mp_worker'@'%';
GRANT SELECT, INSERT ON ${db_name}.app_notification_logs TO 'mp_worker'@'%';
FLUSH PRIVILEGES;
" 2>&1 | grep -v "Using a password" || true
    set -e

    # 验证 mp_worker 账号能否实际登录
    set +e
    docker exec "${mysql_container}" mysql -ump_worker -p"${worker_pass}" -e "SELECT 1 AS login_test;" 2>/dev/null
    local login_test=$?
    set -e

    if [ $login_test -eq 0 ]; then
        log_info "mp_worker 账号创建成功，且可正常登录"
    else
        log_warn "mp_worker 账号创建/登录失败（退出码=${login_test}）"
        log_warn "排查：docker exec ${mysql_container} mysql -uroot -p'***' -e 'SELECT user FROM mysql.user WHERE user=\"mp_worker\";'"
        log_warn "（此警告不阻塞部署）"
    fi
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
    update_task_status "${command_id}" "running" 0 "开始执行公开版镜像更新"

    if run_deploy "${version}" "${command_id}"; then
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
