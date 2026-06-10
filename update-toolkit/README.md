# 公开版 update-toolkit

`update-toolkit/` 用于公开版部署后的宿主机更新执行链路。

## 目录说明

- `public-update-daemon.sh`：监听 `.queue/.trigger`，串行触发更新。
- `public-update.sh`：校验命令、写入 `.env` 中的 `VERSION` / `APP_VERSION`，然后执行 `docker compose pull` 和 `docker compose up -d`。
- `install-public-update-daemon.sh`：初始化 `.queue`、`logs`，安装并启动 systemd 服务。
- `public-update-daemon.service`：systemd 模板文件。

## 设计边界

- 公开版只支持 Docker Hub 公开仓库。
- 只处理四个业务镜像：`api`、`admin`、`h5`、`nginx-api`。
- API 容器只负责写入 `.queue/commands.json` 和 `.queue/.trigger`，不挂载 Docker Socket。

## 安装

在 `public-release-files/` 目录完成首次部署后执行：

```bash
sudo bash ./update-toolkit/install-public-update-daemon.sh
```

安装完成后可用以下命令检查：

```bash
systemctl status fenglianshop-public-update-daemon --no-pager
journalctl -u fenglianshop-public-update-daemon -f
```

运行要求：

- 宿主机需安装 `docker compose` 或 `docker-compose`。
- 宿主机需提供 `jq` 或 `python3` 其中之一，用于解析队列 JSON。

## 队列文件

初始化后的 `.queue/commands.json` 结构：

```json
{
  "commands": [],
  "processing": false
}
```

触发方式为把命令 ID 写入 `.queue/.trigger`。daemon 收到后会读取 `commands.json` 中对应命令并更新状态。

## 手动执行

如果需要手动重试某个命令：

```bash
bash ./update-toolkit/public-update.sh cmd_xxx
```

## 安全提醒

- 不要把 Docker Socket 挂载进 API 容器。
- 不要执行 `docker compose down -v`，否则会删除 MySQL / Redis 数据卷。
- 守护进程只会处理 `api`、`admin`、`h5`、`nginx-api` 四个公开版镜像。
