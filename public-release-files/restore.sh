#!/usr/bin/env bash
# ============================================================
#  蜂链商城 - 数据库恢复脚本
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ----- 颜色定义 -----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

# ----- 用法检查 -----
if [ $# -lt 1 ]; then
    echo "用法: bash restore.sh <备份文件>"
    echo ""
    echo "示例:"
    echo "  bash restore.sh backups/backup_20260531_030000.sql"
    echo ""
    echo "可用备份文件:"
    ls -lh ./backups/backup_*.sql 2>/dev/null || echo "  （暂无备份文件）"
    exit 1
fi

BACKUP_FILE="$1"

# ----- 检查备份文件是否存在 -----
if [ ! -f "$BACKUP_FILE" ]; then
    error "备份文件不存在: ${BACKUP_FILE}"
    exit 1
fi

if [ ! -s "$BACKUP_FILE" ]; then
    error "备份文件为空: ${BACKUP_FILE}"
    exit 1
fi

# ----- 从 .env 读取配置 -----
get_env() {
    grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo ""
}

DB_DATABASE=$(get_env DB_DATABASE)
DB_USERNAME=$(get_env DB_USERNAME)
DB_PASSWORD=$(get_env DB_PASSWORD)

DB_DATABASE=${DB_DATABASE:-xinshangcheng003}
DB_USERNAME=${DB_USERNAME:-xinshangcheng}

# 检测Docker Compose命令
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# ----- 导入前自动备份当前数据库 -----
info "恢复前自动备份当前数据库（安全措施）..."
SAFETY_BACKUP="./backups/pre_restore_$(date +%Y%m%d_%H%M%S).sql"
mkdir -p ./backups

$COMPOSE_CMD exec -T mysql mysqldump \
    --default-character-set=utf8mb4 \
    -u"${DB_USERNAME}" \
    -p"${DB_PASSWORD}" \
    "${DB_DATABASE}" \
    --single-transaction \
    --quick \
    --lock-tables=false \
    > "$SAFETY_BACKUP" 2>/dev/null || warn "自动备份失败（数据库可能为空），继续恢复..."

if [ -s "$SAFETY_BACKUP" ]; then
    ok "当前数据库已备份到: ${SAFETY_BACKUP}"
fi

# ----- 确认恢复 -----
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo ""
warn "即将恢复数据库，当前数据将被覆盖！"
echo ""
echo "  备份文件:  ${BACKUP_FILE}"
echo "  文件大小:  ${BACKUP_SIZE}"
echo "  目标数据库: ${DB_DATABASE}"
echo ""
read -rp "确认恢复？(y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    info "已取消恢复操作。"
    exit 0
fi

# ----- 执行恢复 -----
info "正在恢复数据库..."
$COMPOSE_CMD exec -T mysql mysql \
    --default-character-set=utf8mb4 \
    -u"${DB_USERNAME}" \
    -p"${DB_PASSWORD}" \
    "${DB_DATABASE}" \
    < "$BACKUP_FILE"

ok "数据库恢复完成！"
echo ""
echo "  恢复来源:  ${BACKUP_FILE}"
echo "  安全备份:  ${SAFETY_BACKUP}"
echo ""
echo "  如需回滚到恢复前的状态:"
echo "    bash restore.sh ${SAFETY_BACKUP}"
