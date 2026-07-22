#!/usr/bin/env bash
#
# WARP 生命周期管理：注册 → 设协议 → 设模式 → 连接 → 装策略路由 → 持续看护。
#
# 由 supervisord 托管且 autorestart=true。脚本末尾是一个不退出的看护循环，
# 因此 warp-svc 被重启后连接状态和策略路由都能自动修复。
#
set -uo pipefail

log()  { echo "[warp-agent] $*"; }
warn() { echo "[warp-agent] WARN: $*" >&2; }
die()  { echo "[warp-agent] FATAL: $*" >&2; exit 1; }

WARP_PROTOCOL="${WARP_PROTOCOL:-MASQUE}"
WARP_MODE="${WARP_MODE:-warp}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

wcli() { warp-cli --accept-tos "$@"; }

# warp-cli status 的输出里 "Disconnected" 也包含 "connected" 子串，
# 直接 grep -i connected 会把断线误判成已连接，所以必须先匹配 Disconnected。
warp_is_connected() {
  local s
  s="$(wcli status 2>/dev/null)" || return 1
  case "$s" in
    *Disconnected*) return 1 ;;
    *Connected*)    return 0 ;;
    *)              return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. 等待 warp-svc 守护进程就绪
#
# 轮询而不是固定 sleep —— 固定 sleep 在慢机器上会偶发失败，
# 是常见参考实现里的脆弱点。
# ---------------------------------------------------------------------------
log "等待 warp-svc 守护进程 ..."
for i in $(seq 1 60); do
  if wcli status >/dev/null 2>&1; then
    log "守护进程已就绪"
    break
  fi
  [ "$i" -eq 60 ] && die "warp-svc 在 60 秒内未就绪"
  sleep 1
done

# ---------------------------------------------------------------------------
# 2. 注册（幂等，带持久化退避）
#
# 关键：本脚本由 supervisord 以 autorestart=true 托管，失败退出会被立即拉起。
# 如果这里不做限速，一次注册失败就会变成「失败→重启→再注册」的循环，
# 把出口 IP 打进 Cloudflare 限流甚至封禁——正是最该避免的情况。
#
# 因此失败次数持久化到 volume（跨容器重启有效），并按指数退避：
# 60s → 120s → 240s → ... 上限 30 分钟；连续失败 5 次后进入长睡眠，
# 只打日志不再尝试，等人工介入。
# ---------------------------------------------------------------------------
REG_FAIL_FILE=/var/lib/cloudflare-warp/.registration-failures

if wcli registration show >/dev/null 2>&1; then
  log "已存在注册信息，跳过注册"
  rm -f "$REG_FAIL_FILE"
else
  fails="$(cat "$REG_FAIL_FILE" 2>/dev/null || echo 0)"
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac

  if [ "$fails" -ge 5 ]; then
    warn "注册已连续失败 ${fails} 次，停止自动重试以免加重 Cloudflare 限流。"
    warn "请人工检查网络后，删除 ${REG_FAIL_FILE}（或整个 ./data 目录）再重启容器。"
    sleep 3600
    die "等待人工介入"
  fi

  if [ "$fails" -gt 0 ]; then
    backoff=$(( 60 * (1 << (fails - 1)) ))
    [ "$backoff" -gt 1800 ] && backoff=1800
    warn "上次注册失败（累计 ${fails} 次），退避 ${backoff}s 后重试"
    sleep "$backoff"
  fi

  log "注册 WARP 设备 ..."
  if wcli registration new; then
    log "注册成功"
    rm -f "$REG_FAIL_FILE"
  else
    echo $(( fails + 1 )) > "$REG_FAIL_FILE"
    die "注册失败（累计 $(( fails + 1 )) 次）。常见原因：Cloudflare 按 IP 限流，或网络不通。下次启动会自动退避，请勿手工反复重启。"
  fi
fi

if [ -n "${WARP_LICENSE:-}" ]; then
  log "应用 WARP+ 授权码 ..."
  wcli registration license "$WARP_LICENSE" || warn "授权码应用失败，继续以免费额度运行"
fi

# ---------------------------------------------------------------------------
# 3. 协议
#
# MASQUE 是本方案在国内可用的根本原因：它是 HTTP/3 over QUIC 打到
# Cloudflare anycast，链路上看就是普通 CDN 流量。
# 改成 WireGuard 会退化成无混淆的独特特征，大概率不通。
# 这里显式设置而不是依赖默认值，是为了防止上游默认值变化导致静默退化。
# ---------------------------------------------------------------------------
log "设置隧道协议: ${WARP_PROTOCOL}"
wcli tunnel protocol set "$WARP_PROTOCOL" \
  || warn "设置协议失败（该 warp-cli 版本可能不支持此子命令），将沿用默认协议"

# ---------------------------------------------------------------------------
# 4. 模式与连接
#
# warp 模式 = TUN 全隧道，支持 UDP。
# proxy 模式更简单但完全不支持 UDP，本项目因此选 TUN。
# ---------------------------------------------------------------------------
log "设置模式: ${WARP_MODE}"
wcli mode "$WARP_MODE" || warn "设置模式失败，将沿用当前模式"

log "连接 WARP ..."
wcli connect || warn "connect 返回非零，继续等待状态变化"

for i in $(seq 1 60); do
  if warp_is_connected; then
    log "WARP 已连接"
    break
  fi
  [ "$i" -eq 60 ] && die "WARP 在 60 秒内未能连接。请检查 warp-cli status 输出。"
  sleep 1
done

# ---------------------------------------------------------------------------
# 5. 策略路由
#
# 必须在 WARP 连上之后装 —— 此时 WARP 的隧道路由已经就位，
# 我们再补一张表把入站连接的回包捞回原路。
# ---------------------------------------------------------------------------
/opt/setup-routing.sh || die "策略路由安装失败，9000 端口的回包会被吸进隧道导致连不上"

# ---------------------------------------------------------------------------
# 6. 出口自检
#
# 只是提示，不阻断：即使这里没通，看护循环也可能后续修好。
#
# 注意：这条 warp=on 单独不能证明容器内的 WARP 生效了 —— 如果宿主机也开着
# WARP，流量会 WARP 套 WARP，同样返回 warp=on。完整判据见 README 的割接章节。
# ---------------------------------------------------------------------------
if curl -fsS --max-time 15 "$TRACE_URL" 2>/dev/null | grep -q '^warp=on'; then
  log "出口自检通过: warp=on"
else
  warn "出口自检未通过（trace 未返回 warp=on），请检查 WARP 状态"
fi

log "初始化完成，进入看护循环（间隔 ${WATCHDOG_INTERVAL}s）"

# ---------------------------------------------------------------------------
# 7. 看护循环
#
# warp-svc 被 supervisord 重启后，连接状态与策略路由都需要重建。
# setup-routing.sh 是幂等的，可以安全地反复调用。
# ---------------------------------------------------------------------------
while true; do
  sleep "$WATCHDOG_INTERVAL"

  if ! warp_is_connected; then
    warn "检测到 WARP 断开，尝试重连 ..."
    wcli connect || warn "重连命令失败"
    sleep 5
    if warp_is_connected; then
      log "重连成功，重建策略路由"
      /opt/setup-routing.sh || warn "策略路由重建失败"
    fi
    continue
  fi

  # 连接正常时，确认策略路由规则还在（WARP 重连可能冲掉规则）
  if ! ip rule show 2>/dev/null | grep -q "fwmark ${ROUTE_MARK:-0x1}"; then
    warn "策略路由规则缺失，重新安装"
    /opt/setup-routing.sh || warn "策略路由重建失败"
  fi
done
