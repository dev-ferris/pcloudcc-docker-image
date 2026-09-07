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
    && git rev-parse HEAD > /build/pcloudcc.commit \
    && make -j"$(nproc)" \
    && strip pcloudcc

# ===== Stage 2: Runtime =====
FROM debian:trixie-slim

# licenses/source describe this image (the packaging layer, MIT). The bundled
# pcloudcc binary itself is BSD-3-Clause; its origin is recorded separately.
LABEL org.opencontainers.image.title="pcloudcc" \
      org.opencontainers.image.description="pCloud console client (lneely fork) with bindfs" \
      org.opencontainers.image.source="https://github.com/dev-ferris/pcloudcc-docker-image" \
      org.opencontainers.image.licenses="MIT" \
      pcloudcc.upstream.source="https://github.com/lneely/pcloudcc-lneely" \
      pcloudcc.upstream.licenses="BSD-3-Clause"

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
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /pcloud_internal

COPY --from=builder /build/pcloudcc /usr/local/bin/pcloudcc
# Resolved upstream commit the bundled binary was built from. PCLOUDCC_REF may
# be a moving branch name, so record what it actually pointed at at build time.
COPY --from=builder /build/pcloudcc.commit /usr/local/share/pcloudcc/upstream-commit
COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 healthcheck.sh /healthcheck.sh

# Only the non-credential settings get a baked-in default. The credential
# variables (PCLOUD_USER, PCLOUD_PASSWORD[_FILE], PCLOUD_2FA,
# PCLOUD_TOTP_SECRET[_FILE], PCLOUD_CRYPT[_FILE]) are supplied at runtime and
# are deliberately not declared here: an empty ENV placeholder adds no
# behaviour — entrypoint.sh and healthcheck.sh default them to empty
# themselves — while putting secret-named variables into the image metadata is
# exactly what hadolint DL3064 flags. See README.md and .env.sample for the
# full list.
ENV PCLOUD_MOUNT="/pcloud_internal" \
    ENABLE_BINDFS="0" \
    BINDFS_TARGET="/pcloud" \
    UID="1000" \
    GID="1000" \
    USER="nobody" \
    GROUP="users" \
    MOUNT_TIMEOUT="60"

# Each probe issues a FUSE readdir on the pCloud root (plus one on "Crypto
# Folder" when crypto is configured), which pcloudcc may service over the
# network. 60s halves that background traffic; the cost is that a persistent
# failure is reported after ~3min instead of ~1.5min (interval x retries),
# which is acceptable for a background sync daemon.
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
