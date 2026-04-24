# syntax=docker/dockerfile:1.7
# =============================================================================
# pcloudcc Docker Image - lneely/pcloudcc-lneely fork
# Base: debian:trixie-slim (Debian 13 - mbedTLS 3.x native)
# Includes bindfs for uid/gid remapping
# =============================================================================

# ===== Stage 1: Build =====
FROM debian:trixie-slim AS builder

ARG PCLOUDCC_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    libfuse3-dev \
    libudev-dev \
    libmbedtls-dev \
    libboost-system-dev \
    libboost-program-options-dev \
    libreadline-dev \
    libsqlite3-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 --branch "${PCLOUDCC_REF}" \
        https://github.com/lneely/pcloudcc-lneely.git . \
    && make \
    && strip pcloudcc

# ===== Stage 2: Runtime =====
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="pcloudcc" \
      org.opencontainers.image.description="pCloud console client (lneely fork) with bindfs" \
      org.opencontainers.image.source="https://github.com/lneely/pcloudcc-lneely" \
      org.opencontainers.image.licenses="BSD-3-Clause"

RUN apt-get update && apt-get install -y --no-install-recommends \
    fuse3 \
    libfuse3-4 \
    libudev1 \
    libmbedtls21 \
    libmbedcrypto16 \
    libboost-system1.83.0 \
    libboost-program-options1.83.0 \
    libreadline8t64 \
    libsqlite3-0 \
    zlib1g \
    ca-certificates \
    bindfs \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/pcloudcc /usr/local/bin/pcloudcc
COPY --chmod=755 entrypoint.sh /entrypoint.sh

ENV PCLOUD_USER="" \
    PCLOUD_2FA="" \
    PCLOUD_CRYPT="" \
    PCLOUD_CRYPT_FILE="" \
    PCLOUD_MOUNT="/pcloud_internal" \
    ENABLE_BINDFS="0" \
    BINDFS_TARGET="/pcloud" \
    UID="1000" \
    GID="1000" \
    USER="nobody" \
    GROUP="users" \
    MOUNT_TIMEOUT="120"

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD if [ "${ENABLE_BINDFS}" = "1" ]; then \
          mountpoint -q "${BINDFS_TARGET}" && [ -n "$(ls -A "${BINDFS_TARGET}" 2>/dev/null)" ]; \
        else \
          mountpoint -q "${PCLOUD_MOUNT}" && [ -n "$(ls -A "${PCLOUD_MOUNT}" 2>/dev/null)" ]; \
        fi

ENTRYPOINT ["/entrypoint.sh"]
