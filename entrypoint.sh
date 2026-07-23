#!/usr/bin/env bash
#
# 容器入口：只做「不需要 WARP 守护进程」的准备工作，然后交给 supervisord。
#
# warp-svc / warp-agent / xray 三个进程全部由 supervisord 托管，
# 这样 warp-svc 挂掉时容器能自愈（裸 entrypoint 方案下守护进程死了容器还活着，
# 代理会静默失效）。
#
set -euo pipefail

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARN: $*" >&2; }
die()  { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

ORIG_ROUTE_ENV=/run/warp-orig-route.env
XRAY_CONFIG=/etc/xray/config.json

# ---------------------------------------------------------------------------
# Step 1 — 记录原始默认路由
#
# 必须在 WARP 连接之前做。WARP 一旦连上就会把默认路由改成隧道，
# 那时再读就拿不到真正的物理网关了。
# setup-routing.sh 靠这两个值把入站连接的回包送回原路，
# 否则 9000 端口会「开着但连不上」（回包被吸进隧道）。
# ---------------------------------------------------------------------------
ORIG_GW="$(ip route show default | awk '/^default/ {print $3; exit}')"
ORIG_IF="$(ip route show default | awk '/^default/ {print $5; exit}')"

[ -n "$ORIG_GW" ] && [ -n "$ORIG_IF" ] \
  || die "无法解析原始默认路由，容器网络异常（ip route show default 无输出）"

printf 'ORIG_GW=%s\nORIG_IF=%s\n' "$ORIG_GW" "$ORIG_IF" > "$ORIG_ROUTE_ENV"
log "原始默认路由: via ${ORIG_GW} dev ${ORIG_IF}"

# ---------------------------------------------------------------------------
# Step 2 — TOS 接受标记
#
# 不同版本的 warp-cli 读的路径不一致，两个位置都写上，
# 另外各命令仍会带 --accept-tos 作为双保险。
# ---------------------------------------------------------------------------
for d in /root/.local/share/warp /var/lib/cloudflare-warp; do
  mkdir -p "$d"
  printf 'yes' > "$d/accepted-tos.txt"
done

# ---------------------------------------------------------------------------
# Step 3 — 生成 Xray 配置
#
# 不依赖 WARP 守护进程，所以放在启动 supervisord 之前做完。
# ---------------------------------------------------------------------------
CONFIG_MODE="${CONFIG_MODE:-patch}"
SRC_CONFIG="${SRC_CONFIG:-/config/config.json}"

# 私有网段黑名单。
#
# 用显式 CIDR 而不是 geoip:private，这样无需打包 ~30MB 的 geo 数据文件。
#
# 这条规则不是可选项：容器挂在 docker 网桥上，任何持有 VMess UUID 的人
# 都能经 9000 访问 172.17.0.1（宿主机）以及同网桥的其他容器。
PRIVATE_CIDRS='["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"]'
BLOCK_RULE="$(jq -nc --argjson cidrs "$PRIVATE_CIDRS" \
  '{"type":"field","ip":$cidrs,"outboundTag":"block"}')"

# 首次启动自动生成配置。
#
# 把生成的配置**写回挂载目录**而不是容器内的临时文件，这样 UUID 跨重启稳定，
# 用户也能直接编辑那份文件。要求 /config 可写（compose 里不要挂成 :ro）。
#
# 若 /config 只读则不视为错误：退回到容器内临时文件，功能照常，
# 只是每次重启 UUID 会变——此时会明确警告。
bootstrap_config() {
  local dst="$1" uuid port
  uuid="${VMESS_UUID:-$(xray uuid)}"
  port="${XRAY_PORT:-9000}"

  local tmp=/tmp/generated.json
  jq --arg uuid "$uuid" --argjson port "$port" \
    '.inbounds[0].port = $port | .inbounds[0].settings.clients[0].id = $uuid' \
    /opt/config.example.json > "$tmp" || die "生成配置失败"

  if cp "$tmp" "$dst" 2>/dev/null; then
    SRC_CONFIG="$dst"
    log "已生成默认配置并写入 ${dst}"
  else
    SRC_CONFIG="$tmp"
    warn "${dst} 不可写，配置只存在于容器内，**重启后 UUID 会变**。"
    warn "请把 compose 里 /config 的挂载去掉 :ro，然后重建容器。"
  fi

  print_share_link "$uuid" "$port" "$SRC_CONFIG"
}

# 打印 vmess:// 分享链接与其它入站信息。
# 字段与 v2rayN / v2rayNG 的 base64 JSON 格式一致，可直接导入。
#
# socks/http 端口从生成的配置里读，而不是另设环境变量——
# 端口的唯一事实来源是配置文件本身，两处各写一份迟早对不上。
print_share_link() {
  local uuid="$1" port="$2" cfg="$3" addr link socks_port http_port
  addr="${SERVER_ADDR:-<本机IP>}"
  socks_port="$(jq -r '[.inbounds[] | select(.protocol=="socks") | .port][0] // empty' "$cfg")"
  http_port="$(jq -r '[.inbounds[] | select(.protocol=="http")  | .port][0] // empty' "$cfg")"

  link="vmess://$(jq -nc \
      --arg add "$addr" --arg port "$port" --arg id "$uuid" \
      '{v:"2", ps:"warp-v2ray", add:$add, port:$port, id:$id,
        aid:"0", scy:"auto", net:"tcp", type:"none",
        host:"", path:"", tls:"", sni:"", alpn:""}' \
    | base64 | tr -d '\n')"

  log "────────────────────────────────────────────────"
  log "VMess UUID : ${uuid}"
  log "VMess 分享链接（导入 v2rayN / v2rayNG）："
  log "  ${link}"
  [ -n "${SERVER_ADDR:-}" ] || \
    log "  ↑ 未设置 SERVER_ADDR，链接里的地址是占位符，导入后手动改成本机 IP"
  [ -n "$socks_port" ] && { log ""; log "SOCKS5 : ${addr}:${socks_port}  （无认证，支持 UDP）"; }
  [ -n "$http_port" ]  &&        log "HTTP   : ${addr}:${http_port}  （无认证）"
  log "────────────────────────────────────────────────"
}

case "$CONFIG_MODE" in
  patch)
    if [ -r "$SRC_CONFIG" ]; then
      jq empty "$SRC_CONFIG" 2>/dev/null || die "${SRC_CONFIG} 不是合法 JSON"
      log "patch 模式：以 ${SRC_CONFIG} 为基准，inbounds 保持原样"
    else
      # 首次部署：没有现成配置就自动生成一份，而不是直接退出。
      log "未找到 ${SRC_CONFIG}，按首次部署处理，自动生成默认配置 ..."
      bootstrap_config "$SRC_CONFIG"
    fi
    ;;
  generate)
    # 显式要求生成。与 patch 的区别仅在于：即使已有配置也会覆盖重写。
    log "generate 模式：生成配置（会覆盖已有文件）"
    bootstrap_config "$SRC_CONFIG"
    ;;
  *)
    die "未知的 CONFIG_MODE: ${CONFIG_MODE}（可选 patch / generate）"
    ;;
esac

# 对基准配置做三件事，inbounds 一个字节都不动：
#   1. outbounds 追加 blackhole/block（若不存在）
#   2. routing.rules 最前面插入私网封锁规则
#      —— 必须插在最前，Xray 按序匹配、首个命中即生效；
#         插到 vmess-in -> direct 后面等于没写
#   3. dns 段若缺失则补上（容器 resolv.conf 由 Docker 管，显式配置避免解析行为漂移）
#
# domainStrategy 默认 IPIfNonMatch 而不是 AsIs：
# 上面第 2 条私网封锁是按**目标 IP** 匹配的，而 AsIs 下 Xray 不会为路由决策
# 解析域名，于是用域名访问内网（http://nas.local）就绕过了封锁。
# IPIfNonMatch 会在域名规则未命中时解析成 IP 再匹配一次，封锁才真正生效。
# 代价是路由决策多一次 DNS 查询。
# 注意这里用的是 jq 的 `//`：配置里已显式写了 domainStrategy 就以其为准。
#
# 出站保持现有的 freedom/direct：TUN 模式下内核已把流量送进 WARP 隧道，
# 不需要（也不应该）再串 SOCKS 到 127.0.0.1:40000（那是 proxy 模式的做法）。
#
# 整个 filter 是幂等的：重复 patch 同一份配置结果不变。
jq --argjson blockrule "$BLOCK_RULE" '
    .outbounds = (
      (.outbounds // []) as $o
      | if ($o | map(select(.tag == "block")) | length) > 0
        then $o
        else $o + [{"protocol":"blackhole","settings":{},"tag":"block"}]
        end
    )
  | .routing = ((.routing // {}) | .domainStrategy = (.domainStrategy // "IPIfNonMatch"))
  | .routing.rules = ([$blockrule] + ((.routing.rules // []) | map(select(. != $blockrule))))
  | .dns = (.dns // {"servers":["1.1.1.1","8.8.8.8"],"queryStrategy":"UseIP"})
' "$SRC_CONFIG" > "$XRAY_CONFIG" || die "Xray 配置生成失败"

log "Xray 配置已写入 ${XRAY_CONFIG}"

# ---------------------------------------------------------------------------
# Step 4 — 交给 supervisord
# ---------------------------------------------------------------------------
log "启动 supervisord（warp-svc / warp-agent / xray）"
exec supervisord -c /opt/supervisord.conf
