#!/usr/bin/env bash
#
# CONNMARK 策略路由 —— 解决 TUN 模式下的「回程路由陷阱」。
#
# 问题：WARP 连上后会装一条默认路由，把容器所有出向流量吸进隧道。
#       这也包括 9000 端口收到的连接的**回包**。结果是端口监听着、
#       客户端也能把 SYN 送到，但 SYN-ACK 钻进了隧道再也回不去，
#       表现为「端口开着但连不上」。
#
# 解法：给从物理网卡进来的连接打 CONNMARK，回包时把 mark 还原，
#       带 mark 的包查独立路由表（走原始网关），不进隧道。
#
# 这是通用解，不论客户端来自局域网还是公网都成立，也不依赖
# 「WARP 默认排除 RFC1918」这种不保证稳定的行为。
#
# 本脚本幂等，可被看护循环反复调用。
#
set -uo pipefail

log()  { echo "[routing] $*"; }
die()  { echo "[routing] FATAL: $*" >&2; exit 1; }

MARK="${ROUTE_MARK:-0x1}"
TABLE="${ROUTE_TABLE:-100}"
RULE_PRIO="${ROUTE_RULE_PRIO:-100}"
ENV_FILE=/run/warp-orig-route.env

[ -r "$ENV_FILE" ] || die "${ENV_FILE} 不存在——entrypoint 未能记录原始路由"
# shellcheck disable=SC1090
. "$ENV_FILE"

[ -n "${ORIG_GW:-}" ] && [ -n "${ORIG_IF:-}" ] \
  || die "原始路由信息不完整 (ORIG_GW='${ORIG_GW:-}' ORIG_IF='${ORIG_IF:-}')"

# 独立路由表：默认走原始物理网关，不经隧道
ip route replace default via "$ORIG_GW" dev "$ORIG_IF" table "$TABLE" \
  || die "无法写入路由表 ${TABLE}（缺少 NET_ADMIN?）"

# 带 mark 的包查上面那张表。先删后加保证幂等且不堆积重复规则。
while ip rule del fwmark "$MARK" lookup "$TABLE" 2>/dev/null; do :; done
ip rule add fwmark "$MARK" lookup "$TABLE" priority "$RULE_PRIO" \
  || die "无法添加 ip rule"

# 入向：从物理网卡进来的连接，整条连接打上 mark
iptables -t mangle -C PREROUTING -i "$ORIG_IF" -j CONNMARK --set-mark "$MARK" 2>/dev/null \
  || iptables -t mangle -A PREROUTING -i "$ORIG_IF" -j CONNMARK --set-mark "$MARK" \
  || die "无法添加 PREROUTING CONNMARK 规则"

# 出向：本机发出的包，把所属连接的 mark 还原到包上，供 ip rule 匹配
iptables -t mangle -C OUTPUT -j CONNMARK --restore-mark 2>/dev/null \
  || iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark \
  || die "无法添加 OUTPUT CONNMARK 规则"

log "策略路由就绪: fwmark ${MARK} -> table ${TABLE} (via ${ORIG_GW} dev ${ORIG_IF})"
