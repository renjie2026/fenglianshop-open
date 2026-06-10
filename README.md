# 蜂链商城电商新零售管理系统

## 预发布声明

本项目为蜂链商城电商新零售管理系统的公开部署版本。源码计划于 **90天内** 完全公开，当前配置文件和部署脚本以 [AGPLv3 许可证](LICENSE) 发布，供评估和测试使用。

---

## 功能亮点

- **商品管理** - 多规格SKU、库存管理、分类管理、批量操作
- **订单管理** - 全流程订单处理、支付集成、物流追踪、售后管理
- **会员体系** - 会员等级、积分系统、信用评估、经销商管理
- **插件系统** - 模块化插件架构，支持在线安装、卸载、更新
- **Docker一键部署** - 基于Docker Compose，配置域名即可一键启动

---

## 快速安装

### 1. 克隆仓库

```bash
git clone https://github.com/renjie2026/fenglianshop-open.git
cd fenglianshop-open
```

### 2. 配置环境变量

```bash
cp .env.example .env
vim .env
```

**必须修改的配置项：**

| 配置项 | 说明 | 示例 |
|--------|------|------|
| `ADMIN_URL` | 管理后台域名 | `https://admin.example.com` |
| `H5_URL` | H5会员端域名 | `https://h5.example.com` |
| `API_URL` | API接口域名 | `https://api.example.com` |

### 3. 一键启动

```bash
bash start.sh
```

脚本会自动完成：环境检查、密码生成、镜像拉取、容器启动、健康检查、备份任务配置。

首次部署完成后，如需让后台“系统升级”按钮真正执行宿主机拉镜像更新，请继续安装公开版更新守护进程：

```bash
sudo bash ./update-toolkit/install-public-update-daemon.sh
```

安装完成后，在管理后台进入`升级与授权 -> 系统升级`，填写授权域名和授权码完成激活。

### 4. 配置宝塔反向代理（SSL）

本系统采用**宝塔Nginx（SSL终止）+ Caddy（HTTP反代）**架构：

```
用户浏览器 → 宝塔Nginx(80/443, SSL终止) → Caddy(127.0.0.1:8880, HTTP) → Docker容器
```

Caddy只负责HTTP反向代理，SSL证书由宝塔统一管理。

**以下操作对3个域名各执行一次：**

| 域名 | 代理名称 | 对应容器 |
|------|---------|---------|
| 管理后台域名（如 `admin.example.com`） | `admin` | admin容器 |
| H5会员端域名（如 `h5.example.com`） | `h5web` | h5容器 |
| API接口域名（如 `api.example.com`） | `api` | nginx-api容器 |

**4.1 添加站点**

宝塔面板 → 网站 → 添加站点 → 填写域名 → PHP版本选"纯静态" → 提交

**4.2 申请SSL证书**

点击站点名称 → SSL → 申请/部署证书（Let's Encrypt 或其他证书）

**4.3 添加反向代理**

点击站点名称右侧的 **设置** → 反向代理 → 添加反向代理：
- 代理名称：填写上表对应的名称（管理后台填 `admin`，H5填 `h5web`，API填 `api`）

> **注意**：宝塔反向代理名称最少3个字符，所以H5填 `h5web` 而非 `h5`。
- 目标URL：`http://127.0.0.1:8880`
- 发送域名：`$host`
- 点击保存

**4.4 修改配置文件（关键！每个站点都要单独设置）**

对**每个站点**分别执行：点击站点名称右侧的 **设置** → 反向代理 → 点击刚创建的代理名称右侧的**配置文件**，找到 `proxy_set_header REMOTE-HOST $remote_addr;` 这一行，在它**下面**添加：

```nginx
    proxy_set_header X-Forwarded-Proto $scheme;
```

保存。最终配置文件中的关键部分应如下：

```nginx
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header REMOTE-HOST $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
```

**注意事项：**
- `Host` 必须是 `$host`（不能是 `127.0.0.1`），否则 Caddy 无法按域名路由到正确的容器
- `X-Forwarded-Proto $scheme` 必须添加，否则后端不知道是HTTPS，会生成错误的HTTP链接
- 3个站点的反向代理配置完全相同，只有域名不同

---

## 系统要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| **Docker** | 20.10+ | 最新稳定版 |
| **Docker Compose** | v2.0+ | 最新稳定版 |
| **CPU** | 2核 | 4核 |
| **内存** | 4GB | 8GB |
| **磁盘** | 10GB可用 | 20GB+ 可用 |
| **操作系统** | Linux (Ubuntu 20.04+, CentOS 7+) | Ubuntu 22.04 LTS |
| **域名** | 3个子域名 | 已配置SSL |

---

## 默认账号

| 账号 | 密码 | 说明 |
|------|------|------|
| `admin` | `123123` | 管理后台超级管理员 |

> **首次登录后请立即修改默认密码！**

---

## 环境变量说明

| 变量名 | 必填 | 默认值 | 说明 |
|--------|------|--------|------|
| `ADMIN_URL` | 是 | - | 管理后台完整URL (含https://) |
| `H5_URL` | 是 | - | H5会员端完整URL |
| `API_URL` | 是 | - | API接口完整URL |
| `HTTP_PORT` | 否 | `8880` | HTTP端口映射（SSL由宝塔处理） |
| `DB_DATABASE` | 否 | `xinshangcheng003` | 数据库名称 |
| `DB_USERNAME` | 否 | `xinshangcheng` | 数据库用户名 |
| `DB_PASSWORD` | 否 | 自动生成 | 数据库密码（首次运行自动生成） |
| `MYSQL_ROOT_PASSWORD` | 否 | 自动生成 | MySQL root密码 |
| `REDIS_PASSWORD` | 否 | 空 | Redis密码（留空表示无密码） |
| `VERSION` | 否 | 见.env.example | Docker镜像版本tag |
| `CADDY_IMAGE` | 否 | `caddy:2-alpine` | Caddy镜像（国内可切换阿里云） |
| `BACKUP_RETENTION_DAYS` | 否 | `7` | 备份保留天数 |
| `APP_EDITION` | 否 | `single` | 应用版本（单开版=single） |
| `DEPLOYMENT_MODE` | 否 | `public_dockerhub` | 公开版升级模式 |
| `AGENT_TOOLKIT_DIR` | 否 | `/host/public-update-toolkit` | 容器内宿主机更新工具挂载点 |

---

## 常见问题

### Q1: 域名还没有备案，能用IP直接访问吗？

可以。将 `.env` 中的域名改为 `http://你的IP:端口` 格式，同时需要修改 `HTTP_PORT` 避免端口冲突。注意：使用IP访问时不经过宝塔，无法使用SSL。

### Q2: 国内服务器拉取镜像很慢怎么办？

脚本会自动检测国内网络环境并切换阿里云镜像源。如果自动检测失败，可手动在 `.env` 中取消注释：
```
CADDY_IMAGE=registry.cn-hangzhou.aliyuncs.com/library/caddy:2-alpine
```

### Q3: 如何更新到新版本？

```bash
# 1. 确认 update-toolkit 守护进程已安装
systemctl status fenglianshop-public-update-daemon --no-pager

# 2. 在管理后台进入“升级与授权 -> 系统升级”
# 3. 先完成授权激活，再点击“检查更新 / 立即更新”
```

### Q4: 数据库密码忘记了怎么办？

数据库密码保存在 `.env` 文件中，查看即可：
```bash
grep "DB_PASSWORD" .env
```

### Q5: 如何手动备份和恢复数据？

```bash
# 手动备份
bash backup.sh

# 查看可用备份
ls -lh backups/

# 恢复指定备份
bash restore.sh backups/backup_20260531_030000.sql
```

---

## 项目结构

```
.
├── docker-compose.yml    # Docker Compose 编排文件
├── .env.example          # 环境变量模板
├── Caddyfile             # Caddy 反向代理配置（自动生成）
├── start.sh              # 一键部署脚本
├── update-toolkit/       # 公开版宿主机更新守护进程
├── backup.sh             # 数据库备份脚本
├── restore.sh            # 数据库恢复脚本
├── backups/              # 备份文件目录（自动创建）
└── LICENSE               # 许可证文件
```

---

## 许可证

本项目的**配置文件和部署脚本**以 [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE) 发布。

**源代码**计划于 90天内公开，届时将同步以 AGPLv3 发布。

在源码公开之前，本项目仅限用于评估和测试目的。禁止将本项目用于商业生产环境，直至源码完全公开。

---

## 技术支持

- 提交 Issue: [GitHub Issues](https://github.com/renjie2026/fenglianshop-open/issues)

## 运维提醒

- 不要把 Docker Socket 挂载到 API 容器；公开版升级由宿主机 `update-toolkit` 守护进程执行。
- 不要执行 `docker compose down -v`；这会删除数据库卷和 Redis 数据。
- 常规维护优先使用 `docker compose restart`、`docker compose stop`、`docker compose up -d`。
