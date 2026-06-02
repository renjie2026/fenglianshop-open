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

# ----- 1. 检查 .env 文件 -----
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        warn ".env 文件不存在，已从 .env.example 复制。"
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

# ----- 2. 从 .env 读取配置 -----
get_env() {
    grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo ""
}

ADMIN_URL=$(get_env ADMIN_URL)
H5_URL=$(get_env H5_URL)
API_URL=$(get_env API_URL)
HTTP_PORT=$(get_env HTTP_PORT)
HTTPS_PORT=$(get_env HTTPS_PORT)
DB_PASSWORD=$(get_env DB_PASSWORD)
MYSQL_ROOT_PASSWORD=$(get_env MYSQL_ROOT_PASSWORD)
CADDY_IMAGE_VAL=$(get_env CADDY_IMAGE)

# 默认端口
HTTP_PORT=${HTTP_PORT:-8880}
HTTPS_PORT=${HTTPS_PORT:-8443}

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
if ! echo "$HTTPS_PORT" | grep -qE "$PORT_REGEX"; then
    error "HTTPS_PORT 格式不合法: ${HTTPS_PORT}"
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
check_port "$HTTPS_PORT" || true

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

# ----- 8. 首次运行自动生成强密码 -----
if [ "$DB_PASSWORD" = "CHANGE_ME_ON_FIRST_RUN" ] || [ "$DB_PASSWORD" = "" ]; then
    info "首次运行，自动生成数据库密码..."
    NEW_DB_PASSWORD=$(openssl rand -hex 16)
    NEW_MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)

    # 写入 .env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^DB_PASSWORD=.*|DB_PASSWORD=${NEW_DB_PASSWORD}|" .env
        sed -i '' "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${NEW_MYSQL_ROOT_PASSWORD}|" .env
    else
        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${NEW_DB_PASSWORD}|" .env
        sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${NEW_MYSQL_ROOT_PASSWORD}|" .env
    fi

    DB_PASSWORD="$NEW_DB_PASSWORD"
    MYSQL_ROOT_PASSWORD="$NEW_MYSQL_ROOT_PASSWORD"

    echo ""
    echo "============================================"
    echo "  数据库密码已自动生成（仅显示一次）"
    echo "============================================"
    echo "  DB_PASSWORD         = ${NEW_DB_PASSWORD}"
    echo "  MYSQL_ROOT_PASSWORD = ${NEW_MYSQL_ROOT_PASSWORD}"
    echo "============================================"
    echo ""
    warn "请务必记录以上密码！后续将不再显示。"
    echo ""
fi

# ----- 9. Caddy 镜像加速 -----
if [ -z "$CADDY_IMAGE_VAL" ] || [ "$CADDY_IMAGE_VAL" = "" ]; then
    info "检测网络环境..."
    if curl -s --connect-timeout 3 http://ipinfo.io/country 2>/dev/null | grep -q "CN"; then
        info "检测到国内网络，使用阿里云 Caddy 镜像加速..."
        CADDY_IMAGE_VAL="registry.cn-hangzhou.aliyuncs.com/library/caddy:2-alpine"
        # 写入 .env
        if ! grep -q "^CADDY_IMAGE=" .env; then
            echo "CADDY_IMAGE=${CADDY_IMAGE_VAL}" >> .env
        else
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s|^# *CADDY_IMAGE=.*|CADDY_IMAGE=${CADDY_IMAGE_VAL}|" .env
                sed -i '' "s|^CADDY_IMAGE=.*|CADDY_IMAGE=${CADDY_IMAGE_VAL}|" .env
            else
                sed -i "s|^# *CADDY_IMAGE=.*|CADDY_IMAGE=${CADDY_IMAGE_VAL}|" .env
                sed -i "s|^CADDY_IMAGE=.*|CADDY_IMAGE=${CADDY_IMAGE_VAL}|" .env
            fi
        fi
    fi
fi

# ----- 10. 生成 Caddyfile -----
info "生成 Caddyfile..."

cat > Caddyfile <<CADDY_EOF
# 管理后台
${ADMIN_URL} {
    reverse_proxy admin:80
}

# H5会员端
${H5_URL} {
    reverse_proxy h5:80
}

# API接口
${API_URL} {
    reverse_proxy nginx-api:80
}
CADDY_EOF

ok "Caddyfile 已生成。"

# ----- 11. 拉取镜像 -----
info "拉取 Docker 镜像..."
$COMPOSE_CMD pull

# ----- 12. 启动容器 -----
info "启动容器..."
$COMPOSE_CMD up -d

# ----- 13. 等待健康检查 -----
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

# ----- 14. 安装备份 cron -----
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

# ----- 15. 输出部署信息 -----
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
echo "    停止服务:   $COMPOSE_CMD down"
echo "    数据备份:   bash backup.sh"
echo "    数据恢复:   bash restore.sh backup_XXXXXX.sql"
echo ""
echo "============================================================"
