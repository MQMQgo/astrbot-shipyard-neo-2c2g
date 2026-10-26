#!/usr/bin/env bash
# AstrBot Shipyard Neo 一键部署（2C2G 小鸡精简版）
# 依据: https://docs.astrbot.app/use/astrbot-agent-sandbox.html
# 场景: 沙盒机与 AstrBot 机器人框架不在同一台设备
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-$HOME/astrbot-shipyard-neo}"
BAY_PORT="${BAY_PORT:-8114}"
# 跨机部署默认监听全部网卡；仅本机联调可设 BIND_HOST=127.0.0.1
BIND_HOST="${BIND_HOST:-0.0.0.0}"
# 可选：手动指定填进 AstrBot 的公网/内网 IP 或域名（不含协议和端口）
# 不填则脚本自动探测
PUBLIC_HOST="${PUBLIC_HOST:-}"
SANDBOX_CPUS="${SANDBOX_CPUS:-0.5}"
SANDBOX_MEM="${SANDBOX_MEM:-512m}"
BAY_CPUS="${BAY_CPUS:-0.3}"
BAY_MEM="${BAY_MEM:-256m}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-600}"
CARGO_LIMIT_MB="${CARGO_LIMIT_MB:-256}"
RESERVE_MB="${RESERVE_MB:-900}"
# AstrBot 配置里的 Sandbox TTL（秒）
SANDBOX_TTL="${SANDBOX_TTL:-1800}"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${GRN}[+]${NC} $*"; }
warn(){ echo -e "${YLW}[!]${NC} $*"; }
err(){ echo -e "${RED}[x]${NC} $*"; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || err "缺少命令: $1"; }

detect_public_host() {
  local h=""
  # 1) 用户指定
  if [[ -n "$PUBLIC_HOST" ]]; then
    echo "$PUBLIC_HOST"
    return
  fi
  # 2) 常见云厂商 metadata / 外网探测
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"
  do
    h=$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '\n\r ' || true)
    if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$h"
      return
    fi
  done
  # 3) 默认路由出口 IP（多半是内网/公网主网卡）
  h=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  if [[ -n "$h" ]]; then
    echo "$h"
    return
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

echo "=============================================="
echo " AstrBot Shipyard Neo · 2C2G 精简一键部署"
echo " 场景: 沙盒机 ≠ AstrBot 机器人机"
echo "=============================================="
echo

need_cmd docker
docker compose version >/dev/null 2>&1 || err "需要 Docker Compose v2（docker compose）"
need_cmd curl
need_cmd openssl

if [[ -r /proc/meminfo ]]; then
  TOTAL_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
  AVAIL_MB=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
  info "当前内存: 总量 ${TOTAL_MB}MB，可用 ${AVAIL_MB}MB"
  if (( TOTAL_MB < 1800 )); then
    warn "总内存低于约 2GB，沙盒高峰时可能和 Bitwarden 抢内存。"
  fi
  HEADROOM=$((AVAIL_MB - RESERVE_MB))
  if (( HEADROOM < 400 )); then
    warn "可用内存扣掉预留 ${RESERVE_MB}MB 后只剩约 ${HEADROOM}MB。"
    warn "建议先关掉不用的容器，或把 SANDBOX_MEM 再降到 384m。"
    read -r -p "仍要继续？[y/N] " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]] || exit 0
  else
    info "按预留 ${RESERVE_MB}MB（系统+Bitwarden）估算，沙盒可用约 ${HEADROOM}MB"
  fi
fi

mkdir -p "$DEPLOY_DIR/bay-cargos"
cd "$DEPLOY_DIR"

if [[ -f .api_key ]]; then
  API_KEY=$(tr -d '\n\r ' < .api_key)
  info "复用已有 API Key（.api_key）"
else
  API_KEY="sk-bay-$(openssl rand -hex 24)"
  umask 077
  printf '%s\n' "$API_KEY" > .api_key
  info "已生成 API Key，保存在 $DEPLOY_DIR/.api_key"
fi

FILL_HOST=$(detect_public_host)
[[ -n "$FILL_HOST" ]] || err "无法探测沙盒机 IP，请用 PUBLIC_HOST=你的公网IP 再运行"
ENDPOINT="http://${FILL_HOST}:${BAY_PORT}"

info "写入精简 config.yaml …"
cat > config.yaml << EOF
# Shipyard Neo · 2C2G 精简配置（跨机接入 AstrBot）
# 官方文档: https://docs.astrbot.app/use/astrbot-agent-sandbox.html

server:
  host: "0.0.0.0"
  port: 8114

database:
  url: "sqlite+aiosqlite:///./data/bay.db"
  echo: false

driver:
  type: docker
  image_pull_policy: if_not_present
  docker:
    socket: "unix:///var/run/docker.sock"
    connect_mode: container_network
    network: "bay-network"
    publish_ports: false
    host_port: null

cargo:
  root_path: "/var/lib/bay/cargos"
  default_size_limit_mb: ${CARGO_LIMIT_MB}
  mount_path: "/workspace"

security:
  api_key: "${API_KEY}"
  allow_anonymous: false

browser_service:
  enabled: false

proxy:
  enabled: false

warm_pool:
  enabled: false
  warmup_queue_workers: 1
  warmup_queue_max_size: 8
  warmup_queue_drop_policy: "drop_newest"
  warmup_queue_drop_alert_threshold: 5
  interval_seconds: 60
  run_on_startup: false

profiles:
  - id: python-default
    description: "Low-resource Python sandbox for 2C2G VPS"
    image: "ghcr.io/astrbotdevs/shipyard-neo-ship:latest"
    runtime_type: ship
    runtime_port: 8123
    resources:
      cpus: ${SANDBOX_CPUS}
      memory: "${SANDBOX_MEM}"
    capabilities:
      - filesystem
      - shell
      - python
    idle_timeout: ${IDLE_TIMEOUT}
    warm_pool_size: 0
    env: {}

gc:
  enabled: true
  run_on_startup: true
  interval_seconds: 180
  instance_id: "bay-2c2g"
  idle_session:
    enabled: true
  expired_sandbox:
    enabled: true
  orphan_cargo:
    enabled: true
  orphan_container:
    enabled: true
EOF

info "写入精简 docker-compose.yaml（跨机监听 ${BIND_HOST}:${BAY_PORT}）…"
cat > docker-compose.yaml << EOF
services:
  bay:
    image: ghcr.io/astrbotdevs/shipyard-neo-bay:latest
    container_name: bay
    restart: unless-stopped
    ports:
      - "${BIND_HOST}:${BAY_PORT}:8114"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./config.yaml:/app/config.yaml:ro
      - bay-data:/app/data
      - ./bay-cargos:/var/lib/bay/cargos
    environment:
      - BAY_CONFIG_FILE=/app/config.yaml
      - BAY_DATA_DIR=/app/data
      - BAY_API_KEY=${API_KEY}
    networks:
      - bay-network
    mem_limit: ${BAY_MEM}
    cpus: ${BAY_CPUS}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8114/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  bay-network:
    name: bay-network
    driver: bridge

volumes:
  bay-data:
    name: bay-data
EOF

# 把要填进 AstrBot 的内容落到文件，方便复制
cat > astrbot-fill.txt << EOF
# 复制到 AstrBot「配置文件 → AI → 能力 → 使用电脑能力」
运行环境=第三方沙箱环境(sandbox)
沙箱环境驱动器=shipyard_neo
Shipyard Neo API Endpoint=${ENDPOINT}
Shipyard Neo 访问令牌=${API_KEY}
Shipyard Neo Profile=python-default
Shipyard Neo Sandbox 存活时间(秒)=${SANDBOX_TTL}
EOF

info "拉取镜像（Bay + Ship；不拉 Gull）…"
docker pull ghcr.io/astrbotdevs/shipyard-neo-bay:latest
docker pull ghcr.io/astrbotdevs/shipyard-neo-ship:latest

info "启动 Bay …"
docker compose up -d

info "等待健康检查 …"
ok=0
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${BAY_PORT}/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
(( ok == 1 )) || err "Bay 健康检查失败，请执行: cd $DEPLOY_DIR && docker compose logs -f bay"

# 防火墙提醒（不自动改规则）
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
  warn "检测到 ufw 已启用：请在沙盒机放行 ${BAY_PORT}/tcp，例如: sudo ufw allow ${BAY_PORT}/tcp"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
  warn "检测到 firewalld：请放行 ${BAY_PORT}/tcp"
fi

echo
echo -e "${CYN}======== 按 AstrBot 配置项填写（跨机） ========${NC}"
echo -e "配置路径: 配置文件 → AI → 能力 → 使用电脑能力"
echo
echo -e "  运行环境"
echo -e "    → ${GRN}第三方沙箱环境（sandbox）${NC}"
echo
echo -e "  沙箱环境驱动器"
echo -e "    → ${GRN}shipyard_neo${NC}"
echo
echo -e "  Shipyard Neo API Endpoint"
echo -e "    → ${GRN}${ENDPOINT}${NC}"
echo
echo -e "  Shipyard Neo 访问令牌"
echo -e "    → ${GRN}${API_KEY}${NC}"
echo
echo -e "  Shipyard Neo Profile"
echo -e "    → ${GRN}python-default${NC}"
echo
echo -e "  Shipyard Neo Sandbox 存活时间(秒)"
echo -e "    → ${GRN}${SANDBOX_TTL}${NC}"
echo
echo -e "${CYN}================================================${NC}"
echo
info "以上内容已写入: $DEPLOY_DIR/astrbot-fill.txt"
info "API Key 文件: $DEPLOY_DIR/.api_key"
echo
warn "安全提醒: 8114 已对公网暴露，务必配合云厂商安全组/防火墙，只允许 AstrBot 所在机器 IP 访问。"
warn "若探测到的 IP 不对，用 PUBLIC_HOST=正确IP 重新执行本脚本即可覆盖配置。"
echo
echo "常用命令:"
echo "  cd $DEPLOY_DIR"
echo "  docker compose logs -f bay"
echo "  docker compose ps"
echo "  docker compose down"
