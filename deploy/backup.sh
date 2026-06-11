#!/usr/bin/env bash
# ============================================================
#  蜂链商城 - 数据库备份脚本
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

# ----- 从 .env 读取配置 -----
get_env() {
    grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo ""
}

DB_DATABASE=$(get_env DB_DATABASE)
DB_USERNAME=$(get_env DB_USERNAME)
DB_PASSWORD=$(get_env DB_PASSWORD)
BACKUP_RETENTION_DAYS=$(get_env BACKUP_RETENTION_DAYS)

DB_DATABASE=${DB_DATABASE:-xinshangcheng003}
DB_USERNAME=${DB_USERNAME:-xinshangcheng}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}

# ----- 创建备份目录 -----
BACKUP_DIR="./backups"
mkdir -p "$BACKUP_DIR"

# ----- 生成备份文件名 -----
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/backup_${TIMESTAMP}.sql"

# 检测Docker Compose命令
if docker compose version &>/dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# ----- 执行备份 -----
info "正在备份数据库 ${DB_DATABASE}..."

$COMPOSE_CMD exec -T mysql mysqldump \
    --default-character-set=utf8mb4 \
    -u"${DB_USERNAME}" \
    -p"${DB_PASSWORD}" \
    "${DB_DATABASE}" \
    --single-transaction \
    --quick \
    --lock-tables=false \
    > "$BACKUP_FILE"

if [ ! -s "$BACKUP_FILE" ]; then
    error "备份文件为空，备份可能失败。"
    rm -f "$BACKUP_FILE"
    exit 1
fi

# ----- 显示备份信息 -----
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
ok "备份完成: ${BACKUP_FILE} (${BACKUP_SIZE})"

# ----- 清理旧备份 -----
info "清理 ${BACKUP_RETENTION_DAYS} 天前的旧备份..."
DELETED=0
while IFS= read -r old_file; do
    rm -f "$old_file"
    DELETED=$((DELETED + 1))
done < <(find "$BACKUP_DIR" -name "backup_*.sql" -type f -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null || true)

if [ $DELETED -gt 0 ]; then
    info "已清理 ${DELETED} 个旧备份文件。"
fi

echo ""
echo "备份文件: ${BACKUP_FILE}"
echo "文件大小: ${BACKUP_SIZE}"
echo "保留天数: ${BACKUP_RETENTION_DAYS}"
