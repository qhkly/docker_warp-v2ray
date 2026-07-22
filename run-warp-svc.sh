#!/usr/bin/env bash
#
# warp-svc 的日志包装器。
#
# 背景：warp-svc 默认把海量 DEBUG 打到 stdout（实测一次启动约 1400 行），
# 会把我们自己 agent 的关键日志完全淹没，让 `docker compose logs` 失去排障价值。
#
# 实测结论：warp-svc **不认 RUST_LOG**（设 RUST_LOG=warn 后依然刷 DEBUG），
# 官方也没提供日志级别开关。因此只能在输出侧过滤——这一层完全在我们控制内。
#
# ERROR 在任何级别下都保留，不会因为降噪而丢掉故障信息。
#
set -uo pipefail

# 已知的良性噪音：warp-svc 给自己的策略路由（FwMark/Table 65743）下 netlink
# 命令时，把成功的响应也当成失败打 WARN —— 报文里写得很清楚
# `response=Os { code: 0, message: "Success" }`。实测单次启动刷 316 行。
# 只过滤「同时含该命令名和 Success 响应」的行，真正失败的 netlink 报错仍会显示。
BENIGN_NETLINK='failed to issue netlink command.*message: "Success"'

case "${WARP_LOG_LEVEL:-warn}" in
  debug|trace)
    # 完整输出，不做任何过滤
    exec /usr/bin/warp-svc 2>&1
    ;;
  info)
    /usr/bin/warp-svc 2>&1 \
      | grep --line-buffered -vE $'\033\\[34mDEBUG' \
      | grep --line-buffered -vE "$BENIGN_NETLINK"
    ;;
  *)
    # 默认 warn：只保留 WARN/ERROR，并去掉上述良性噪音
    /usr/bin/warp-svc 2>&1 \
      | grep --line-buffered -vE $'\033\\[(34mDEBUG|32m INFO)' \
      | grep --line-buffered -vE "$BENIGN_NETLINK"
    ;;
esac
