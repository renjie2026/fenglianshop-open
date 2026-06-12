#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  修复宝塔反代配置 — 公开版部署专用
#  修复内容：
#    1. 去除 proxy_pass 末尾自动添加的 "/" (URI截断问题)
#    2. 确保 proxy_set_header Host $host 存在 (非127.0.0.1)
#    3. 添加 proxy_set_header X-Forwarded-Proto $scheme (Laravel生成HTTPS URL)
#
#  适用场景：宝塔Nginx → Caddy(127.0.0.1:8880) → Docker容器
#  目标域名：从脚本同目录的 .env 文件中读取
#    ADMIN_URL / H5_URL / API_URL
#
#  用法：
#    chmod +x fix-bt-proxy-pass.sh
#    ./fix-bt-proxy-pass.sh
#    ./fix-bt-proxy-pass.sh --dry-run
# ============================================================

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  echo "[模式] dry-run：仅预览，不做任何修改"
  echo ""
fi

BT_PROXY_ROOT="/www/server/panel/vhost/nginx/proxy"
TARGET_PORT="8880"

# 从脚本同目录的 .env 文件中读取域名
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[错误] 未找到 .env 文件：$ENV_FILE" >&2
  echo "        请在脚本同目录下创建 .env 文件，配置以下项：" >&2
  echo '        ADMIN_URL=https://admin.yourdomain.com' >&2
  echo '        H5_URL=https://h5.yourdomain.com' >&2
  echo '        API_URL=https://api.yourdomain.com' >&2
  exit 1
fi

# 从 URL 中提取域名（去除协议前缀）
extract_domain() {
  local url="$1"
  echo "$url" | sed -E 's#^https?://##' | sed -E 's#/.*$##'
}

ADMIN_DOMAIN=$(grep -E "^ADMIN_URL=" "$ENV_FILE" | tail -1 | cut -d'=' -f2-)
H5_DOMAIN=$(grep -E "^H5_URL=" "$ENV_FILE" | tail -1 | cut -d'=' -f2-)
API_DOMAIN=$(grep -E "^API_URL=" "$ENV_FILE" | tail -1 | cut -d'=' -f2-)

ADMIN_DOMAIN=$(extract_domain "$ADMIN_DOMAIN")
H5_DOMAIN=$(extract_domain "$H5_DOMAIN")
API_DOMAIN=$(extract_domain "$API_DOMAIN")

DOMAINS=()
[[ -n "$ADMIN_DOMAIN" ]] && DOMAINS+=("$ADMIN_DOMAIN")
[[ -n "$H5_DOMAIN" ]] && DOMAINS+=("$H5_DOMAIN")
[[ -n "$API_DOMAIN" ]] && DOMAINS+=("$API_DOMAIN")

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "[错误] .env 文件中未找到有效的域名配置" >&2
  echo "        请确认 ADMIN_URL / H5_URL / API_URL 已填写" >&2
  exit 1
fi

echo "[信息] 从 .env 读取到 ${#DOMAINS[@]} 个域名："
for d in "${DOMAINS[@]}"; do
  echo "        $d"
done
echo ""

if [[ ! -d "$BT_PROXY_ROOT" ]]; then
  echo "[错误] 未发现宝塔 proxy 目录：$BT_PROXY_ROOT" >&2
  echo "        请确认已安装宝塔面板并在面板中配置了反向代理" >&2
  exit 1
fi

changed=0
backup_ts=$(date +%Y%m%d-%H%M%S)

for domain in "${DOMAINS[@]}"; do
  dir="$BT_PROXY_ROOT/$domain"
  if [[ ! -d "$dir" ]]; then
    echo "[跳过] 未找到域名 proxy 目录：$dir"
    echo "        请先在宝塔面板中为 $domain 添加反向代理"
    continue
  fi

  shopt -s nullglob
  files=("$dir"/*.conf)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "[跳过] 目录下无 .conf 文件：$dir"
    continue
  fi

  echo "[信息] 扫描域名：$domain"

  for f in "${files[@]}"; do
    file_changed=0
    echo "  文件：$f"

    # --- 修复1: 去除 proxy_pass 末尾的 / ---
    # 宝塔自动生成: proxy_pass http://127.0.0.1:8880/;
    # 正确应为:     proxy_pass http://127.0.0.1:8880;
    if grep -qE "proxy_pass[[:space:]]+http://127\.0\.0\.1:${TARGET_PORT}/;" "$f"; then
      echo "    [命中] proxy_pass 末尾有多余的 /"
      echo "           $(grep -nE "proxy_pass[[:space:]]+http://127\.0\.0\.1:${TARGET_PORT}/;" "$f")"
      if [[ "$DRY_RUN" == "0" ]]; then
        cp -a "$f" "$f.bak-$backup_ts"
        sed -i -E "s#proxy_pass[[:space:]]+http://127\.0\.0\.1:${TARGET_PORT}/;#proxy_pass http://127.0.0.1:${TARGET_PORT};#g" "$f"
        file_changed=1
        echo "    [已修复] 去除末尾 /"
      fi
    else
      echo "    [正常] proxy_pass 无末尾 /"
    fi

    # --- 修复2: 确保 Host 头为 $host ---
    # 宝塔有时会把 Host 设为 127.0.0.1，导致Caddy无法按域名路由
    if grep -qE "proxy_set_header[[:space:]]+Host[[:space:]]+127\.0\.0\.1" "$f"; then
      echo "    [命中] Host 头为 127.0.0.1（错误）"
      if [[ "$DRY_RUN" == "0" ]]; then
        [[ "$file_changed" == "0" ]] && cp -a "$f" "$f.bak-$backup_ts"
        sed -i -E "s#proxy_set_header[[:space:]]+Host[[:space:]]+127\.0\.0\.1#proxy_set_header Host \$host#g" "$f"
        file_changed=1
        echo "    [已修复] Host 127.0.0.1 → \$host"
      fi
    else
      echo "    [正常] Host 头配置正确"
    fi

    # --- 修复3: 添加 X-Forwarded-Proto 头 ---
    # Laravel 需要此头才能生成 HTTPS 的 URL（如登录回调、API响应中的链接）
    if ! grep -qE "proxy_set_header[[:space:]]+X-Forwarded-Proto" "$f"; then
      echo "    [缺失] 未找到 X-Forwarded-Proto 头"
      if [[ "$DRY_RUN" == "0" ]]; then
        [[ "$file_changed" == "0" ]] && cp -a "$f" "$f.bak-$backup_ts"
        # 在 proxy_pass 行之前插入
        sed -i -E "/proxy_pass[[:space:]]+http:\/\/127\.0\.0\.1:${TARGET_PORT}/i\\    proxy_set_header X-Forwarded-Proto \$scheme;" "$f"
        file_changed=1
        echo "    [已添加] X-Forwarded-Proto \$scheme"
      fi
    else
      echo "    [正常] X-Forwarded-Proto 已存在"
    fi

    # --- 修复4: 确保 Host $host 存在（即使不是127.0.0.1也可能缺失） ---
    if ! grep -qE "proxy_set_header[[:space:]]+Host[[:space:]]+\\\$host" "$f"; then
      echo "    [缺失] 未找到 Host \$host"
      if [[ "$DRY_RUN" == "0" ]]; then
        [[ "$file_changed" == "0" ]] && cp -a "$f" "$f.bak-$backup_ts"
        sed -i -E "/proxy_pass[[:space:]]+http:\/\/127\.0\.0\.1:${TARGET_PORT}/i\\    proxy_set_header Host \$host;" "$f"
        file_changed=1
        echo "    [已添加] Host \$host"
      fi
    fi

    if [[ "$file_changed" == "1" ]]; then
      changed=1
    fi
    echo ""
  done
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "============================================"
  echo "[完成] dry-run 预览结束：未做任何修改。"
  echo "       确认无误后去掉 --dry-run 参数再执行。"
  echo "============================================"
  exit 0
fi

if [[ "$changed" -eq 0 ]]; then
  echo "[完成] 所有配置均正常，无需修复。"
  exit 0
fi

echo "[信息] 正在验证 Nginx 配置..."
nginx -t && nginx -s reload

echo ""
echo "============================================"
echo "[完成] 修复完毕！已自动重载 Nginx。"
echo "       备份文件：*.bak-$backup_ts"
echo ""
echo "恭喜部署成功，欢迎使用蜂链商城电商新零售系统。"
echo "容器已经全部部署成功，正在初始化中，首次部署成功后请等待1~3分钟后再登录管理后台使用系统。"
echo ""
echo "请测试以下地址："
[[ -n "$ADMIN_DOMAIN" ]] && echo "  管理后台: https://$ADMIN_DOMAIN"
[[ -n "$H5_DOMAIN" ]]   && echo "  H5会员端: https://$H5_DOMAIN"
[[ -n "$API_DOMAIN" ]]  && echo "  API接口:  https://$API_DOMAIN"
echo "============================================"
