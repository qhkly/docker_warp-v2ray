# docker_warp-v2ray

把 **Cloudflare 官方 WARP 客户端**和 **Xray (v2ray)** 装进同一个容器：WARP 负责出网，Xray 以 VMess 对内网提供代理。

---

## 为什么必须用官方客户端，而不是 wgcf + WireGuard

**这是本项目最重要的背景知识。不了解它，很容易把方案「优化」回一个不能用的形态。**

- Cloudflare 已把 **MASQUE 设为 1.1.1.1 / WARP 全平台的默认协议**（[官方博客](https://blog.cloudflare.com/masque-now-powers-1-1-1-1-and-warp-apps-dex-available-with-remote-captures)、[Zero Trust 文档](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/settings/)）。MASQUE 是 HTTP/3 over QUIC 打到 Cloudflare anycast，在链路上看就是普通 CDN 流量。
- 裸 WireGuard 没有任何混淆，特征独特，在国内被重点干扰。
- **「官方客户端能用、自己搭 wgcf 不通」是普遍现象**，根源就是协议不同。
- **Xray / v2ray 不会说 MASQUE**。它只能做前端代理，不能充当 WARP 引擎。

所以：WARP 引擎 = 官方 `cloudflare-warp` 包；Xray 只负责把能力以 VMess 暴露给内网。

> 本容器用于**优化**出口（换 IP、拿 IPv6、统一内网出口），前提是官方 WARP 客户端在你的网络环境下本身可用。

---

## 架构

```
┌─ 容器 (Ubuntu 22.04) ─────────────────────────────────────┐
│                                                           │
│  warp-svc  ── TUN 模式，建 CloudflareWARP 接口 + 默认路由 │
│      └── MASQUE / HTTP3 ─────────> Cloudflare ──> 互联网  │
│                  ▲                                        │
│  xray            │ 出站 freedom，由内核路由进隧道         │
│      └── VMess inbound :9000                              │
│           ▲                                               │
│  CONNMARK 策略路由：从物理网卡进来的连接，回包走原网关    │
│           │        （否则 9000 会「开着但连不上」）        │
│                                                           │
│  supervisord 托管 warp-svc / warp-agent / xray            │
└───────────┼───────────────────────────────────────────────┘
            │ :9000
        内网客户端
```

### 回程路由陷阱（改配置前务必先读）

WARP 连上后会装一条默认路由，把容器**所有**出向流量吸进隧道——**包括 9000 端口收到的连接的回包**。结果是端口监听着、SYN 也能到达，但 SYN-ACK 钻进隧道再也回不去，表现为「端口开着但连不上」。

`setup-routing.sh` 用 CONNMARK 解决：给从物理网卡进来的连接打标记，回包时还原标记，带标记的包查独立路由表走原始网关。

这是通用解，不依赖「WARP 默认排除 RFC1918」这类不保证稳定的行为。**动路由相关代码前请先理解这一段。**

---

## 快速开始

已发布镜像：**`land007/warp-v2ray`**（`latest` / `1.0.0`，支持 `linux/amd64` 与 `linux/arm64`）

```bash
# 1. 放入现有 v2ray 配置（inbounds 会被原样保留，客户端零改动）
mkdir -p config data
cp /path/to/your/v2ray/config.json config/

# 2. 起容器（compose 默认从源码构建；想直接用发布镜像，
#    把 docker-compose.yml 里的 build 那行注释掉即可）
docker compose up -d
docker compose logs -f

# 3. 验证（注意先断开宿主机 WARP，见下方割接章节）
curl --max-time 10 https://www.cloudflare.com/cdn-cgi/trace
```

---

## 从「宿主机 WARP + 独立 v2ray 容器」割接

### 先了解这个验证陷阱

割接期间如果宿主机 WARP 还连着，流量会变成 **WARP 套 WARP**（容器 WARP → docker 网桥 → 宿主机 WARP → 出网）。此时 `warp=on` **会通过——但可能只是宿主机那层在起作用，容器内的 WARP 其实压根没连上**。测试显示成功，割接后一停宿主机 WARP 就全崩。

**`warp=on` 单独不构成证据。** 必须按顺序来：

```bash
# 1. 记录基线（宿主机 WARP 连着时的出口 IP）
curl ifconfig.me

# 2. 断开宿主机 WARP
sudo warp-cli disconnect

# 3. 记录真实原生出口 IP，确认与步骤 1 不同
curl ifconfig.me          # ← 记下这个值，后面要用

# 4. 停掉旧 v2ray 容器，释放 9000
docker stop <旧容器名>

# 5. 起新容器并跑完验证清单
docker compose up -d

# 6. 稳定运行几天后（可选）卸载宿主机 WARP
sudo apt remove cloudflare-warp
```

**回滚**：任一步失败 → `docker compose down` + 启回旧容器 + `sudo warp-cli connect`。步骤 6 之前，回滚成本是几秒钟。

### 验证清单

| # | 检查项 | 命令 / 判据 |
|---|---|---|
| 1 | 回程路由（最易翻车，优先验） | 从**另一台机器**用现有客户端连 `<服务器IP>:9000`，能连上 |
| 2 | 出口确实走 WARP | trace 含 `warp=on` **且** `ip=` ≠ 割接步骤 3 记录的值 |
| 3 | UDP 通路（选 TUN 的理由） | 经代理做 UDP DNS 查询，或访问强制 HTTP/3 的站点 |
| 4 | 容器内状态 | `docker exec warp-v2ray warp-cli status` → `Connected` |
| 5 | 协议确实是 MASQUE | `docker exec warp-v2ray warp-cli tunnel protocol get` |
| 6 | 入站零改动 | `diff <(jq -S .inbounds config/config.json) <(docker exec warp-v2ray jq -S .inbounds /etc/xray/config.json)` 无输出 |
| 7 | 私网封锁生效 | 经代理访问 `http://172.17.0.1`、`http://192.168.1.1` **应全部被拒** |
| 8 | 注册持久化 | `docker compose restart` 后日志无 `registration new` |
| 9 | 自愈 | `docker exec warp-v2ray pkill warp-svc` 后，检查 2 应自行恢复 |
| 10 | 健康检查 | `docker compose ps` 显示 `healthy` |

---

## 实测结果

本方案已在 arm64 Linux 容器中完整跑通（2026-07-22）。

**核心前提已验证**：日志中 WARP 建隧道前的连通性预检显示底层出口为
`ip=123.113.102.115 / loc=CN`，随后 MASQUE 握手成功
（`TLS handshake completed ... post_quantum_enabled: true`，
`Primary protocol won after secondary failed protocol="masque"`）。
**即 MASQUE 从国内 IP 可直接连通 Cloudflare**——这是整个方案成立的基础。

| 项 | 结果 |
|---|---|
| 注册 / MASQUE 连接 | 成功，Free 账号 |
| 经 VMess:9000 出网 | `warp=on`，出口为 WARP IPv6，与直连出口不同 |
| UDP 往返 | 向 `1.1.1.1:53` 发 DNS 查询收到完整应答（2 条 A 记录） |
| 私网封锁 | 经代理连内网中**确有服务监听**的地址，被拒 |
| 入站零改动 | `diff .inbounds` 无输出 |
| 注册持久化 | 重启后日志显示「已存在注册信息，跳过注册」，Account ID 不变 |
| 自愈 | `pkill warp-svc` 后 supervisord 拉起，出网自动恢复 |
| 镜像体积 | 811MB (arm64) |
| 稳态日志量 | 约 960 行/天 |

### 实测中发现并已修复的三个问题

1. **`supervisorctl` 不可用** —— 初版 supervisord.conf 缺 `unix_http_server` 等三段配置，容器内执行报 `no such file`，排障手段直接失效。
2. **dbus 告警无限刷屏** —— 不装 dbus 时 warp-svc 每 3 秒打一条 `dbus connection failed` 且永不停止，实测约 **2.9 万行/天**，足以冲垮 `docker logs`。已改为容器内运行 dbus 守护进程。
3. **warp-svc DEBUG 刷屏** —— 单次启动约 1400 行。实测 **warp-svc 不认 `RUST_LOG`**，官方也无日志级别开关，只能在输出侧过滤（见 `run-warp-svc.sh`）。

> 另注：WARP 会把自己的路由变更日志写进 `/var/lib/cloudflare-warp/cfwarp_route_change_log.txt`（挂载的 `data/` 目录内），该文件会随运行时间增长，长期运行需留意磁盘占用。

---

## 配置说明

`CONFIG_MODE=patch`（默认）下，容器读取挂载的 `config/config.json`，只做三件事：

1. `inbounds` —— **一个字节都不改**
2. `outbounds` —— 保留现有 `freedom`/`direct`，追加一个 `blackhole`/`block`
3. `routing.rules` —— 在**最前面**插入私网封锁规则

出站保持 `freedom` 是正确的：TUN 模式下内核已把流量送进 WARP 隧道，不需要（也不应该）再串 SOCKS 到 `127.0.0.1:40000`——那是 proxy 模式的做法。

整个 patch 是幂等的，重复应用结果不变。

### 私网封锁不是可选项

容器挂在 docker 网桥上，**任何持有 VMess UUID 的人都能经 9000 访问 `172.17.0.1`（宿主机）以及同网桥的其他容器**。原架构下 v2ray 容器的网络暴露面较窄，合并后这个风险变为实质性。

封锁列表用显式 CIDR 而非 `geoip:private`，因此无需打包 ~30MB 的 geo 数据文件：

```
10.0.0.0/8  172.16.0.0/12  192.168.0.0/16  127.0.0.0/8
169.254.0.0/16  ::1/128  fc00::/7  fe80::/10
```

规则**必须插在最前面**——Xray 按序匹配、首个命中即生效，插到 `vmess-in → direct` 后面等于没写。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CONFIG_MODE` | `patch` | `patch` 用挂载的配置；`generate` 从环境变量生成 |
| `VMESS_UUID` | — | `generate` 模式必填 |
| `WARP_PROTOCOL` | `MASQUE` | 改 `WireGuard` 在国内大概率不通 |
| `WARP_MODE` | `warp` | `warp` = TUN 全隧道支持 UDP；`proxy` = 完全不支持 UDP |
| `WARP_LICENSE` | — | WARP+ 授权码，可选 |
| `XRAY_PORT` | `9000` | 健康检查探测的端口，需与 inbounds 一致 |
| `WATCHDOG_INTERVAL` | `30` | WARP 看护循环间隔（秒） |
| `ROUTE_MARK` / `ROUTE_TABLE` | `0x1` / `100` | 策略路由参数，一般不用改 |

---

## 排障

```bash
docker compose logs -f                                   # 全部日志
docker exec -it warp-v2ray warp-cli status               # 连接状态
docker exec -it warp-v2ray warp-cli registration show    # 注册信息
docker exec -it warp-v2ray warp-cli tunnel protocol get  # 当前协议
docker exec -it warp-v2ray ip rule show                  # 策略路由规则
docker exec -it warp-v2ray iptables -t mangle -L -n      # CONNMARK 规则
```

| 症状 | 排查方向 |
|---|---|
| 9000 端口连不上，但容器日志正常 | 回程路由。查 `ip rule show` 是否有 `fwmark 0x1` |
| `warp=on` 但出口 IP 没变 | 可能是宿主机 WARP 在起作用（双层 WARP 假阳性） |
| 注册失败 | Cloudflare 按 IP 限流。**不要反复重启**，那会加重限流。稍后再试 |
| UDP 不通 | 确认 `WARP_MODE=warp` 而非 `proxy`；确认挂了 `/dev/net/tun` |
| 容器起不来，提示缺 TUN | compose 里 `devices` 和 `cap_add: NET_ADMIN` 是否都在 |

---

## 构建

```bash
# 本机
docker compose build

# 多架构（官方源已确认提供 amd64 + arm64）
docker buildx build --platform linux/amd64,linux/arm64 -t <user>/warp-v2ray:latest --push .
```

**实测镜像 811MB**（arm64，Xray 26.3.27 + warp-cli 2026.6.880.0）。官方 `cloudflare-warp` 包把 CLI 与 GUI 打在一起，`libwebkit2gtk-4.1-0`、`libayatana-appindicator3-1` 等是硬依赖去不掉。这是换取 MASQUE 的代价。

若体积不可接受，可考虑用 `dpkg --ignore-depends` 剥离 GUI 依赖，但那会让 apt 处于不一致状态——属于用可维护性换体积，非必要不做。

---

## 已知限制与后续改进

- 免费 WARP 有带宽和并发限制。
- **想拿「干净 IP」访问 OpenAI / Claude / Gemini 的话，WARP 通常适得其反**——这些服务对 Cloudflare WARP 出口段的风控比普通 IP 更严。当通用出网通道则没问题。
- **VMess 正在被上游弃用。** 本项目锁定的 Xray v26.3.27 启动时会打印：

  ```
  [Warning] The feature VMess (with no Forward Secrecy, etc.) is deprecated,
  not recommended for using and might be removed.
  Please migrate to VLESS Encryption as soon as possible.
  ```

  当前不影响使用，配置校验为 `Configuration OK`。但这意味着迁移到 VLESS 不只是安全建议，而是迟早要做的事——将来某个 Xray 版本可能直接移除 VMess。升级 Xray 版本前请先确认这一点。
- **当前 VMess 是裸 TCP、无 TLS**（`security: "none"`）。仅对内网开放时可以接受；**若将来 9000 需要对公网开放，应换成 VLESS + Reality 或至少套 TLS**——明文 TCP 上的 VMess 有已知的主动探测特征。该改动需要同步更新客户端，属独立任务。
- `data/` 含 WARP 设备凭据，`config/` 含 VMess UUID，两者都已在 `.gitignore` 中，**切勿提交或分享**。
