#!/usr/bin/env bash
# AstrBot Shipyard Neo 一键部署（2C2G 小鸡精简版）
# 依据: https://docs.astrbot.app/use/astrbot-agent-sandbox.html
# 场景: 沙盒机与 AstrBot 不在同一台；Bitwarden 已在本机 Docker 运行
# 特性: 可重入 / 断线后续跑——每次先检查当前状态再决定下一步
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-$HOME/astrbot-shipyard-neo}"
BAY_PORT="${BAY_PORT:-8114}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
SANDBOX_CPUS="${SANDBOX_CPUS:-0.5}"
SANDBOX_MEM="${SANDBOX_MEM:-512m}"
BAY_CPUS="${BAY_CPUS:-0.3}"
BAY_MEM="${BAY_MEM:-256m}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-600}"
CARGO_LIMIT_MB="${CARGO_LIMIT_MB:-256}"
# Bitwarden 已在跑：默认多留一点；可用 RESERVE_MB 覆盖
RESERVE_MB="${RESERVE_MB:-1000}"
SANDBOX_TTL="${SANDBOX_TTL:-1800}"
# FORCE=1 时即使已健康也重写配置并 recreate
FORCE="${FORCE:-0}"
BAY_IMAGE="ghcr.io/astrbotdevs/shipyard-neo-bay:latest"
SHIP_IMAGE="ghcr.io/astrbotdevs/shipyard-neo-ship:latest"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
info(){ echo -e "${GRN}[+]${NC} $*"; }
warn(){ echo -e "${YLW}[!]${NC} $*"; }
err(){ echo -e "${RED}[x]${NC} $*"; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || err "缺少命令: $1"; }

is_tty(){ [[ -t 0 ]]; }

confirm_or_auto() {
  local prompt="$1"
  if is_tty; then
    read -r -p "$prompt [y/N] " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]]
  else
    warn "非交互环境（例如 curl|bash 或 SSH 已断后重连管道），自动继续。"
    return 0
  fi
}

is_private_ip() {
  # 10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, 100.64/10(CGNAT)
  local ip="$1" a b
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  a=${ip%%.*}; b=${ip#*.}; b=${b%%.*}
  (( a == 10 )) && return 0
  (( a == 127 )) && return 0
  (( a == 192 && b == 168 )) && return 0
  (( a == 169 && b == 254 )) && return 0
  (( a == 172 && b >= 16 && b <= 31 )) && return 0
  (( a == 100 && b >= 64 && b <= 127 )) && return 0
  return 1
}

list_local_ipv4() {
  # 本机网卡 IPv4，排除 lo / docker / br- / veth
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '{
        iface=$2; gsub(/\/.*$/,"",$4); ip=$4;
        if (iface ~ /^(lo|docker|br-|veth|virbr|cni|flannel)/) next;
        print ip;
      }' || true
}

detect_egress_ip() {
  local h="" url
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
}

detect_public_host() {
  local h="" cand="" picked="" egress=""
  local -a locals=() publics=()

  # 1) 用户显式指定：最高优先，绝不覆盖
  if [[ -n "$PUBLIC_HOST" ]]; then
    echo "$PUBLIC_HOST"
    return
  fi

  mapfile -t locals < <(list_local_ipv4 | awk 'NF' | awk '!seen[$0]++')
  for cand in "${locals[@]}"; do
    if ! is_private_ip "$cand"; then
      publics+=("$cand")
    fi
  done

  egress=$(detect_egress_ip || true)

  echo -e "${CYN}---- IP 候选 ----${NC}" >&2
  if ((${#locals[@]})); then
    echo -e "  本机网卡: ${locals[*]}" >&2
  else
    echo -e "  本机网卡: (无)" >&2
  fi
  echo -e "  出口探测: ${egress:-失败}" >&2
  if [[ -f "$DEPLOY_DIR/.public_host" ]]; then
    echo -e "  上次缓存: $(tr -d '\n\r ' < "$DEPLOY_DIR/.public_host")" >&2
  fi

  # 2) 本机网卡上的公网 IP（VPS 主 IP 通常在这里，比出口探测更可信）
  if ((${#publics[@]} == 1)); then
    picked="${publics[0]}"
    echo -e "  选用: ${picked}（本机公网网卡）" >&2
  elif ((${#publics[@]} > 1)); then
    # 若出口 IP 正好落在候选里，用它；否则用第一个并警告
    picked="${publics[0]}"
    for cand in "${publics[@]}"; do
      if [[ -n "$egress" && "$cand" == "$egress" ]]; then
        picked="$cand"
        break
      fi
    done
    echo -e "  选用: ${picked}（多块公网网卡，可用 PUBLIC_HOST= 指定）" >&2
    echo -e "  全部公网候选: ${publics[*]}" >&2
  fi

  # 3) 出口探测：仅当与本机公网一致，或本机没有公网网卡时才用
  if [[ -z "$picked" && -n "$egress" ]]; then
    if ! is_private_ip "$egress"; then
      # 出口 IP 不在本机网卡上时，多半是 NAT/CDN，跨机回连会错
      local on_nic=0
      for cand in "${locals[@]}"; do
        [[ "$cand" == "$egress" ]] && on_nic=1 && break
      done
      if (( on_nic == 1 )); then
        picked="$egress"
        echo -e "  选用: ${picked}（出口探测且在本机网卡上）" >&2
      else
        echo -e "  ${YLW}[!]${NC} 出口 IP ${egress} 不在本机网卡上（可能是 NAT），不采用。" >&2
      fi
    fi
  fi

  # 4) 上次缓存（必须是公网且仍挂在本机网卡上）
  if [[ -z "$picked" && -f "$DEPLOY_DIR/.public_host" ]]; then
    h=$(tr -d '\n\r ' < "$DEPLOY_DIR/.public_host")
    if [[ -n "$h" ]] && ! is_private_ip "$h"; then
      for cand in "${locals[@]}"; do
        if [[ "$cand" == "$h" ]]; then
          picked="$h"
          echo -e "  选用: ${picked}（缓存且仍在本机网卡）" >&2
          break
        fi
      done
    fi
  fi

  # 5) 实在没有：给出明确错误，要求 PUBLIC_HOST
  if [[ -z "$picked" ]]; then
    echo -e "  ${RED}[x]${NC} 未能可靠确定 VPS 公网 IP。" >&2
    echo -e "  请用: PUBLIC_HOST=你的VPS公网IP bash ..." >&2
    return 1
  fi

  echo -e "${CYN}----------------${NC}" >&2
  echo "$picked"
}

image_present() {
  docker image inspect "$1" >/dev/null 2>&1
}

container_status() {
  # running / exited / restarting / ""(不存在)
  docker inspect -f '{{.State.Status}}' bay 2>/dev/null || true
}

bay_healthy_http() {
  curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:${BAY_PORT}/health" >/dev/null 2>&1
}

detect_bitwarden() {
  # 匹配常见自建：vaultwarden / bitwarden / bwdata 相关容器
  docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
    | grep -Eiq 'vaultwarden|bitwarden|bw-' && return 0
  return 1
}

bitwarden_mem_mb() {
  local ids total=0 usage
  ids=$(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null \
    | awk 'BEGIN{IGNORECASE=1} /vaultwarden|bitwarden|bw-/ {print $1}')
  [[ -z "$ids" ]] && { echo 0; return; }
  for id in $ids; do
    usage=$(docker stats --no-stream --format '{{.MemUsage}}' "$id" 2>/dev/null | awk '{print $1}' || true)
    case "$usage" in
      *GiB|*GB) total=$(awk -v t="$total" -v u="${usage%%G*}" 'BEGIN{printf "%d", t+u*1024}') ;;
      *MiB|*MB) total=$(awk -v t="$total" -v u="${usage%%M*}" 'BEGIN{printf "%d", t+u}') ;;
    esac
  done
  echo "$total"
}

pull_with_retry() {
  local img="$1" i
  if image_present "$img"; then
    info "镜像已存在，跳过拉取: $img"
    return 0
  fi
  for i in 1 2 3 4 5; do
    info "拉取镜像 ($i/5): $img"
    if docker pull "$img"; then
      return 0
    fi
    warn "拉取失败，20 秒后重试（SSH 断线可重新执行本脚本，会从这里续跑）"
    sleep 20
  done
  err "镜像拉取失败: $img"
}

write_fill_file() {
  local endpoint="$1" key="$2"
  cat > "$DEPLOY_DIR/astrbot-fill.txt" << EOF
# 复制到 AstrBot「配置文件 → AI → 能力 → 使用电脑能力」
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
运行环境=第三方沙箱环境(sandbox)
沙箱环境驱动器=shipyard_neo
Shipyard Neo API Endpoint=${endpoint}
Shipyard Neo 访问令牌=${key}
Shipyard Neo Profile=python-default
Shipyard Neo Sandbox 存活时间(秒)=${SANDBOX_TTL}
EOF
}

print_astrbot_fill() {
  local endpoint="$1" key="$2"
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
  echo -e "    → ${GRN}${endpoint}${NC}"
  echo
  echo -e "  Shipyard Neo 访问令牌"
  echo -e "    → ${GRN}${key}${NC}"
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
  warn "安全提醒: ${BAY_PORT} 已对公网暴露，务必配合云厂商安全组/防火墙，只允许 AstrBot 所在机器 IP 访问。"
  echo
  echo "常用命令:"
  echo "  cd $DEPLOY_DIR"
  echo "  docker compose logs -f bay"
  echo "  docker compose ps"
  echo "  docker compose down"
  echo
  echo "断线后续跑（同一条命令即可）:"
  echo "  curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/install.sh | PUBLIC_HOST=${FILL_HOST:-你的公网IP} bash"
}

write_configs() {
  local api_key="$1"
  cat > "$DEPLOY_DIR/config.yaml" << EOF
# Shipyard Neo · 2C2G 精简配置（跨机接入 AstrBot）
# Bitwarden 已在本机运行，已关闭浏览器/预热池并压低资源
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
  api_key: "${api_key}"
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
    image: "${SHIP_IMAGE}"
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

  cat > "$DEPLOY_DIR/docker-compose.yaml" << EOF
services:
  bay:
    image: ${BAY_IMAGE}
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
      - BAY_API_KEY=${api_key}
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
}

# ── main ──────────────────────────────────────────────
echo "=============================================="
echo " AstrBot Shipyard Neo · 2C2G 精简一键部署"
echo " 场景: 沙盒机 ≠ AstrBot；Bitwarden 已在跑"
echo " 特性: 先检查状态，可断线后续跑"
echo "=============================================="
echo

need_cmd docker
docker compose version >/dev/null 2>&1 || err "需要 Docker Compose v2（docker compose）"
need_cmd curl
need_cmd openssl
docker info >/dev/null 2>&1 || err "Docker 守护进程不可用"

mkdir -p "$DEPLOY_DIR/bay-cargos"
cd "$DEPLOY_DIR"

# ── 0) 状态总览 ──
echo -e "${CYN}---- 当前状态检查 ----${NC}"
STATUS=$(container_status)
if [[ -n "$STATUS" ]]; then
  info "Bay 容器状态: $STATUS"
else
  info "Bay 容器: 不存在"
fi
if bay_healthy_http; then
  info "本机健康检查: 通过 (http://127.0.0.1:${BAY_PORT}/health)"
  HEALTHY=1
else
  info "本机健康检查: 未通过"
  HEALTHY=0
fi
image_present "$BAY_IMAGE" && info "Bay 镜像: 已就绪" || info "Bay 镜像: 未就绪"
image_present "$SHIP_IMAGE" && info "Ship 镜像: 已就绪" || info "Ship 镜像: 未就绪"

BW_FOUND=0
if detect_bitwarden; then
  BW_FOUND=1
  BW_MB=$(bitwarden_mem_mb)
  info "已检测到 Bitwarden/Vaultwarden 容器在运行（当前约占用 ${BW_MB}MB）"
  # 实测占用 + 系统余量；不低于 RESERVE_MB
  NEED_RESERVE=$((BW_MB + 500))
  if (( NEED_RESERVE > RESERVE_MB )); then
    RESERVE_MB=$NEED_RESERVE
    info "按 Bitwarden 实测占用上调预留到 ${RESERVE_MB}MB"
  else
    info "内存预留: ${RESERVE_MB}MB（系统 + Bitwarden）"
  fi
else
  warn "未在 docker ps 里匹配到 Bitwarden/Vaultwarden 名称；仍按预留 ${RESERVE_MB}MB 处理。"
fi

if [[ -r /proc/meminfo ]]; then
  TOTAL_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
  AVAIL_MB=$(awk '/MemAvailable/{printf "%d",$2/1024}' /proc/meminfo)
  info "内存: 总量 ${TOTAL_MB}MB，可用 ${AVAIL_MB}MB"
  HEADROOM=$((AVAIL_MB - RESERVE_MB))
  if (( HEADROOM < 400 )); then
    warn "扣掉预留后余量约 ${HEADROOM}MB，偏紧。可用 SANDBOX_MEM=384m 再跑。"
    if ! confirm_or_auto "内存偏紧，仍继续？"; then
      exit 0
    fi
  else
    info "扣掉预留后估算沙盒余量约 ${HEADROOM}MB"
  fi
fi
echo -e "${CYN}----------------------${NC}"
echo

# API Key：永远优先复用，避免断线重跑换密钥导致 AstrBot 配错
if [[ -f .api_key ]]; then
  API_KEY=$(tr -d '\n\r ' < .api_key)
  info "复用已有 API Key（.api_key）"
elif [[ -f config.yaml ]] && grep -q 'api_key:' config.yaml; then
  API_KEY=$(awk -F'"' '/api_key:/{print $2; exit}' config.yaml)
  if [[ -n "$API_KEY" && "$API_KEY" != "CHANGE-ME" ]]; then
    umask 077
    printf '%s\n' "$API_KEY" > .api_key
    info "从 config.yaml 恢复 API Key 到 .api_key"
  fi
fi
if [[ -z "${API_KEY:-}" ]]; then
  API_KEY="sk-bay-$(openssl rand -hex 24)"
  umask 077
  printf '%s\n' "$API_KEY" > .api_key
  info "已生成新 API Key → $DEPLOY_DIR/.api_key"
fi

if ! FILL_HOST=$(detect_public_host); then
  err "无法可靠确定 VPS 公网 IP。请显式指定：PUBLIC_HOST=你的VPS公网IP"
fi
[[ -n "$FILL_HOST" ]] || err "无法可靠确定 VPS 公网 IP。请显式指定：PUBLIC_HOST=你的VPS公网IP"
if is_private_ip "$FILL_HOST"; then
  err "当前选中的是内网地址 ${FILL_HOST}，跨机 AstrBot 无法访问。请用 PUBLIC_HOST=VPS公网IP 重跑。"
fi
# 仅在用户指定或探测成功后写入缓存
printf '%s\n' "$FILL_HOST" > "$DEPLOY_DIR/.public_host"
ENDPOINT="http://${FILL_HOST}:${BAY_PORT}"
info "AstrBot Endpoint 将使用: ${ENDPOINT}"

# ── 已健康：默认只打印配置并退出 ──
if [[ "$HEALTHY" == "1" && "$FORCE" != "1" ]]; then
  info "Bay 已在健康运行。跳过拉取/重启（需要重建请加 FORCE=1）。"
  write_fill_file "$ENDPOINT" "$API_KEY"
  print_astrbot_fill "$ENDPOINT" "$API_KEY"
  exit 0
fi

# ── 容器存在但未健康：尝试拉起 ──
if [[ -n "$STATUS" && "$STATUS" != "running" && -f docker-compose.yaml ]]; then
  warn "发现已有 Bay 容器（状态=$STATUS），尝试 docker compose up -d 拉起…"
fi

info "写入/更新配置文件…"
write_configs "$API_KEY"
write_fill_file "$ENDPOINT" "$API_KEY"

# 标记进度，方便判断断在哪一步
STATE_FILE="$DEPLOY_DIR/.deploy_state"
mark(){ printf '%s\n' "$1" > "$STATE_FILE"; info "进度标记: $1"; }

PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "none")
info "上次进度: $PREV_STATE"

mark "pulling"
pull_with_retry "$BAY_IMAGE"
pull_with_retry "$SHIP_IMAGE"
mark "images_ready"

mark "starting"
info "启动 / 更新 Bay …"
docker compose up -d
mark "started"

info "等待健康检查 …"
ok=0
for i in $(seq 1 45); do
  if bay_healthy_http; then
    ok=1
    break
  fi
  # 容器若反复退出，提前报错
  st=$(container_status)
  if [[ "$st" == "exited" || "$st" == "dead" ]]; then
    warn "Bay 容器状态=$st，打印最近日志："
    docker compose logs --tail=80 bay || true
    err "Bay 启动失败。修好后重新执行同一条一键命令即可续跑。"
  fi
  sleep 2
done
(( ok == 1 )) || {
  docker compose logs --tail=80 bay || true
  err "健康检查超时。SSH 断线后重跑同一条命令会先检查状态再续。"
}
mark "healthy"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
  warn "检测到 ufw 已启用：请放行 ${BAY_PORT}/tcp，例如: sudo ufw allow ${BAY_PORT}/tcp"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
  warn "检测到 firewalld：请放行 ${BAY_PORT}/tcp"
fi

print_astrbot_fill "$ENDPOINT" "$API_KEY"
