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

# ============================================
# 创建 mp-upload-worker 受限 DB 账号
# 必须在 api migrate 完成后调用（否则 GRANT 目标表不存在）
# 复用 .env 的 MYSQL_ROOT_PASSWORD 执行 GRANT，密码写入 .env 的 MP_WORKER_DB_PASSWORD
# ============================================
ensure_mp_worker_db_account() {
    local db_name
    db_name=$(get_env "DB_DATABASE")
    db_name="${db_name:-xinshangcheng003}"

    local root_pass
    root_pass=$(get_env "MYSQL_ROOT_PASSWORD")
    if [[ -z "$root_pass" || "$root_pass" == "CHANGE_ME_ON_FIRST_RUN" ]]; then
        warn "MYSQL_ROOT_PASSWORD 未就绪，跳过 mp_worker 账号创建"
        return 0
    fi

    # 定位 MySQL 容器（支持多种命名格式）
    local mysql_container=""
    for name in "${COMPOSE_PROJECT:-fenglianshop}_mysql_1" "${COMPOSE_PROJECT:-fenglianshop}-mysql-1" "${COMPOSE_PROJECT:-fenglianshop}_mysql"; do
        if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            mysql_container="$name"
            break
        fi
    done
    if [[ -z "$mysql_container" ]]; then
        warn "MySQL 容器未找到，跳过 mp_worker 账号创建"
        return 0
    fi

    # 密码优先读 .env，不存在则随机生成并回写（仅首次）
    local worker_pass
    worker_pass=$(get_env "MP_WORKER_DB_PASSWORD")
    if [[ -z "$worker_pass" ]]; then
        # 仅 [A-Za-z0-9]，杜绝特殊字符导致 SQL 注入
        worker_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)
        set_env_val "MP_WORKER_DB_PASSWORD" "$worker_pass"
        info "已生成 mp_worker 密码并写入 .env"
    fi

    info "创建/更新受限 DB 账号 mp_worker（仅授权小程序上传相关表）..."

    # 🔴 关键：不能用 heredoc + 管道 + grep 的组合
    # 在 set -euo pipefail 下，grep 找不到匹配会返回1，pipefail 让整个管道返回1，
    # set -e 会立即终止脚本（这正是上次部署卡在这里的直接原因）
    #
    # 正确做法：先用 -e 执行 SQL（不用管道，退出码非0不致命），再用单独命令验证账号

    # 步骤1：执行 CREATE USER + GRANT（set +e 临时关闭，避免任何错误终止脚本）
    set +e
    docker exec "$mysql_container" mysql -uroot -p"$root_pass" --default-character-set=utf8mb4 -e "
CREATE USER IF NOT EXISTS 'mp_worker'@'%' IDENTIFIED BY '${worker_pass}';
ALTER USER 'mp_worker'@'%' IDENTIFIED BY '${worker_pass}';
GRANT SELECT, INSERT, UPDATE ON ${db_name}.miniprogram_ci_keys TO 'mp_worker'@'%';
GRANT SELECT, INSERT, UPDATE ON ${db_name}.miniprogram_upload_history TO 'mp_worker'@'%';
GRANT SELECT, INSERT ON ${db_name}.app_notification_logs TO 'mp_worker'@'%';
FLUSH PRIVILEGES;
" 2>&1 | grep -v "Using a password" || true
    set -e

    # 步骤2：验证 mp_worker 账号能否实际登录（最可靠的成败判断）
    set +e
    docker exec "$mysql_container" mysql -ump_worker -p"$worker_pass" -e "SELECT 1 AS login_test;" 2>/dev/null
    local login_test=$?
    set -e

    if [ $login_test -eq 0 ]; then
        ok "mp_worker 账号创建成功，且可正常登录（仅授权 3 张小程序相关表）"
    else
        warn "mp_worker 账号创建/登录失败（退出码=${login_test}）"
        warn "可能原因：①migrate 未完成（3张表不存在）②root 密码错误 ③密码含特殊字符"
        warn "排查命令："
        warn "  docker exec $mysql_container mysql -uroot -p'***' -e 'SHOW TABLES LIKE \"miniprogram_%\";'"
        warn "  docker exec $mysql_container mysql -uroot -p'***' -e 'SELECT user FROM mysql.user WHERE user=\"mp_worker\";'"
        warn "（此警告不阻塞部署，mp-upload-worker 会在任务执行时报错）"
    fi
}

# ============================================
# 从 api 容器同步 APP_KEY 到 .env
# APP_KEY 是 CI 私钥加密根密钥，API/Worker 必须一致
# ============================================
sync_app_key_from_container() {
    local current_app_key
    current_app_key=$(get_env "APP_KEY")
    if [[ -n "$current_app_key" ]]; then
        return 0
    fi

    info "从 api 容器同步 APP_KEY 到 .env ..."
    local api_container=""
    for name in "${COMPOSE_PROJECT:-fenglianshop}_api_1" "${COMPOSE_PROJECT:-fenglianshop}-api-1" "${COMPOSE_PROJECT:-fenglianshop}_api"; do
        if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
            api_container="$name"
            break
        fi
    done

    if [[ -z "$api_container" ]]; then
        warn "api 容器未运行，无法同步 APP_KEY（mp-upload-worker 启动时若 APP_KEY 为空会失败）"
        return 0
    fi

    # 等 api 容器完成 key:generate（最多60秒）
    local try=0
    local container_key=""
    while [[ $try -lt 30 ]]; do
        container_key=$(docker exec "$api_container" sh -c "grep '^APP_KEY=' /var/www/html/.env 2>/dev/null | cut -d'=' -f2-" 2>/dev/null || true)
        if [[ -n "$container_key" && "$container_key" != "base64:"* ]]; then
            # 等待有效 key
            :
        fi
        if [[ -n "$container_key" ]]; then
            break
        fi
        sleep 2
        try=$((try + 1))
    done

    if [[ -n "$container_key" ]]; then
        set_env_val "APP_KEY" "$container_key"
        ok "APP_KEY 已同步到 .env（mp-upload-worker 将使用此 key 解密 CI 私钥）"
    else
        warn "未能从 api 容器获取 APP_KEY，mp-upload-worker 可能无法解密 CI 私钥"
        warn "请稍后手动执行: docker exec <api容器> grep ^APP_KEY /var/www/html/.env 并写入 .env"
    fi
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
        DOCKER_MIRROR="https://docker.1ms.run"
        if [ -f /etc/docker/daemon.json ]; then
            if ! grep -q "docker.1ms.run" /etc/docker/daemon.json; then
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
info "拉取镜像（已有镜像自动跳过，失败自动重试）..."

# 公开版首次部署：CI/CD 推送镜像到 Docker Hub 后，CDN 全球同步需要几分钟
# 首次拉取可能撞上同步窗口（报 not found），故失败后等待重试
pull_images_with_retry() {
    local max_retries=3
    local retry_delay=30
    local attempt=1
    while [ $attempt -le $max_retries ]; do
        info "拉取镜像（第 ${attempt}/${max_retries} 次尝试）..."
        # 🔴 关键：不能用 | tail 或 | grep 管道（会把进度输出全部缓冲到命令结束才显示，
        # 表现为光标闪烁长时间无输出）。直接让 compose pull 输出到终端，实时显示进度。
        # 退出码用 $?: set +e 保护避免失败终止脚本，失败后进入重试逻辑。
        set +e
        $COMPOSE_CMD pull
        local pull_exit=$?
        set -e
        if [ $pull_exit -eq 0 ]; then
            ok "镜像拉取完成"
            return 0
        fi
        if [ $attempt -lt $max_retries ]; then
            warn "拉取失败（exit=${pull_exit}），${retry_delay}秒后重试..."
            warn "（常见原因：刚推送的镜像在 Docker Hub CDN 同步中，稍等即可）"
            sleep $retry_delay
        fi
        attempt=$((attempt + 1))
    done
    error "镜像拉取失败（已重试 ${max_retries} 次）"
    error "请稍后重试 bash start.sh，或检查网络/Docker Hub 状态"
    return 1
}

if ! pull_images_with_retry; then
    exit 1
fi

info "启动容器..."
$COMPOSE_CMD up -d

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

# ----- 12.5 确保 storage 目录结构 -----
info "确保 API storage 目录结构..."
$COMPOSE_CMD exec -T api sh -c "mkdir -p /var/www/html/storage/framework/sessions /var/www/html/storage/framework/cache /var/www/html/storage/framework/views /var/www/html/storage/logs /var/www/html/bootstrap/cache && chmod -R 755 /var/www/html/storage /var/www/html/bootstrap/cache" 2>/dev/null || warn "storage 目录初始化跳过（API容器可能未就绪）"

# ----- 12.6 等待 api 容器完成 migrate + 同步 APP_KEY + 创建 mp_worker 受限账号 -----
info "等待 API 容器完成数据库迁移（SAFE_DB_INIT）..."
API_WAIT=0
API_WAIT_MAX=180
API_READY=false
while [ $API_WAIT -lt $API_WAIT_MAX ]; do
    if $COMPOSE_CMD exec -T api sh -c "php artisan tinker --execute=\"echo Schema::hasTable('mall_admins')?1:0;\"" 2>/dev/null | grep -q "1"; then
        ok "API 容器 migrate 已完成"
        API_READY=true
        break
    fi
    sleep 3
    API_WAIT=$((API_WAIT + 3))
    echo -ne "\r  等待 API migrate... ${API_WAIT}s / ${API_WAIT_MAX}s"
done
echo ""

if [ "$API_READY" != "true" ]; then
    warn "API migrate 等待超时（${API_WAIT_MAX}s），继续尝试..."
fi

# 同步 APP_KEY（CI 私钥解密根密钥，API/Worker 必须一致）
sync_app_key_from_container

# 创建 mp-upload-worker 受限 DB 账号（api migrate 完成后调用，确保目标表已存在）
ensure_mp_worker_db_account

# ----- 12.7 重启 mp-upload-worker 使其读取最新的 APP_KEY 和 mp_worker 密码 -----
info "确保 mp-upload-worker 读取最新配置..."
$COMPOSE_CMD up -d mp-upload-worker 2>/dev/null || warn "mp-upload-worker 启动跳过（docker-compose.yml 可能未含此服务）"

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
echo -e "  ${YELLOW}恭喜部署成功，欢迎使用蜂链商城电商新零售系统。${NC}"
echo -e "  ${YELLOW}容器已经全部部署成功，正在初始化中，首次部署成功后请等待1~3分钟后再登录管理后台使用系统。${NC}"
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
