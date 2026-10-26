# AstrBot Shipyard Neo · 2C2G 精简一键部署

为 **2C2G 小鸡** 准备的 [AstrBot Agent 沙盒](https://docs.astrbot.app/use/astrbot-agent-sandbox.html) 部署脚本。

- 驱动：官方推荐的 **Shipyard Neo**
- 场景：**沙盒机与 AstrBot 不在同一台**；本机 **Bitwarden 已在跑**
- 策略：无浏览器 / 无预热池 / 仅 `python-default`
- **可重入**：SSH 断线后用同一条命令再执行，会先检查状态再续跑

## 一键部署（在沙盒机执行）

> **务必带上 `PUBLIC_HOST=VPS公网IP`**。自动探测可能拿到 NAT 出口地址，不是你要给 AstrBot 填的回连 IP。

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | PUBLIC_HOST=你的公网IP bash
```

示例：

```bash
curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | PUBLIC_HOST=107.174.175.25 bash
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

## 防火墙

沙盒机放行 `8114/tcp`，云安全组建议 **只允许 AstrBot 所在机器 IP**。
