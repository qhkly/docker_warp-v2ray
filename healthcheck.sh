#!/usr/bin/env bash
#
# 健康检查：三件事都要成立才算健康。
#   1. WARP 处于 Connected
#   2. Xray 在监听对外端口
#   3. 出网确实经过 WARP
#
set -uo pipefail

XRAY_PORT="${XRAY_PORT:-9000}"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

# 1. WARP 连接状态
#    注意 "Disconnected" 也含 "connected" 子串，必须先匹配 Disconnected
status="$(warp-cli --accept-tos status 2>/dev/null)" || exit 1
case "$status" in
  *Disconnected*) echo "unhealthy: WARP disconnected"; exit 1 ;;
  *Connected*)    : ;;
  *)              echo "unhealthy: WARP status unknown"; exit 1 ;;
esac

# 2. Xray 监听
if ! ss -ltn 2>/dev/null | grep -qE "[:.]${XRAY_PORT}[[:space:]]"; then
  echo "unhealthy: xray not listening on ${XRAY_PORT}"
  exit 1
fi

# 3. 出口确实走 WARP
if ! curl -fsS --max-time 10 "$TRACE_URL" 2>/dev/null | grep -q '^warp=on'; then
  echo "unhealthy: egress is not going through WARP"
  exit 1
fi

echo "healthy"
