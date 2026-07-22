# 刻意不写 `# syntax=docker/dockerfile:1`：
# 该指令会让 BuildKit 每次构建都去 registry 拉一个外部前端镜像。
# 本文件只用了内置前端就支持的语法（多阶段 COPY --from、
# FROM 作用域的 ARG TARGETARCH），加它并无收益，省掉即少一个
# 构建期的网络依赖。

# ---------- builder: 取 Xray 二进制 ----------
FROM ubuntu:22.04 AS builder

ARG XRAY_VERSION=v26.3.27
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) asset="Xray-linux-64.zip" ;; \
      arm64) asset="Xray-linux-arm64-v8a.zip" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}"; \
    mkdir -p /out; \
    unzip -j /tmp/xray.zip xray -d /out; \
    chmod +x /out/xray

# ---------- runtime ----------
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# warp-svc 的日志级别（Rust tracing）。默认 warn，避免 DEBUG 刷屏淹没
# 我们自己 agent 的日志；排障时可在 compose 里覆盖为 info / debug。
ENV WARP_LOG_LEVEL=warn

# cloudflare-warp 来自 Cloudflare 官方 apt 源。
# 已实测确认该源提供 amd64 与 arm64 两个架构（dists/jammy/Release -> Architectures: amd64 arm64）。
#
# 体积说明：官方包把 CLI 与 GUI 打在一起，libwebkit2gtk-4.1-0 /
# libayatana-appindicator3-1 是硬依赖，去不掉。实测镜像 811MB。
# 这是换取 MASQUE 协议的必要代价（见 README「为什么必须用官方客户端」）。
#
# 防火墙后端：WARP 依赖 nftables 并用它装自己的规则。这里装的 iptables 是
# Ubuntu 22.04 默认的 nft 后端（iptables-nft），与 WARP 共存。
# 切勿改成 iptables-legacy，否则两套规则各写各的，排障会变成噩梦。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ jammy main" \
      > /etc/apt/sources.list.d/cloudflare-client.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      cloudflare-warp \
      supervisor \
      dbus \
      iproute2 \
      iptables \
      jq; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=builder /out/xray /usr/local/bin/xray

COPY entrypoint.sh    /opt/entrypoint.sh
COPY warp-agent.sh    /opt/warp-agent.sh
COPY setup-routing.sh /opt/setup-routing.sh
COPY healthcheck.sh   /opt/healthcheck.sh
COPY run-warp-svc.sh  /opt/run-warp-svc.sh
COPY supervisord.conf /opt/supervisord.conf
COPY config.example.json /opt/config.example.json

RUN chmod +x /opt/entrypoint.sh /opt/warp-agent.sh /opt/setup-routing.sh \
             /opt/healthcheck.sh /opt/run-warp-svc.sh \
 && mkdir -p /etc/xray

EXPOSE 9000

HEALTHCHECK --interval=60s --timeout=15s --start-period=60s --retries=3 \
  CMD /opt/healthcheck.sh

ENTRYPOINT ["/opt/entrypoint.sh"]
