# syntax=docker/dockerfile:1.7
# =============================================================================
# pcloudcc Docker Image - lneely/pcloudcc-lneely fork
# Base: debian:trixie-slim (Debian 13 - mbedTLS 3.x native)
# =============================================================================

# ===== Stage 1: Build =====
FROM debian:trixie-slim AS builder

ARG PCLOUDCC_REF=main

# Dependency list mirrors upstream doc/BUILD.md: zlib, pthread, udev, fuse,
# sqlite, mbedTLS, readline. Boost is deliberately absent — upstream replaced
# Boost.Program_options with the vendored single-header CLI11.hpp (lneely#396,
# 2026-05-01) and the Makefile no longer links any boost library. Keeping the
# -dev packages around only lengthened the build and dragged two more shared
# libraries into the runtime image for Trivy to scan.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    libfuse3-dev \
    libudev-dev \
    libmbedtls-dev \
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
      org.opencontainers.image.description="pCloud console client (lneely fork)" \
      org.opencontainers.image.source="https://github.com/dev-ferris/pcloudcc-docker-image" \
      org.opencontainers.image.licenses="MIT" \
      pcloudcc.upstream.source="https://github.com/lneely/pcloudcc-lneely" \
      pcloudcc.upstream.licenses="BSD-3-Clause"

# Deliberately absent from this list, each for its own reason:
#
#   bindfs      - the uid/gid remapping overlay was dropped. It meant a second
#                 FUSE process on top of pcloudcc's own mount for what is really
#                 a mount-option concern, and it is the one runtime dependency
#                 with no packaged equivalent outside Debian/Ubuntu (Alpine
#                 carries it in edge/testing only), which pinned the base image
#                 to Debian. ENABLE_BINDFS/BINDFS_TARGET/UID/GID are still
#                 accepted by entrypoint.sh - see the shim there.
#   ca-certificates
#               - it Depends on openssl, so installing it dragged openssl,
#                 libssl3 and debconf into the runtime layer for Trivy to scan.
#                 pcloudcc speaks TLS through mbedTLS against pinned pCloud
#                 certificate fingerprints compiled into the binary, and nothing
#                 else in this image makes an outbound TLS connection. The trust
#                 store itself is still copied in below as a plain file, so any
#                 library that does go looking for it finds it - a file carries
#                 no package metadata and no CVEs.
#   util-linux  - `mountpoint`, which entrypoint.sh and healthcheck.sh use, ships
#                 in util-linux, which is Essential in Debian and therefore
#                 already present in the slim base. Installing it explicitly was
#                 a no-op. The smoke test in .github/workflows/docker-build.yml
#                 asserts `mountpoint` exists, so a future de-essentialization
#                 would fail CI rather than the container.
#
# /pcloud is pre-created: it is the PCLOUD_MOUNT default, what
# docker-compose.yml bind-mounts, and what ENABLE_BINDFS=1 resolves to. With
# `read_only: true` it could not be created at runtime unless it is
# bind-mounted or a tmpfs. (/pcloud_internal is gone: it only existed as the
# private lower layer under the bindfs overlay.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    fuse3 \
    libfuse3-4 \
    libudev1 \
    libmbedtls21 \
    libmbedcrypto16 \
    libreadline8t64 \
    libsqlite3-0 \
    zlib1g \
    oathtool \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /pcloud

# The CA bundle without the package that generates it. The builder stage needs
# ca-certificates anyway (git fetches over HTTPS), so take the generated bundle
# from there. It is frozen at build time - no update-ca-certificates here - which
# the weekly scheduled rebuild takes care of.
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

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
#
# ENABLE_BINDFS, BINDFS_TARGET, UID and GID no longer drive a bindfs overlay.
# They are kept, and keep their old meaning: apply_bindfs_compat() in
# entrypoint.sh translates them into the mount point and the uid=/gid=/
# allow_other FUSE options of pcloudcc's own mount.
ENV PCLOUD_MOUNT="/pcloud" \
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
