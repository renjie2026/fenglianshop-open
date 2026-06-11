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

### 0. 配置宝塔站点和反向代理

本系统采用**宝塔Nginx（SSL终止）+ Caddy（HTTP反代）**架构：

```
用户浏览器 → 宝塔Nginx(80/443, SSL终止) → Caddy(127.0.0.1:8880, HTTP) → Docker容器
```

**以下操作对3个域名各执行一次：**

| 域名 | 代理名称 | 对应容器 |
|------|---------|---------|
| 管理后台域名（如 `admin.example.com`） | `admin` | admin容器 |
| H5会员端域名（如 `h5.example.com`） | `h5web` | h5容器 |
| API接口域名（如 `api.example.com`） | `api` | nginx-api容器 |

**0.1 添加站点**

宝塔面板 → 网站 → 添加站点 → 填写域名 → PHP版本选"纯静态" → 提交

**0.2 申请SSL证书**

点击站点名称 → SSL → 申请/部署证书（Let's Encrypt 或其他证书）

**0.3 添加反向代理**

点击站点名称右侧的 **设置** → 反向代理 → 添加反向代理：
- 代理名称：填写上表对应的名称（管理后台填 `admin`，H5填 `h5web`，API填 `api`）

> **注意**：宝塔反向代理名称最少3个字符，所以H5填 `h5web` 而非 `h5`。
- 目标URL：`http://127.0.0.1:8880`
- 发送域名：`$host`
- 点击保存

每个域名的站点各添加一次。3个站点全部添加完成后，进入下一步。

### 1. 一键下载部署工具包

在服务器上执行以下命令，自动下载部署工具包到 `/opt/fenglianshop` 目录：

```bash
curl -fsSL https://raw.githubusercontent.com/renjie2026/fenglianshop-open/main/deploy/install.sh | bash
```

> 如果下载缓慢或失败，也可以手动克隆（只下载 deploy 目录，不含源码）：
> ```bash
> cd /opt
> git clone --depth 1 --sparse https://github.com/renjie2026/fenglianshop-open.git fenglianshop-tmp
> cd fenglianshop-tmp && git sparse-checkout set deploy
> cp -r deploy ../fenglianshop && cd .. && rm -rf fenglianshop-tmp
> ```
>
> 克隆时遇到 `HTTP2 framing layer` 错误，使用 HTTP/1.1 重试：
> ```bash
> git -c http.version=HTTP/1.1 clone --depth 1 --sparse https://github.com/renjie2026/fenglianshop-open.git fenglianshop-tmp
> ```

### 2. 配置环境变量

```bash
cd /opt/fenglianshop
cp .env.example .env
```

**必须修改的三项域名配置**（把 `yourdomain.com` 换成你的真实域名）：

| 配置项 | 说明 | 示例 |
|--------|------|------|
| `ADMIN_URL` | 管理后台域名 | `https://admin.example.com` |
| `H5_URL` | H5会员端域名 | `https://h5.example.com` |
| `API_URL` | API接口域名 | `https://api.example.com` |

**方式一：使用 sed 一键替换（推荐）**

```bash
sed -i 's|https://admin.yourdomain.com|https://admin.你的域名.com|g' .env
sed -i 's|https://h5.yourdomain.com|https://h5.你的域名.com|g' .env
sed -i 's|https://api.yourdomain.com|https://api.你的域名.com|g' .env
```

> 将上面三行中的 `你的域名.com` 替换为你实际使用的域名，然后逐行粘贴到终端执行。

**方式二：使用 vim 手动编辑**

```bash
vim .env
```

进入 vim 后的操作步骤：

1. 按 `i` 键进入编辑模式（左下角显示 `-- INSERT --`）
2. 用方向键找到 `ADMIN_URL`、`H5_URL`、`API_URL` 三行
3. 将 `yourdomain.com` 改为你实际的域名
4. 按 `Esc` 键退出编辑模式（左下角 `-- INSERT --` 消失）
5. 输入 `:wq` 然后按 `Enter` 保存并退出

> 如果改错了想放弃保存：按 `Esc`，输入 `:q!` 然后按 `Enter`，重新编辑即可。

**方式三：在宝塔面板中编辑（适合不熟悉 vim 的用户）**

宝塔面板 → 文件 → 进入 `/opt/fenglianshop` 目录 → 找到 `.env` 文件 → 双击打开编辑 → 修改三个域名 → 保存。

> 如果宝塔文件管理器看不到 `.env` 文件，点击右上角"显示隐藏文件"即可。
>
> **备注**：需要先执行上面的 `cd /opt/fenglianshop && cp .env.example .env` 命令，才会从 `.env.example` 复制生成 `.env` 文件。

**验证修改结果：**

```bash
head -5 .env
```

输出应显示三个域名已替换为你的真实域名。

### 3. 一键启动

```bash
bash start.sh
```

脚本会自动完成：环境检查、密码生成、镜像拉取、容器启动、健康检查、备份任务配置。

部署完成后会依次提示：
1. **是否安装自动更新守护进程？**（建议选 Y）
2. **是否执行宝塔反代优化修复脚本？**（建议选 Y，自动修复宝塔反代配置问题）

安装完成后，在管理后台进入`升级与授权 -> 系统升级`，填写授权域名和授权码完成激活。

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
| `CADDY_IMAGE` | 否 | `caddy:2-alpine` | Caddy镜像（国内服务器如拉取失败改为 `caddy:2-alpine`） |
| `BACKUP_RETENTION_DAYS` | 否 | `7` | 备份保留天数 |
| `APP_EDITION` | 否 | `single` | 应用版本（单开版=single） |
| `DEPLOYMENT_MODE` | 否 | `public_dockerhub` | 公开版升级模式 |
| `AGENT_TOOLKIT_DIR` | 否 | `/host/public-update-toolkit` | 容器内宿主机更新工具挂载点 |

---

## 常见问题

### Q1: 域名还没有备案，能用IP直接访问吗？

可以。将 `.env` 中的域名改为 `http://你的IP:端口` 格式，同时需要修改 `HTTP_PORT` 避免端口冲突。注意：使用IP访问时不经过宝塔，无法使用SSL。

### Q2: 国内服务器拉取镜像很慢或超时怎么办？

`start.sh` 会自动检测国内网络并配置 `docker.1panel.live` 镜像加速器，一般情况下无需手动操作。

如果遇到加速器不可用的情况，可手动切换其他镜像源：

**备用镜像源：**
```bash
# 切换为 mirror.baijiayun.com
echo '{"registry-mirrors":["https://mirror.baijiayun.com"]}' > /etc/docker/daemon.json
systemctl daemon-reload && systemctl restart docker
bash start.sh
```

**恢复直连 Docker Hub：**
```bash
echo '{}' > /etc/docker/daemon.json
systemctl daemon-reload && systemctl restart docker
bash start.sh
```

### Q3: 如何更新到新版本？

```bash
# 方式1（推荐）：通过管理后台自动更新
# 1. 确认守护进程已安装
systemctl status fenglianshop-public-update-daemon --no-pager
# 2. 在管理后台进入"升级与授权 → 系统升级"
# 3. 先完成授权激活，再点击"检查更新 / 立即更新"

# 方式2：手动更新
cd /opt/fenglianshop
# 修改 .env 中的 VERSION 为新版本号
vim .env
bash start.sh
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
fenglianshop-open/
├── README.md                  ← 部署安装教程（你正在看的）
├── LICENSE                    ← AGPLv3 许可证
└── deploy/                    ← 部署工具包
    ├── install.sh             ← 一键下载脚本（推荐使用）
    ├── docker-compose.yml     ← Docker Compose 编排文件
    ├── .env.example           ← 环境变量模板
    ├── Dockerfile.caddy       ← Caddy 镜像构建文件
    ├── start.sh               ← 一键部署脚本
    ├── fix-bt-proxy-pass.sh   ← 宝塔反代优化修复脚本
    ├── backup.sh              ← 数据库备份脚本
    ├── restore.sh             ← 数据库恢复脚本
    ├── 部署使用教程.md         ← 完整详细教程
    └── update-toolkit/        ← 公开版宿主机更新守护进程
```

> **部署后的目录结构**（`/opt/fenglianshop`）：
> ```
> /opt/fenglianshop/            ← install.sh 自动创建
> ├── docker-compose.yml
> ├── .env                      ← 环境变量（从 .env.example 复制）
> ├── Caddyfile                 ← 自动生成
> ├── start.sh
> ├── backups/                  ← 备份文件目录（自动创建）
> └── ...
> ```

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
