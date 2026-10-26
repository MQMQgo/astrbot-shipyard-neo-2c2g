# AstrBot Shipyard Neo · 2C2G 精简一键部署

为 **2C2G 小鸡** 准备的 [AstrBot Agent 沙盒](https://docs.astrbot.app/use/astrbot-agent-sandbox.html) 部署脚本。

- 驱动：官方推荐的 **Shipyard Neo**
- 场景：**沙盒机与 AstrBot 不在同一台**；本机 **Bitwarden 已在跑**
- 策略：无浏览器 / 无预热池 / 仅 `python-default`
- **可重入**：SSH 断线后用同一条命令再执行，会先检查状态再续跑

## 一键部署（在沙盒机执行）

> 脚本会自动获取公网 IP（本机网卡 → 云 metadata → 出口探测）。一般直接跑下面命令即可；只有自动结果不对时才需要 `PUBLIC_HOST=`。

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | PUBLIC_HOST=你的公网IP bash
```

Bitwarden 更吃内存时：

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | SANDBOX_MEM=384m RESERVE_MB=1100 PUBLIC_HOST=你的公网IP bash
```

强制重建（已健康时默认会跳过）：

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | FORCE=1 PUBLIC_HOST=你的公网IP bash
```

## 断线后续跑

拉取镜像或启动时 SSH 断开不要紧。**用同一条命令再执行一次**即可：

1. 检测 Bay 容器 / 健康检查 / 镜像是否已存在  
2. 检测 Bitwarden 容器并按占用上调内存预留  
3. **复用**已有 `.api_key`（不会无故换令牌）  
4. 已健康则只打印 AstrBot 填写项并退出  
5. 镜像已有则跳过 `docker pull`；容器异常则 `compose up` 拉起  

## 部署后填到 AstrBot

路径：`配置文件 → AI → 能力 → 使用电脑能力`

| 配置项 | 填写内容 |
| --- | --- |
| 运行环境 | 第三方沙箱环境（sandbox） |
| 沙箱环境驱动器 | `shipyard_neo` |
| Shipyard Neo API Endpoint | `http://<沙盒机公网IP>:8114` |
| Shipyard Neo 访问令牌 | `~/astrbot-shipyard-neo/.api_key` |
| Shipyard Neo Profile | `python-default` |
| Shipyard Neo Sandbox 存活时间(秒) | `1800` |

脚本结束时会逐项打印，并写入 `~/astrbot-shipyard-neo/astrbot-fill.txt`。


## AstrBot 提示「无法连接」时

脚本本机 `/health` 通过 **不等于** 跨机可达。常见原因：

1. **旧部署只监听了 `127.0.0.1`**（早期脚本默认）。解决：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | FORCE=1 PUBLIC_HOST=你的正确公网IP bash
   ```
   然后看输出里的端口映射应类似 `0.0.0.0:8114`。
2. **云安全组 / 防火墙没放行 8114**。在 **AstrBot 那台机器**执行：
   ```bash
   curl -v --connect-timeout 5 http://你的正确公网IP:8114/health
   ```
   超时就是网络问题，不是 Token 问题。
3. Token 填错：网络通但仍鉴权失败时再核对 `.api_key`。

## 防火墙（一键放行 8114）

在**沙盒机**执行（自动识别 ufw / firewalld / iptables / nftables）：

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/open-8114.sh | sudo bash
```

只允许 AstrBot 机器访问（推荐）：

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/open-8114.sh | sudo SOURCE=AstrBot公网IP bash
```

主机防火墙放行后，若 AstrBot 侧仍超时，再到**云安全组**放行 TCP `8114`（来源建议仅 AstrBot IP）。
