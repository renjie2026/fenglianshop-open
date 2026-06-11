#!/usr/bin/env bash
# ============================================================
#  蜂链商城 - 一键下载部署工具包
#  用法: curl -fsSL https://raw.githubusercontent.com/renjie2026/fenglianshop-open/main/deploy/install.sh | bash
#  自定义目录: curl -fsSL ... | bash -s -- /data/fenglianshop
# ============================================================
set -euo pipefail

# ----- 颜色 -----
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ----- 配置 -----
INSTALL_DIR="${1:-/opt/fenglianshop}"
REPO_URL="https://github.com/renjie2026/fenglianshop-open.git"

# ----- 1. 检查 git -----
if ! command -v git &>/dev/null; then
    error "git 未安装，请先安装 git。"
    echo "  Ubuntu/Debian: sudo apt install -y git"
    echo "  CentOS/RHEL:   sudo yum install -y git"
    exit 1
fi

ok "git $(git --version | awk '{print $3}')"

# ----- 2. 检查目标目录 -----
if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    error "目标目录已存在且不为空: $INSTALL_DIR"
    echo "  如需重新安装，请先删除旧目录: rm -rf $INSTALL_DIR"
    echo "  如需更新，请进入目录后修改 .env 中的 VERSION 并执行 bash start.sh"
    exit 1
fi

# ----- 3. 下载部署工具包 -----
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "正在下载 fenglianshop 部署工具包到 ${INSTALL_DIR} ..."

# 检查 git 是否支持 sparse checkout（>= 2.25）
GIT_MAJOR=$(git --version | awk '{print $3}' | cut -d. -f1)
GIT_MINOR=$(git --version | awk '{print $3}' | cut -d. -f2)
USE_SPARSE=false

if [ "$GIT_MAJOR" -gt 2 ] || { [ "$GIT_MAJOR" -eq 2 ] && [ "$GIT_MINOR" -ge 25 ]; }; then
    USE_SPARSE=true
fi

if [ "$USE_SPARSE" = true ]; then
    # sparse checkout：只拉取 deploy/ 目录
    git clone --depth 1 --sparse "$REPO_URL" "$TMPDIR/repo"
    cd "$TMPDIR/repo"
    git sparse-checkout set deploy
else
    # 回退：完整浅克隆
    warn "git 版本较低，使用完整克隆（推荐升级 git 到 2.25+）"
    git clone --depth 1 "$REPO_URL" "$TMPDIR/repo"
fi

# ----- 4. 复制部署文件到目标目录 -----
mkdir -p "$INSTALL_DIR"

if [ -d "$TMPDIR/repo/deploy" ]; then
    cp -r "$TMPDIR/repo/deploy/"* "$INSTALL_DIR/"
    for f in "$TMPDIR/repo/deploy/".[!.]*; do
        [ -e "$f" ] && cp -r "$f" "$INSTALL_DIR/"
    done
else
    error "仓库中未找到 deploy/ 目录，可能是仓库结构尚未更新。"
    exit 1
fi

# ----- 5. 验证 -----
if [ ! -f "$INSTALL_DIR/start.sh" ]; then
    error "下载不完整：start.sh 未找到。"
    exit 1
fi

if [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
    error "下载不完整：docker-compose.yml 未找到。"
    exit 1
fi

# 设置脚本可执行权限
chmod +x "$INSTALL_DIR/start.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/fix-bt-proxy-pass.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/backup.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/restore.sh" 2>/dev/null || true

ok "部署工具包下载完成！"

# ----- 6. 提示下一步 -----
echo ""
echo "============================================================"
echo -e "  ${GREEN}下载完成！${NC}"
echo "============================================================"
echo ""
echo "  安装目录: ${INSTALL_DIR}"
echo ""
echo "  接下来执行："
echo ""
echo "    cd ${INSTALL_DIR}"
echo "    cp .env.example .env"
echo "    vim .env            # 修改域名和密码"
echo "    bash start.sh       # 一键启动"
echo ""
echo "============================================================"
