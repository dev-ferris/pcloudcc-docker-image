# syntax=docker/dockerfile:1.7
# =============================================================================
# pcloudcc Docker Image - lneely/pcloudcc-lneely fork
# Base: debian:trixie-slim (Debian 13 - mbedTLS 3.x native)
#
# The base image is pinned by digest; Dependabot proposes updates as PRs.
# =============================================================================

# ===== Stage 1: Build =====
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS builder

# Upstream commit to build. Pinned so every build of this repository compiles
# reviewed code; .github/workflows/check-upstream.yml opens a PR to move it
# when upstream changes. Override with --build-arg (branch, tag or SHA) to
# build something else. Keep it on one line: the workflow rewrites it.
ARG PCLOUDCC_REF=93a99cd6add26ffc403113d1a8f7fca34274fa02

# Dependencies per upstream doc/BUILD.md. No Boost: upstream uses the vendored
# CLI11.hpp since lneely#396.
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
# `git fetch` rather than `clone --branch`, so PCLOUDCC_REF may also be a SHA.
RUN git init -q \
    && git fetch --depth 1 \
        https://github.com/lneely/pcloudcc-lneely.git "${PCLOUDCC_REF}" \
    && git checkout -q FETCH_HEAD \
    && git rev-parse HEAD > /build/pcloudcc.commit \
    && make -j"$(nproc)" \
    && strip pcloudcc

# ===== Stage 2: Runtime =====
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

# licenses/source describe this image (the packaging layer, MIT). The bundled
# pcloudcc binary itself is BSD-3-Clause; its origin is recorded separately.
LABEL org.opencontainers.image.title="pcloudcc" \
      org.opencontainers.image.description="pCloud console client (lneely fork)" \
      org.opencontainers.image.source="https://github.com/dev-ferris/pcloudcc-docker-image" \
      org.opencontainers.image.licenses="MIT" \
      pcloudcc.upstream.source="https://github.com/lneely/pcloudcc-lneely" \
      pcloudcc.upstream.licenses="BSD-3-Clause"

# Intentionally not installed:
#   ca-certificates - pulls in openssl/libssl3. pcloudcc uses mbedTLS with
#                     pinned certificate fingerprints; the CA bundle is copied
#                     from the builder below as a plain file instead.
#   util-linux      - provides `mountpoint`, but is Essential and already in
#                     the base image (the CI smoke test checks for it).
#   bindfs          - replaced by pcloudcc's own uid=/gid= FUSE options.
#
# /pcloud is the default mount point; created here so it exists even with
# read_only: true and no bind mount.
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

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /build/pcloudcc /usr/local/bin/pcloudcc
# The upstream commit the binary was actually built from.
COPY --from=builder /build/pcloudcc.commit /usr/local/share/pcloudcc/upstream-commit
COPY --chmod=644 common.sh /usr/local/lib/pcloudcc/common.sh
COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 healthcheck.sh /healthcheck.sh

# Only non-credential settings get a default here. Credentials are supplied at
# runtime (preferably as secret files) and never baked into image metadata.
# ENABLE_BINDFS, BINDFS_TARGET, UID and GID are deprecated aliases, see
# apply_bindfs_compat() in entrypoint.sh.
ENV PCLOUD_MOUNT="/pcloud" \
    ENABLE_BINDFS="0" \
    BINDFS_TARGET="/pcloud" \
    UID="1000" \
    GID="1000" \
    MOUNT_TIMEOUT="60"

# Each probe reads the pCloud root (plus the Crypto Folder when configured),
# which pcloudcc may serve over the network, so probe once a minute.
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
