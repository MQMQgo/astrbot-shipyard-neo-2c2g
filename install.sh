#!/usr/bin/env bash
# 一键安装入口：curl -fsSL .../install.sh | bash
# 可选环境变量见 README（PUBLIC_HOST / SANDBOX_MEM / RESERVE_MB 等）
set -euo pipefail
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/MQMQgo/astrbot-shipyard-neo-2c2g/main}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$RAW_BASE/deploy-shipyard-neo-2c2g.sh" -o "$TMP/deploy-shipyard-neo-2c2g.sh"
chmod +x "$TMP/deploy-shipyard-neo-2c2g.sh"
exec bash "$TMP/deploy-shipyard-neo-2c2g.sh" "$@"
