# 刻意不写 `# syntax=docker/dockerfile:1`：
# 该指令会让 BuildKit 每次构建都去 registry 拉一个外部前端镜像。
# 本文件只用了内置前端就支持的语法（多阶段 COPY --from、
# FROM 作用域的 ARG TARGETARCH），加它并无收益，省掉即少一个
# 构建期的网络依赖。

# ---------- builder: 取 Xray 二进制 ----------
#
# --platform=$BUILDPLATFORM 让本阶段始终在**构建机的原生架构**上运行，
# 不进 QEMU 模拟。本阶段只是按 TARGETARCH 下载对应的 Xray 预编译二进制，
# 没有任何需要目标架构才能做的事，模拟纯属浪费。
# 实测：在 arm64 机器上交叉构建 amd64 时，模拟下光跑到本阶段第一条 apt
# 就花了 18 分钟，且因模拟环境下的索引问题失败。
FROM --platform=$BUILDPLATFORM ubuntu:22.04 AS builder

ARG XRAY_VERSION=v26.3.27
ARG TARGETARCH

# apt 重试与超时。
# 默认 apt 不重试、也没有连接超时，网络一抖就会无限干等——实测卡死过一次
# （下到 578MB 后网络 I/O 完全冻结）。这几行让它失败快、自动重试。
RUN set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\nAcquire::ftp::Timeout "30";\n' \
      > /etc/apt/apt.conf.d/99-retries

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

# apt 重试与超时。
# 默认 apt 不重试、也没有连接超时，网络一抖就会无限干等——实测卡死过一次
# （下到 578MB 后网络 I/O 完全冻结）。这几行让它失败快、自动重试。
RUN set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\nAcquire::ftp::Timeout "30";\n' \
      > /etc/apt/apt.conf.d/99-retries

# apt 重试包装器。
#
# 仅有 Acquire::Retries 不够：`apt-get update` 在部分源下载失败时仍可能
# 返回成功，留下一份**残缺的包索引**，随后的 install 就会报
# 「Depends: libX but it is not installable / held broken packages」。
# 实测 amd64 交叉构建时就是这样失败的，而且报错完全指向依赖问题，
# 极具误导性——真正的原因是索引没下全。
#
# 因此把 update+install 作为一个整体重试，并在每次重试前清空索引重来。
RUN set -eux; \
    printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'for i in 1 2 3; do' \
      '  rm -rf /var/lib/apt/lists/*' \
      '  if apt-get update && apt-get install -y --no-install-recommends "$@"; then exit 0; fi' \
      '  echo "apt 第 $i 次尝试失败，清空索引后重试 ..." >&2' \
      '  sleep 10' \
      'done' \
      'echo "apt 连续 3 次失败" >&2; exit 1' \
      > /usr/local/bin/apt-retry; \
    chmod +x /usr/local/bin/apt-retry

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
    apt-retry ca-certificates curl gnupg; \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ jammy main" \
      > /etc/apt/sources.list.d/cloudflare-client.list; \
    apt-retry \
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
