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
# Use `git fetch` instead of `git clone --branch` so PCLOUDCC_REF can be a
# branch, tag, or a full commit SHA (as documented in README.md). GitHub allows
# fetching arbitrary SHAs via uploadpack.allowReachableSHA1InWant.
RUN git init -q \
    && git fetch --depth 1 \
        https://github.com/lneely/pcloudcc-lneely.git "${PCLOUDCC_REF}" \
    && git checkout -q FETCH_HEAD \
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
    oathtool \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /pcloud_internal

COPY --from=builder /build/pcloudcc /usr/local/bin/pcloudcc
COPY --chmod=755 entrypoint.sh /entrypoint.sh

ENV PCLOUD_USER="" \
    PCLOUD_PASSWORD="" \
    PCLOUD_PASSWORD_FILE="" \
    PCLOUD_2FA="" \
    PCLOUD_TOTP_SECRET="" \
    PCLOUD_TOTP_SECRET_FILE="" \
    PCLOUD_CRYPT="" \
    PCLOUD_CRYPT_FILE="" \
    PCLOUD_MOUNT="/pcloud_internal" \
    ENABLE_BINDFS="0" \
    BINDFS_TARGET="/pcloud" \
    UID="1000" \
    GID="1000" \
    USER="nobody" \
    GROUP="users" \
    MOUNT_TIMEOUT="60"

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD if [ ! -f /root/.pcloud/data.db ]; then \
          exit 0; \
        else \
          if [ "${ENABLE_BINDFS}" = "1" ]; then _mnt="${BINDFS_TARGET}"; else _mnt="${PCLOUD_MOUNT}"; fi; \
          mountpoint -q "${_mnt}" && [ -n "$(ls -A "${_mnt}" 2>/dev/null)" ] || exit 1; \
          if [ -n "${PCLOUD_CRYPT}" ] || [ -n "${PCLOUD_CRYPT_FILE}" ]; then \
            [ -d "${_mnt}/Crypto Folder" ] && [ -n "$(ls -A "${_mnt}/Crypto Folder" 2>/dev/null)" ] || exit 1; \
          fi; \
        fi

ENTRYPOINT ["/entrypoint.sh"]
