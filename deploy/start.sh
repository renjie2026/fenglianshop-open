#!/usr/bin/env bash
# ============================================================
#  蜂链商城 - 一键部署脚本
#  适用版本: 单开版 (single)
# ============================================================
set -euo pipefail

# ----- 颜色定义 -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

sed_in_place() {
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

get_env() {
    grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo ""
}

set_env_val() {
    local key="$1"
    local value="$2"
    local escaped_value

    escaped_value=$(printf '%s' "$value" | sed 's/[\\/&]/\\&/g')
    if grep -q "^${key}=" .env 2>/dev/null; then
        sed_in_place "s|^${key}=.*|${key}=${escaped_value}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
        return 0
    fi

    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

generate_public_version() {
    printf 'v6.%s.001' "$(date '+%Y%m%d')"
}

GENERATED_DB_PASSWORD=""
GENERATED_ROOT_PASSWORD=""
GENERATED_REDIS_PASSWORD=""
GENERATED_VERSION=""

ensure_bootstrap_env_values() {
    local current_db_password
    local current_root_password
    local current_redis_password
    local current_version

    current_db_password=$(get_env "DB_PASSWORD")
    current_root_password=$(get_env "MYSQL_ROOT_PASSWORD")
    current_redis_password=$(get_env "REDIS_PASSWORD")
    current_version=$(get_env "VERSION")

    if [ "$current_db_password" = "CHANGE_ME_ON_FIRST_RUN" ] || [ -z "$current_db_password" ]; then
        GENERATED_DB_PASSWORD=$(generate_secret)
        set_env_val "DB_PASSWORD" "$GENERATED_DB_PASSWORD"
    fi

    if [ "$current_root_password" = "CHANGE_ME_ON_FIRST_RUN" ] || [ -z "$current_root_password" ]; then
        GENERATED_ROOT_PASSWORD=$(generate_secret)
        set_env_val "MYSQL_ROOT_PASSWORD" "$GENERATED_ROOT_PASSWORD"
    fi

    if [ -z "$current_redis_password" ]; then
        GENERATED_REDIS_PASSWORD="redis123123"
        set_env_val "REDIS_PASSWORD" "$GENERATED_REDIS_PASSWORD"
    fi

    if [ -z "$current_version" ]; then
        GENERATED_VERSION=$(generate_public_version)
        current_version="$GENERATED_VERSION"
        set_env_val "VERSION" "$current_version"
    fi

    set_env_val "APP_VERSION" "$current_version"
    set_env_val "APP_EDITION" "single"
    set_env_val "DEPLOYMENT_MODE" "public_dockerhub"
    set_env_val "AGENT_TOOLKIT_DIR" "/host/public-update-toolkit"
}

print_generated_secrets() {
    if [ -z "$GENERATED_DB_PASSWORD$GENERATED_ROOT_PASSWORD$GENERATED_REDIS_PASSWORD$GENERATED_VERSION" ]; then
        return 0
    fi

    echo ""
    echo "============================================"
    echo "  以下信息已自动生成（仅显示一次）"
    echo "============================================"
    [ -n "$GENERATED_VERSION" ] && echo "  VERSION             = ${GENERATED_VERSION}"
    [ -n "$GENERATED_DB_PASSWORD" ] && echo "  DB_PASSWORD         = ${GENERATED_DB_PASSWORD}"
    [ -n "$GENERATED_ROOT_PASSWORD" ] && echo "  MYSQL_ROOT_PASSWORD = ${GENERATED_ROOT_PASSWORD}"
    [ -n "$GENERATED_REDIS_PASSWORD" ] && echo "  REDIS_PASSWORD      = ${GENERATED_REDIS_PASSWORD}"
    echo "============================================"
    echo ""
}

print_public_update_daemon_hint() {
    echo ""
    echo "  公开版后台自动更新守护进程安装命令:"
    echo "    sudo bash ./update-toolkit/install-public-update-daemon.sh"
    echo ""
}

maybe_install_public_update_daemon() {
    local install_script="./update-toolkit/install-public-update-daemon.sh"
    local confirm_install

    if [ ! -f "$install_script" ]; then
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        print_public_update_daemon_hint
        return 0
    fi

    if [ "${EUID}" -ne 0 ]; then
        print_public_update_daemon_hint
        return 0
    fi

    read -rp "是否现在安装公开版自动更新守护进程？(y/N): " confirm_install
    if [ "$confirm_install" = "y" ] || [ "$confirm_install" = "Y" ]; then
        bash "$install_script"
    else
        print_public_update_daemon_hint
    fi
}

maybe_run_bt_proxy_fix() {
    local fix_script="./fix-bt-proxy-pass.sh"
    local confirm_fix

    if [ ! -f "$fix_script" ]; then
        return 0
    fi

    echo ""
    info "检测到宝塔反代优化修复脚本，可自动修复以下问题："
    info "  - 去除 proxy_pass 末尾多余的 /"
    info "  - 修正 Host 头为 \$host（使Caddy按域名路由）"
    info "  - 添加 X-Forwarded-Proto 请求头（使后端识别HTTPS）"
    echo ""
    read -rp "是否执行宝塔反代优化修复脚本？(y/N): " confirm_fix
    if [ "$confirm_fix" = "y" ] || [ "$confirm_fix" = "Y" ]; then
        bash "$fix_script"
    else
        echo ""
        echo "  稍后可手动执行: bash fix-bt-proxy-pass.sh"
        echo "  预览模式（不修改）: bash fix-bt-proxy-pass.sh --dry-run"
        echo ""
    fi
}

# ----- 1. 检查 .env 文件 -----
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        ensure_bootstrap_env_values
        warn ".env 文件不存在，已从 .env.example 复制。"
        print_generated_secrets
        warn "请先编辑 .env 配置域名等信息，然后重新运行此脚本。"
        echo ""
        echo "  vim .env"
        echo "  bash start.sh"
        echo ""
        exit 0
    else
        error ".env.example 文件不存在，无法初始化配置。"
        exit 1
    fi
fi

ensure_bootstrap_env_values
print_generated_secrets

# ----- 2. 从 .env 读取配置 -----
ADMIN_URL=$(get_env ADMIN_URL)
H5_URL=$(get_env H5_URL)
API_URL=$(get_env API_URL)
HTTP_PORT=$(get_env HTTP_PORT)
DB_PASSWORD=$(get_env DB_PASSWORD)
MYSQL_ROOT_PASSWORD=$(get_env MYSQL_ROOT_PASSWORD)
CADDY_IMAGE_VAL=$(get_env CADDY_IMAGE)

# 默认端口
HTTP_PORT=${HTTP_PORT:-8880}

# ----- 3. 域名校验 -----
DOMAIN_REGEX='^[a-zA-Z0-9.-]+$'

extract_domain() {
    echo "$1" | sed 's|https\?://||' | cut -d'/' -f1 | cut -d':' -f1
}

validate_domain() {
    local url="$1"
    local name="$2"
    if [ -z "$url" ]; then
        error "${name} 未配置，请编辑 .env 文件。"
        exit 1
    fi
    local domain
    domain=$(extract_domain "$url")
    if ! echo "$domain" | grep -qE "$DOMAIN_REGEX"; then
        error "${name} 域名格式不合法: ${domain}"
        exit 1
    fi
    echo "$domain"
}

ADMIN_DOMAIN=$(validate_domain "$ADMIN_URL" "ADMIN_URL")
H5_DOMAIN=$(validate_domain "$H5_URL" "H5_URL")
API_DOMAIN=$(validate_domain "$API_URL" "API_URL")

info "域名配置: admin=${ADMIN_DOMAIN}, h5=${H5_DOMAIN}, api=${API_DOMAIN}"

# ----- 4. 端口校验 -----
PORT_REGEX='^[0-9]+$'

if ! echo "$HTTP_PORT" | grep -qE "$PORT_REGEX"; then
    error "HTTP_PORT 格式不合法: ${HTTP_PORT}"
    exit 1
fi

# ----- 5. 检查 Docker 和 Docker Compose -----
if ! command -v docker &>/dev/null; then
    error "Docker 未安装，请先安装 Docker。"
    echo "  参考: https://docs.docker.com/engine/install/"
    exit 1
fi

if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
else
    error "Docker Compose 未安装，请先安装。"
    echo "  参考: https://docs.docker.com/compose/install/"
    exit 1
fi

ok "Docker: $(docker --version | head -1)"
ok "Compose: $($COMPOSE_CMD version 2>/dev/null || echo 'available')"

# ----- 6. 检查端口冲突 -----
check_port() {
    local port="$1"
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
            warn "端口 ${port} 已被占用，可能导致启动失败。"
            return 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
            warn "端口 ${port} 已被占用，可能导致启动失败。"
            return 1
        fi
    fi
    return 0
}

check_port "$HTTP_PORT"  || true

# ----- 7. DNS 解析检查 -----
check_dns() {
    local domain="$1"
    local name="$2"
    if command -v nslookup &>/dev/null; then
        if ! nslookup "$domain" &>/dev/null; then
            warn "${name} 域名 ${domain} 未解析到IP。"
            echo ""
            echo "  请确保域名已添加 DNS A 记录指向本服务器IP。"
            echo "  如果你已在 hosts 文件中配置，请忽略此警告。"
            echo ""
            read -rp "按 Enter 继续，或按 Ctrl+C 取消..."
        fi
    elif command -v dig &>/dev/null; then
        if ! dig +short "$domain" | grep -q .; then
            warn "${name} 域名 ${domain} 未解析到IP。"
            echo ""
            read -rp "按 Enter 继续，或按 Ctrl+C 取消..."
        fi
    fi
}

check_dns "$ADMIN_DOMAIN" "ADMIN_URL"
check_dns "$H5_DOMAIN"    "H5_URL"
check_dns "$API_DOMAIN"   "API_URL"

# ----- 8. Docker 镜像加速（国内服务器） -----
if [ -z "$CADDY_IMAGE_VAL" ] || [ "$CADDY_IMAGE_VAL" = "" ]; then
    info "检测网络环境..."
    if curl -s --connect-timeout 3 http://ipinfo.io/country 2>/dev/null | grep -q "CN"; then
        info "检测到国内网络，配置 Docker 镜像加速器..."
        DOCKER_MIRROR="https://docker.1panel.live"
        if [ -f /etc/docker/daemon.json ]; then
            if ! grep -q "docker.1panel.live" /etc/docker/daemon.json; then
                info "写入 Docker 镜像加速器到 /etc/docker/daemon.json..."
                echo "{\"registry-mirrors\":[\"${DOCKER_MIRROR}\"]}" > /etc/docker/daemon.json
                systemctl daemon-reload && systemctl restart docker
                info "Docker 镜像加速器配置完成"
            else
                info "Docker 镜像加速器已配置，跳过"
            fi
        else
            info "写入 Docker 镜像加速器到 /etc/docker/daemon.json..."
            echo "{\"registry-mirrors\":[\"${DOCKER_MIRROR}\"]}" > /etc/docker/daemon.json
            systemctl daemon-reload && systemctl restart docker
            info "Docker 镜像加速器配置完成"
        fi

    fi
fi

# ----- 9. 生成 Caddyfile -----
info "生成 Caddyfile（HTTP-only，SSL由宝塔处理）..."

# 提取域名（去掉 https:// 前缀）
ADMIN_DOMAIN=$(extract_domain "$ADMIN_URL")
H5_DOMAIN=$(extract_domain "$H5_URL")
API_DOMAIN=$(extract_domain "$API_URL")

cat > Caddyfile <<CADDY_EOF
# 管理后台
http://${ADMIN_DOMAIN} {
    reverse_proxy admin:80
}

# H5会员端
http://${H5_DOMAIN} {
    reverse_proxy h5:80
}

# API接口
http://${API_DOMAIN} {
    reverse_proxy nginx-api:80
}
CADDY_EOF

ok "Caddyfile 已生成。"

# ----- 10+11. 拉取镜像并启动容器 -----
info "拉取镜像并启动容器（已有镜像自动跳过）..."
$COMPOSE_CMD up -d --pull missing

# ----- 12. 等待健康检查 -----
info "等待 MySQL 和 Redis 就绪..."
WAIT_TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $WAIT_TIMEOUT ]; do
    MYSQL_STATUS=$($COMPOSE_CMD ps mysql 2>/dev/null | grep -oP '(healthy|unhealthy)' || echo "starting")
    REDIS_STATUS=$($COMPOSE_CMD ps redis 2>/dev/null | grep -oP '(healthy|unhealthy)' || echo "starting")

    if echo "$MYSQL_STATUS" | grep -q "healthy" && echo "$REDIS_STATUS" | grep -q "healthy"; then
        ok "MySQL 和 Redis 已就绪。"
        break
    fi

    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo -ne "\r  等待中... ${ELAPSED}s / ${WAIT_TIMEOUT}s"
done

if [ $ELAPSED -ge $WAIT_TIMEOUT ]; then
    warn "等待超时，请检查容器状态: $COMPOSE_CMD ps"
    warn "查看日志: $COMPOSE_CMD logs mysql redis"
fi

# ----- 13. 安装备份 cron -----
BACKUP_DAYS=$(get_env BACKUP_RETENTION_DAYS)
BACKUP_DAYS=${BACKUP_DAYS:-7}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_CMD="0 3 * * * cd ${SCRIPT_DIR} && bash backup.sh >> ./backups/cron.log 2>&1"

if command -v crontab &>/dev/null; then
    if ! crontab -l 2>/dev/null | grep -qF "backup.sh"; then
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
        ok "已安装每日备份任务（凌晨3点，保留 ${BACKUP_DAYS} 天）。"
    else
        info "备份任务已存在，跳过安装。"
    fi
else
    warn "crontab 不可用，请手动配置定时备份。"
fi

maybe_install_public_update_daemon
maybe_run_bt_proxy_fix

# ----- 14. 输出部署信息 -----
echo ""
echo "============================================================"
echo -e "  ${GREEN}蜂链商城部署完成！${NC}"
echo "============================================================"
echo ""
echo "  管理后台:   ${ADMIN_URL}"
echo "  H5会员端:   ${H5_URL}"
echo "  API接口:    ${API_URL}"
echo ""
echo "  默认账号:   admin"
echo "  默认密码:   123123"
echo ""
echo "  ⚠ 请登录后立即修改默认密码！"
echo ""
echo "============================================================"
echo ""
echo "  常用命令:"
echo "    查看日志:   $COMPOSE_CMD logs -f"
echo "    重启服务:   $COMPOSE_CMD restart"
echo "    停止服务:   $COMPOSE_CMD stop"
echo "    数据备份:   bash backup.sh"
echo "    数据恢复:   bash restore.sh backup_XXXXXX.sql"
echo ""
echo "============================================================"
