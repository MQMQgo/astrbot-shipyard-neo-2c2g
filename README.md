# AstrBot Shipyard Neo · 2C2G 精简一键部署

为 **2C2G 小鸡** 准备的 [AstrBot Agent 沙盒](https://docs.astrbot.app/use/astrbot-agent-sandbox.html) 部署脚本。

- 驱动：官方推荐的 **Shipyard Neo**
- 场景：**沙盒机与 AstrBot 不在同一台**
- 策略：无浏览器 / 无预热池 / 仅 `python-default`，给系统和自建 Bitwarden 留内存

## 一键部署（在沙盒机执行）

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | bash
```

指定公网 IP（强烈推荐，便于脚本打印正确的 AstrBot Endpoint）：

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | PUBLIC_HOST=你的公网IP bash
```

Bitwarden 比较吃内存时：

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | SANDBOX_MEM=384m RESERVE_MB=1100 PUBLIC_HOST=你的公网IP bash
```

## 部署后填到 AstrBot

路径：`配置文件 → AI → 能力 → 使用电脑能力`

| 配置项 | 填写内容 |
| --- | --- |
| 运行环境 | 第三方沙箱环境（sandbox） |
| 沙箱环境驱动器 | `shipyard_neo` |
| Shipyard Neo API Endpoint | `http://<沙盒机公网IP>:8114` |
| Shipyard Neo 访问令牌 | 部署目录 `~/astrbot-shipyard-neo/.api_key` |
| Shipyard Neo Profile | `python-default` |
| Shipyard Neo Sandbox 存活时间(秒) | `1800`（默认） |

脚本结束时会逐项打印，并写入 `~/astrbot-shipyard-neo/astrbot-fill.txt`。

## 资源说明

| 项目 | 默认 |
| --- | --- |
| 沙盒单实例 | 0.5 CPU / 512MB |
| Bay 控制面 | 0.3 CPU / 256MB |
| 预留（系统+Bitwarden） | 约 900MB |
| 浏览器 / Gull | 关闭 |
| 预热池 | 关闭 |
| 监听 | `0.0.0.0:8114`（跨机） |

官方建议宿主机 ≥ 4C8G；本仓库是 2C2G 妥协方案，高峰请少并发。

## 防火墙

沙盒机放行 `8114/tcp`，云安全组建议 **只允许 AstrBot 所在机器 IP**。

## 常用命令

```bash
cd ~/astrbot-shipyard-neo
docker compose logs -f bay
docker compose ps
docker compose down
```

## 可选环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PUBLIC_HOST` | 自动探测 | 填进 AstrBot 的沙盒机 IP/域名 |
| `BIND_HOST` | `0.0.0.0` | Bay 监听地址 |
| `BAY_PORT` | `8114` | 端口 |
| `SANDBOX_CPUS` | `0.5` | 沙盒 CPU |
| `SANDBOX_MEM` | `512m` | 沙盒内存 |
| `BAY_CPUS` | `0.3` | Bay CPU |
| `BAY_MEM` | `256m` | Bay 内存 |
| `IDLE_TIMEOUT` | `600` | 空闲回收（秒） |
| `SANDBOX_TTL` | `1800` | 打印给 AstrBot 的 TTL |
| `RESERVE_MB` | `900` | 预留内存告警阈值 |
| `DEPLOY_DIR` | `~/astrbot-shipyard-neo` | 部署目录 |
