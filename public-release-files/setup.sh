#!/bin/bash
# ============================================================
#  蜂链商城 - 交互式部署向导
#  用法：bash setup.sh
# ============================================================
set -euo pipefail

# ===== 辅助函数 =====
get_env_val() {
    grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo ""
}

sed_in_place() {
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
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

    current_db_password=$(get_env_val "DB_PASSWORD")
    current_root_password=$(get_env_val "MYSQL_ROOT_PASSWORD")
    current_redis_password=$(get_env_val "REDIS_PASSWORD")
    current_version=$(get_env_val "VERSION")

    if [ "$current_db_password" = "CHANGE_ME_ON_FIRST_RUN" ] || [ -z "$current_db_password" ]; then
        GENERATED_DB_PASSWORD=$(generate_secret)
        set_env_val "DB_PASSWORD" "$GENERATED_DB_PASSWORD"
    fi

    if [ "$current_root_password" = "CHANGE_ME_ON_FIRST_RUN" ] || [ -z "$current_root_password" ]; then
        GENERATED_ROOT_PASSWORD=$(generate_secret)
        set_env_val "MYSQL_ROOT_PASSWORD" "$GENERATED_ROOT_PASSWORD"
    fi

    if [ -z "$current_redis_password" ]; then
        GENERATED_REDIS_PASSWORD=$(generate_secret)
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
    echo -e "  ${YELLOW}╔══════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}║${NC}  ${BOLD}重要：请记录以下信息（仅显示一次）${NC} ${YELLOW}║${NC}"
    echo -e "  ${YELLOW}╠══════════════════════════════════════════╣${NC}"
    [ -n "$GENERATED_VERSION" ] && echo -e "  ${YELLOW}║${NC}  APP版本:       ${BOLD}${GENERATED_VERSION}${NC}"
    [ -n "$GENERATED_DB_PASSWORD" ] && echo -e "  ${YELLOW}║${NC}  数据库密码:     ${BOLD}${GENERATED_DB_PASSWORD}${NC}"
    [ -n "$GENERATED_ROOT_PASSWORD" ] && echo -e "  ${YELLOW}║${NC}  MySQL root密码: ${BOLD}${GENERATED_ROOT_PASSWORD}${NC}"
    [ -n "$GENERATED_REDIS_PASSWORD" ] && echo -e "  ${YELLOW}║${NC}  Redis密码:      ${BOLD}${GENERATED_REDIS_PASSWORD}${NC}"
    echo -e "  ${YELLOW}╚══════════════════════════════════════════╝${NC}"
}

print_public_update_daemon_hint() {
    echo ""
    echo -e "  ${DIM}公开版后台自动更新守护进程安装命令：${NC}"
    echo -e "  ${GREEN}sudo bash ./update-toolkit/install-public-update-daemon.sh${NC}"
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

    echo ""
    echo -ne "  ${BOLD}是否现在安装公开版自动更新守护进程？${NC} ${DIM}(y/N)${NC}: "
    read -r confirm_install

    if [ "$confirm_install" = "y" ] || [ "$confirm_install" = "Y" ]; then
        bash "$install_script"
    else
        print_public_update_daemon_hint
    fi
}

# ===== 颜色和符号 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CHECK="✅"
CROSS="❌"
ARROW="➜"
DOT="●"

# ===== 辅助函数 =====
print_header() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}蜂链商城电商新零售系统 - 一键部署向导${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${DIM}Fenglian Shop E-commerce System Setup${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() {
    local num="$1"
    local title="$2"
    local status="$3"  # done, current, pending
    case "$status" in
        done)    echo -e "  ${GREEN}${CHECK} [${num}]${NC} ${title}" ;;
        current) echo -e "  ${CYAN}${ARROW} [${num}]${NC} ${BOLD}${title}${NC}" ;;
        pending) echo -e "  ${DIM}${DOT} [${num}]${NC} ${DIM}${title}${NC}" ;;
    esac
}

print_result() {
    local label="$1"
    local value="$2"
    echo -e "       ${DIM}${label}:${NC} ${GREEN}${value}${NC}"
}

# ===== 配置变量 =====
ADMIN_URL=""
H5_URL=""
API_URL=""
ADMIN_DOMAIN=""
H5_DOMAIN=""
API_DOMAIN=""
HTTP_PORT="8880"
STEP=1
TOTAL_STEPS=5

# ===== 步骤状态 =====
S1_DONE=false
S2_DONE=false
S3_DONE=false
S4_DONE=false
S5_DONE=false

# ===== 显示当前进度 =====
show_progress() {
    echo ""
    echo -e "${DIM}──────────────────────────────────────────────${NC}"
    print_step 1 "管理后台域名"  "$([ "$S1_DONE" = true ] && echo 'done' || ([ $STEP -eq 1 ] && echo 'current' || echo 'pending'))"
    [ "$S1_DONE" = true ] && print_result "$ADMIN_DOMAIN" "$ADMIN_URL"
    print_step 2 "H5商城域名"   "$([ "$S2_DONE" = true ] && echo 'done' || ([ $STEP -eq 2 ] && echo 'current' || echo 'pending'))"
    [ "$S2_DONE" = true ] && print_result "$H5_DOMAIN" "$H5_URL"
    print_step 3 "API接口域名"  "$([ "$S3_DONE" = true ] && echo 'done' || ([ $STEP -eq 3 ] && echo 'current' || echo 'pending'))"
    [ "$S3_DONE" = true ] && print_result "$API_DOMAIN" "$API_URL"
    print_step 4 "端口配置"     "$([ "$S4_DONE" = true ] && echo 'done' || ([ $STEP -eq 4 ] && echo 'current' || echo 'pending'))"
    [ "$S4_DONE" = true ] && print_result "HTTP端口" "${HTTP_PORT}"
    print_step 5 "确认并部署"   "$([ "$S5_DONE" = true ] && echo 'done' || ([ $STEP -eq 5 ] && echo 'current' || echo 'pending'))"
    echo -e "${DIM}──────────────────────────────────────────────${NC}"
    echo ""
}

# ===== 域名校验 =====
validate_domain() {
    local input="$1"
    local domain
    domain=$(echo "$input" | sed 's|https\?://||' | cut -d'/' -f1 | cut -d':' -f1)
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        echo "$domain"
        return 0
    fi
    return 1
}

# ===== 域名输入 =====
input_domain() {
    local label="$1"
    local var_name="$2"
    local default_val="${3:-}"

    while true; do
        if [ -n "$default_val" ]; then
            echo -ne "  ${ARROW} ${BOLD}${label}${NC} ${DIM}[${default_val}]${NC}: "
        else
            echo -ne "  ${ARROW} ${BOLD}${label}${NC}: "
        fi
        read -r input

        # 使用默认值
        if [ -z "$input" ] && [ -n "$default_val" ]; then
            input="$default_val"
        fi

        if [ -z "$input" ]; then
            echo -e "  ${RED}${CROSS} 域名不能为空，请重新输入${NC}"
            continue
        fi

        local domain
        if domain=$(validate_domain "$input"); then
            eval "$var_name=$domain"
            # 自动生成完整URL
            eval "${var_name/_DOMAIN/_URL}=https://${domain}"
            echo -e "  ${GREEN}${CHECK} ${domain}${NC}"
            return 0
        else
            echo -e "  ${RED}${CROSS} 域名格式不正确: ${input}${NC}"
            echo -e "  ${DIM}   正确格式: admin.example.com（不要带https://）${NC}"
        fi
    done
}

# ===== 端口输入 =====
input_port() {
    local label="$1"
    local default_val="$2"
    local result_var="$3"

    echo -ne "  ${ARROW} ${BOLD}${label}${NC} ${DIM}[${default_val}]${NC}: "
    read -r input

    if [ -z "$input" ]; then
        input="$default_val"
    fi

    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
        eval "$result_var=$input"
        echo -e "  ${GREEN}${CHECK} 端口 ${input}${NC}"
        return 0
    else
        echo -e "  ${RED}${CROSS} 端口格式不正确: ${input}（应为1-65535的数字）${NC}"
        return 1
    fi
}

# ===== 环境检查 =====
check_environment() {
    echo -e "  ${DIM}检查运行环境...${NC}"
    local ok=true

    # Docker
    if command -v docker &>/dev/null; then
        echo -e "  ${GREEN}${CHECK}${NC} Docker: $(docker --version | head -1)"
    else
        echo -e "  ${RED}${CROSS}${NC} Docker 未安装"
        ok=false
    fi

    # Docker Compose
    if docker compose version &>/dev/null; then
        echo -e "  ${GREEN}${CHECK}${NC} Docker Compose: $(docker compose version --short 2>/dev/null || echo 'available')"
    elif command -v docker-compose &>/dev/null; then
        echo -e "  ${GREEN}${CHECK}${NC} Docker Compose (legacy): $(docker-compose version --short 2>/dev/null || echo 'available')"
    else
        echo -e "  ${RED}${CROSS}${NC} Docker Compose 未安装"
        ok=false
    fi

    # 磁盘空间
    local avail_gb
    avail_gb=$(df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [ "${avail_gb:-0}" -ge 10 ]; then
        echo -e "  ${GREEN}${CHECK}${NC} 可用磁盘空间: ${avail_gb}GB"
    else
        echo -e "  ${YELLOW}!${NC} 磁盘空间可能不足: ${avail_gb:-?}GB（建议10GB以上）"
    fi

    if [ "$ok" = false ]; then
        echo ""
        echo -e "  ${RED}${CROSS} 环境检查未通过，请先安装缺少的组件${NC}"
        exit 1
    fi
    echo ""
}

# ===== 主流程 =====

# 步骤1：管理后台域名
print_header
echo -e "  ${BOLD}步骤 1/${TOTAL_STEPS}：配置管理后台域名${NC}"
echo -e "  ${DIM}管理员通过此域名登录后台管理商城${NC}"
echo ""
input_domain "管理后台域名" "ADMIN_DOMAIN"
S1_DONE=true
STEP=2

# 步骤2：H5商城域名
print_header
show_progress
echo -e "  ${BOLD}步骤 2/${TOTAL_STEPS}：配置H5商城域名${NC}"
echo -e "  ${DIM}顾客通过此域名在手机浏览器访问商城${NC}"
echo ""
input_domain "H5商城域名" "H5_DOMAIN"
S2_DONE=true
STEP=3

# 步骤3：API接口域名
print_header
show_progress
echo -e "  ${BOLD}步骤 3/${TOTAL_STEPS}：配置API接口域名${NC}"
echo -e "  ${DIM}后端API服务域名，前端通过此域名调用接口${NC}"
echo ""
input_domain "API接口域名" "API_DOMAIN"
S3_DONE=true
STEP=4

# 步骤4：端口配置
print_header
show_progress
echo -e "  ${BOLD}步骤 4/${TOTAL_STEPS}：配置端口${NC}"
echo -e "  ${DIM}默认8880为Caddy内部HTTP端口，SSL由宝塔处理${NC}"
echo ""
while true; do
    input_port "HTTP端口" "$HTTP_PORT" "HTTP_PORT" && break
done
S4_DONE=true
STEP=5

# 步骤5：确认配置
print_header
show_progress
echo -e "  ${BOLD}步骤 5/${TOTAL_STEPS}：确认配置${NC}"
echo ""
echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${CYAN}║${NC}  ${BOLD}部署配置摘要${NC}                                ${CYAN}║${NC}"
echo -e "  ${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}║${NC}  管理后台:  ${GREEN}https://${ADMIN_DOMAIN}${NC}"
echo -e "  ${CYAN}║${NC}  H5商城:    ${GREEN}https://${H5_DOMAIN}${NC}"
echo -e "  ${CYAN}║${NC}  API接口:   ${GREEN}https://${API_DOMAIN}${NC}"
echo -e "  ${CYAN}║${NC}  HTTP端口:  ${GREEN}${HTTP_PORT}${NC}"
echo -e "  ${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# 环境检查
check_environment

# DNS检查
echo -e "  ${DIM}检查域名DNS解析...${NC}"
for domain in "$ADMIN_DOMAIN" "$H5_DOMAIN" "$API_DOMAIN"; do
    if nslookup "$domain" &>/dev/null || dig +short "$domain" 2>/dev/null | grep -q .; then
        echo -e "  ${GREEN}${CHECK}${NC} ${domain} → DNS已解析"
    else
        echo -e "  ${YELLOW}!${NC} ${domain} → DNS未解析（请确保域名已添加A记录指向本服务器IP）"
    fi
done
echo ""

# 确认
echo -ne "  ${BOLD}确认以上配置无误，开始部署？${NC} ${DIM}(y/N)${NC}: "
read -r confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo ""
    echo -e "  ${YELLOW}已取消部署。${NC}"
    echo -e "  ${DIM}你可以重新运行 bash setup.sh 重新配置。${NC}"
    exit 0
fi

S5_DONE=true
STEP=6

# ===== 步骤6：执行部署 =====
print_header
show_progress
echo -e "  ${BOLD}步骤 6/${TOTAL_STEPS}：正在部署...${NC}"
echo ""

# 生成.env文件
echo -e "  ${ARROW} 生成配置文件..."
if [ ! -f .env ]; then
    cp .env.example .env
fi
ensure_bootstrap_env_values

# 写入域名配置
set_env_val "ADMIN_URL" "https://${ADMIN_DOMAIN}"
set_env_val "H5_URL" "https://${H5_DOMAIN}"
set_env_val "API_URL" "https://${API_DOMAIN}"
set_env_val "HTTP_PORT" "${HTTP_PORT}"

echo -e "  ${GREEN}${CHECK}${NC} 配置文件已生成"
print_generated_secrets

# Caddy镜像加速
echo -e "  ${ARROW} 检测网络环境..."
if curl -s --connect-timeout 3 http://ipinfo.io/country 2>/dev/null | grep -q "CN"; then
    echo -e "  ${GREEN}${CHECK}${NC} 检测到国内网络，使用阿里云Caddy镜像加速"
    if ! grep -q "^CADDY_IMAGE=" .env; then
        echo "CADDY_IMAGE=registry.cn-hangzhou.aliyuncs.com/library/caddy:2-alpine" >> .env
    else
        set_env_val "CADDY_IMAGE" "registry.cn-hangzhou.aliyuncs.com/library/caddy:2-alpine"
    fi
else
    echo -e "  ${GREEN}${CHECK}${NC} 海外网络，使用Docker Hub官方镜像"
fi

# 生成Caddyfile
echo -e "  ${ARROW} 生成Caddy反代配置（HTTP-only，SSL由宝塔处理）..."
cat > Caddyfile << CADDY_EOF
http://${ADMIN_DOMAIN} {
    reverse_proxy admin:80
}

http://${H5_DOMAIN} {
    reverse_proxy h5:80
}

http://${API_DOMAIN} {
    reverse_proxy nginx-api:80
}
CADDY_EOF
echo -e "  ${GREEN}${CHECK}${NC} Caddyfile已生成"

# 检测Docker Compose命令
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# 拉取镜像
echo -e "  ${ARROW} 拉取Docker镜像..."
$COMPOSE_CMD pull

# 启动容器
echo -e "  ${ARROW} 启动容器..."
$COMPOSE_CMD up -d

# 等待健康检查 - 基础设施（数据库 + 缓存）
echo -e "  ${ARROW} 等待数据库和缓存就绪..."
WAIT_TIMEOUT=90
ELAPSED=0
while [ $ELAPSED -lt $WAIT_TIMEOUT ]; do
    MYSQL_OK=$($COMPOSE_CMD ps mysql 2>/dev/null | grep -c "healthy" || true)
    REDIS_OK=$($COMPOSE_CMD ps redis 2>/dev/null | grep -c "healthy" || true)
    if [ "$MYSQL_OK" -ge 1 ] && [ "$REDIS_OK" -ge 1 ]; then
        echo -e "  ${GREEN}${CHECK}${NC} MySQL和Redis已就绪"
        break
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo -ne "\r  ${DIM}等待中... ${ELAPSED}s / ${WAIT_TIMEOUT}s${NC}"
done

if [ $ELAPSED -ge $WAIT_TIMEOUT ]; then
    echo -e "\n  ${YELLOW}!${NC} 数据库或缓存启动超时，请检查: $COMPOSE_CMD ps"
fi

# 等待 API 服务就绪（减少首次登录 502/500 错误）
echo -e "  ${ARROW} 等待 API 服务就绪..."
API_WAIT_SECONDS=60
API_ELAPSED=0
API_READY=false
while [ $API_ELAPSED -lt $API_WAIT_SECONDS ]; do
    API_CONTAINER="${COMPOSE_PROJECT:-fenglianshop}-api-1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${API_CONTAINER}$"; then
        if docker exec "${API_CONTAINER}" sh -c "php -v" >/dev/null 2>&1; then
            echo -e "  ${GREEN}${CHECK}${NC} API 服务已就绪 (${API_ELAPSED}秒)"
            API_READY=true
            break
        fi
    fi
    sleep 2
    API_ELAPSED=$((API_ELAPSED + 2))
    if [ $((API_ELAPSED % 10)) -eq 0 ]; then
        echo -e "  ${DIM}  等待 API 服务就绪... (${API_ELAPSED}/${API_WAIT_SECONDS})${NC}"
    fi
done

if [ "$API_READY" = false ]; then
    echo -e "  ${YELLOW}!${NC} API 服务启动超时，部署将继续但首次登录可能需要等待 1-2 分钟"
fi

# 额外等待确保服务完全初始化（PHP 应用引导、Nginx 连接池）
echo -e "  ${DIM}  等待服务初始化完成...${NC}"
sleep 5

# 启动容器后，从容器内同步 APP_KEY 到 .env（确保升级时 APP_KEY 不变）
local current_app_key
current_app_key=$(get_env_val "APP_KEY")
if [[ -z "${current_app_key}" || "${current_app_key}" == "base64:" ]]; then
    local container_app_key
    container_app_key=$(docker exec "${COMPOSE_PROJECT:-fenglianshop}-api-1" sh -c "grep '^APP_KEY=' /var/www/html/.env 2>/dev/null | cut -d'=' -f2-" 2>/dev/null || true)
    if [[ -n "${container_app_key}" ]]; then
        set_env_val "APP_KEY" "${container_app_key}"
    fi
fi

# 安装备份cron
BACKUP_DAYS=$(grep "^BACKUP_RETENTION_DAYS=" .env | cut -d'=' -f2 || echo "7")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_CMD="0 3 * * * cd ${SCRIPT_DIR} && bash backup.sh >> ./backups/cron.log 2>&1"
if command -v crontab &>/dev/null; then
    if ! crontab -l 2>/dev/null | grep -qF "backup.sh"; then
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
        echo -e "  ${GREEN}${CHECK}${NC} 每日备份已安装（凌晨3点，保留${BACKUP_DAYS}天）"
    fi
fi

maybe_install_public_update_daemon

# ===== 部署完成 =====
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}  ${BOLD}🎉 部署完成！${NC}                                     ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}                                                      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  管理后台:  ${BOLD}https://${ADMIN_DOMAIN}${NC}"
echo -e "${GREEN}║${NC}  H5商城:    ${BOLD}https://${H5_DOMAIN}${NC}"
echo -e "${GREEN}║${NC}  API接口:   ${BOLD}https://${API_DOMAIN}${NC}"
echo -e "${GREEN}║${NC}                                                      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  默认账号:  ${BOLD}admin${NC}"
echo -e "${GREEN}║${NC}  默认密码:  ${BOLD}123123${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}⚠ 首次登录后请立即修改默认密码！${NC}               ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}                                                      ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${DIM}常用命令：${NC}                                         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  查看日志:  ${DIM}$COMPOSE_CMD logs -f${NC}"
echo -e "${GREEN}║${NC}  重启服务:  ${DIM}$COMPOSE_CMD restart${NC}"
echo -e "${GREEN}║${NC}  手动备份:  ${DIM}bash backup.sh${NC}"
echo -e "${GREEN}║${NC}  数据恢复:  ${DIM}bash restore.sh backups/xxx.sql${NC}"
echo -e "${GREEN}║${NC}                                                      ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
