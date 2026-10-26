#!/usr/bin/env bash
# 一键放行 Bay 端口 8114（在沙盒机执行）
#
#   curl -fsSL https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main/open-8114.sh | sudo bash
#   curl -fsSL .../open-8114.sh | sudo SOURCE=AstrBot公网IP bash   # 仅允许该 IP
#   PORT=8114 SOURCE=1.2.3.4/32 bash open-8114.sh
set -euo pipefail

PORT="${PORT:-8114}"
SOURCE="${SOURCE:-}"     # 空 = 任意；IP 或 CIDR
PROTO="${PROTO:-tcp}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main}"

# curl|bash 且非 root：重新下载到临时文件再 sudo（保留环境变量）
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "请用 root 执行：curl -fsSL ${RAW_BASE}/open-8114.sh | bash" >&2
    exit 1
  fi
  _tmp="$(mktemp)"
  trap 'rm -f "$_tmp"' EXIT
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    cp "${BASH_SOURCE[0]}" "$_tmp"
  else
    curl -fsSL "$RAW_BASE/open-8114.sh" -o "$_tmp"
  fi
  chmod +x "$_tmp"
  exec sudo -E env PORT="$PORT" SOURCE="$SOURCE" PROTO="$PROTO" RAW_BASE="$RAW_BASE" bash "$_tmp"
fi

echo "=== 放行 Shipyard Bay ${PORT}/${PROTO} ==="
if [[ -n "$SOURCE" ]]; then
  echo "来源限制: ${SOURCE}"
else
  echo "来源: 任意（建议稍后改成只允许 AstrBot IP）"
fi

cidr_of() {
  local x="$1"
  [[ "$x" == */* ]] && echo "$x" || echo "${x}/32"
}

open_ufw() {
  echo "→ 使用 ufw"
  if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo "  ufw 未启用，先放行 SSH 再 enable"
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
  fi
  if [[ -n "$SOURCE" ]]; then
    local from
    from="$(cidr_of "$SOURCE")"
    if ufw status 2>/dev/null | grep -E "^${PORT}/${PROTO}" | grep -qF "$SOURCE"; then
      echo "  规则已存在：${PORT}/${PROTO} from ${from}"
    else
      ufw allow from "$from" to any port "$PORT" proto "$PROTO" comment "astrbot-shipyard-bay"
      echo "  已添加：allow from ${from} → ${PORT}/${PROTO}"
    fi
  else
    if ufw status 2>/dev/null | grep -qE "^${PORT}/${PROTO}[[:space:]]+ALLOW"; then
      echo "  规则已存在：${PORT}/${PROTO}"
    else
      ufw allow "${PORT}/${PROTO}" comment "astrbot-shipyard-bay"
      echo "  已添加：allow ${PORT}/${PROTO}"
    fi
  fi
  ufw reload >/dev/null 2>&1 || true
  echo "  相关规则："
  ufw status | grep -E "${PORT}|Status" || true
}

open_firewalld() {
  echo "→ 使用 firewalld"
  local zone
  zone="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
  if [[ -n "$SOURCE" ]]; then
    local from
    from="$(cidr_of "$SOURCE")"
    firewall-cmd --permanent --zone="$zone" \
      --add-rich-rule="rule family=ipv4 source address=${from} port port=${PORT} protocol=${PROTO} accept" >/dev/null
    echo "  已添加 rich rule：${from} → ${PORT}/${PROTO} (zone=${zone})"
  else
    firewall-cmd --permanent --zone="$zone" --add-port="${PORT}/${PROTO}" >/dev/null
    echo "  已添加：${PORT}/${PROTO} (zone=${zone})"
  fi
  firewall-cmd --reload >/dev/null
  firewall-cmd --zone="$zone" --list-ports 2>/dev/null || true
  firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null | grep -F "$PORT" || true
}

open_iptables() {
  echo "→ 使用 iptables"
  if [[ -n "$SOURCE" ]]; then
    local from
    from="$(cidr_of "$SOURCE")"
    if iptables -C INPUT -s "$from" -p "$PROTO" --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
      echo "  规则已存在：${from} → ${PORT}/${PROTO}"
    else
      iptables -I INPUT -s "$from" -p "$PROTO" --dport "$PORT" -j ACCEPT \
        -m comment --comment "astrbot-shipyard-bay" 2>/dev/null \
        || iptables -I INPUT -s "$from" -p "$PROTO" --dport "$PORT" -j ACCEPT
      echo "  已插入：ACCEPT ${from} → ${PORT}/${PROTO}"
    fi
  else
    if iptables -C INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
      echo "  规则已存在：${PORT}/${PROTO}"
    else
      iptables -I INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT \
        -m comment --comment "astrbot-shipyard-bay" 2>/dev/null \
        || iptables -I INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT
      echo "  已插入：ACCEPT ${PORT}/${PROTO}"
    fi
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    [[ -d /etc/sysconfig ]] && iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
  fi
  iptables -L INPUT -n --line-numbers 2>/dev/null | grep -E "${PORT}|Chain" | head -20 || true
}

open_nft() {
  echo "→ 使用 nftables"
  local table="inet filter" chain="input"
  if ! nft list tables 2>/dev/null | grep -q "table inet filter"; then
    if nft list tables 2>/dev/null | grep -q "table ip filter"; then
      table="ip filter"
    else
      nft add table inet filter 2>/dev/null || true
      nft 'add chain inet filter input { type filter hook input priority 0; policy accept; }' 2>/dev/null || true
    fi
  fi
  if ! nft list chain $table input >/dev/null 2>&1; then
    nft list chain $table INPUT >/dev/null 2>&1 && chain="INPUT"
  fi
  local src_args=()
  if [[ -n "$SOURCE" ]]; then
    src_args=(ip saddr "$(cidr_of "$SOURCE")")
  fi
  if nft list chain $table "$chain" 2>/dev/null | grep -qE "dport ${PORT}[^0-9]*accept"; then
    echo "  相关 accept 规则似乎已存在"
  else
    nft add rule $table "$chain" "${src_args[@]}" "$PROTO" dport "$PORT" accept \
      comment \"astrbot-shipyard-bay\" 2>/dev/null \
      || nft add rule $table "$chain" "${src_args[@]}" "$PROTO" dport "$PORT" accept
    echo "  已添加：${SOURCE:-any} → ${PORT}/${PROTO}"
  fi
  nft list chain $table "$chain" 2>/dev/null | grep -E "${PORT}|chain" | head -20 || true
}

detect_and_open() {
  if command -v ufw >/dev/null 2>&1; then
    open_ufw
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    open_firewalld
    return
  fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE "hook input|dport"; then
    open_nft
    return
  fi
  if command -v iptables >/dev/null 2>&1; then
    open_iptables
    return
  fi
  if command -v nft >/dev/null 2>&1; then
    open_nft
    return
  fi
  echo "未检测到 ufw / firewalld / iptables / nftables，跳过主机防火墙。" >&2
  echo "请到云面板安全组放行 TCP ${PORT}。" >&2
}

check_listen() {
  echo
  echo "→ 检查本机监听 ${PORT}"
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx bay; then
    echo -n "  docker port bay: "
    docker port bay "$PORT" 2>/dev/null || docker port bay 2>/dev/null || echo "(无映射)"
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -lntu | grep -E ":${PORT}\\b" || echo "  ss: 未看到 :${PORT}"
  fi
  if curl -fsS --connect-timeout 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "  本机 /health: OK"
  else
    echo "  本机 /health: 失败（先确认 Bay 已启动）"
  fi
}

echo
detect_and_open
check_listen

cat <<MSG

==========================================
主机防火墙已处理完毕。

请在 AstrBot 机器上重测：
  curl -v --connect-timeout 5 http://沙盒公网IP:${PORT}/health

若仍超时，到【云厂商安全组】再加：
  协议 TCP  端口 ${PORT}  来源 ${SOURCE:-AstrBot机器IP（或临时 0.0.0.0/0）}
==========================================
MSG
