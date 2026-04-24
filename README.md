# pcloudcc-docker-image

[![Build and publish](https://github.com/dev-ferris/pcloudcc-docker-image/actions/workflows/docker-build.yml/badge.svg)](https://github.com/dev-ferris/pcloudcc-docker-image/actions/workflows/docker-build.yml)
[![Lint](https://github.com/dev-ferris/pcloudcc-docker-image/actions/workflows/lint.yml/badge.svg)](https://github.com/dev-ferris/pcloudcc-docker-image/actions/workflows/lint.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-pcloudcc--docker--image-2088FF?logo=github)](https://github.com/dev-ferris/pcloudcc-docker-image/pkgs/container/pcloudcc-docker-image)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

Docker image for [pcloudcc](https://github.com/lneely/pcloudcc-lneely) — a pCloud console client for Linux, based on the actively maintained `lneely` fork.

This image fixes the SSL fingerprint issue introduced by pCloud's server certificate renewal in early 2026, which broke the original `pcloudcom/console-client` and most existing Docker images based on it.

## Upstream projects

This project is essentially a Docker packaging layer. All the real work happens upstream:

- **[lneely/pcloudcc-lneely](https://github.com/lneely/pcloudcc-lneely)** — the actively maintained pcloudcc fork that this image is built from. Huge thanks to Levi Neely for keeping this alive after the original project went inactive. Without this fork, pCloud would be unusable on Linux today.
- **[DjSni/docker-image-pCloud](https://github.com/DjSni/docker-image-pCloud)** — the Docker image this project replaces. The environment variables and compose setup here are compatible with DjSni's original, so it should be a drop-in replacement.
- **[pCloud/console-client](https://github.com/pCloud/console-client)** — the original (now inactive) client by pCloud.

## Features

- Built from the [lneely fork](https://github.com/lneely/pcloudcc-lneely) with up-to-date SSL fingerprints
- Based on `debian:trixie-slim` (Debian 13, mbedTLS 3.x native)
- Supports EU and US pCloud regions
- Optional 2FA support
- Optional crypto folder unlock
- Built-in `bindfs` for UID/GID remapping (useful on NAS setups)
- Healthcheck included
- POSIX-compliant entrypoint script with graceful shutdown
- Compatible environment variables with the `DjSni/docker-image-pCloud` setup

## Quick start

You have two options: pull the pre-built image from GHCR / Docker Hub (recommended), or build it yourself from this repository.

### Option A: Use the pre-built image (recommended)

Multi-arch images (`linux/amd64`, `linux/arm64`, `linux/arm/v7`) are published automatically on every push to `main` and on a weekly schedule. They are cosign-signed and ship with provenance and SBOM attestations.

Minimal `docker-compose.yml`:

```yaml
volumes:
  pconfig: {}

services:
  pcloud:
    image: ghcr.io/dev-ferris/pcloudcc-docker-image:latest
    # Or, from Docker Hub:
    # image: <your-dockerhub-user>/pcloudcc-docker-image:latest
    restart: unless-stopped
    volumes:
      - pconfig:/root/.pcloud:rw
      - /path/to/your/pcloud:/pcloud:rshared
    env_file:
      - .env
    environment:
      - ENABLE_BINDFS=1
    read_only: true
    tmpfs:
      - /tmp
      - /run
    security_opt:
      - apparmor:unconfined
      - no-new-privileges:true
    devices:
      - /dev/fuse
    cap_add:
      - SYS_ADMIN
    stdin_open: true
    tty: true
```

Then jump straight to [step 2](#2-create-your-env-file).

You can verify the image signature with cosign:

```bash
cosign verify \
  --certificate-identity-regexp 'https://github.com/dev-ferris/pcloudcc-docker-image/' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/dev-ferris/pcloudcc-docker-image:latest
```

### Option B: Build from source

#### 1. Clone the repository

```bash
git clone https://github.com/YOURNAME/pcloudcc-docker-image.git
cd pcloudcc-docker-image
```

#### 2. Create your `.env` file

```bash
cp .env.sample .env
```

Edit `.env` and set at least `PCLOUD_USER`. Other values are optional:

```env
PCLOUD_USER=your@email.com
PCLOUD_CRYPT=your_crypto_password
UID=1000
GID=1000
```

#### 3. Adjust volume paths in `docker-compose.yml`

By default, the compose file mounts `/path/to/your/pcloud` on the host. Change this to match your setup.

#### 4. Build and start

```bash
docker compose build
docker compose up -d
```

#### 5. First-time login

On the very first start, the container won't have saved credentials yet. Check the logs for instructions:

```bash
docker logs pcloud
```

You'll see something like:

```
No saved credentials found. Run the following inside the container:
  pcloudcc -u your@email.com -m /pcloud_internal -p -s
```

Run that command interactively:

```bash
docker exec -it pcloud pcloudcc -u your@email.com -m /pcloud_internal -p -s
```

Enter your password when prompted. If you have 2FA enabled, add `-t` to the command. Once you see `status is READY`, press `Ctrl+C` and restart the container:

```bash
docker compose restart pcloud
```

From now on, the container will start automatically without manual intervention.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `PCLOUD_USER` | Yes | — | Your pCloud account email |
| `PCLOUD_2FA` | No | — | 2FA code (only for first login) |
| `PCLOUD_CRYPT` | No | — | Crypto folder password (auto-unlocks on start) |
| `PCLOUD_MOUNT` | No | `/pcloud_internal` | Internal mount point (where pcloudcc mounts) |
| `ENABLE_BINDFS` | No | `0` | Set to `1` to enable bindfs UID/GID remapping |
| `BINDFS_TARGET` | No | `/pcloud` | Target path for bindfs overlay |
| `UID` | No | `1000` | User ID for bindfs remapping |
| `GID` | No | `1000` | Group ID for bindfs remapping |
| `USER` | No | `nobody` | Username that owns the internal mount point |
| `GROUP` | No | `users` | Group that owns the internal mount point |
| `MOUNT_TIMEOUT` | No | `120` | Seconds to wait for a mount to become ready |

## How it works

When `ENABLE_BINDFS=1` (the default in the compose file), the container mounts two filesystems:

1. **pcloudcc** mounts your pCloud drive to `/pcloud_internal` (owned by root inside the container)
2. **bindfs** overlays `/pcloud_internal` to `/pcloud` with the UID/GID you specified

The `/pcloud` path is then shared to the host via the `rshared` volume mount, so files appear with the correct ownership on your host system.

If you don't need UID/GID remapping, set `ENABLE_BINDFS=0` and mount `/pcloud_internal` directly to the host.

## Security considerations

### Why root and SYS_ADMIN?

FUSE mounts require mounting capabilities that are not available to unprivileged processes. The container therefore runs as root with `CAP_SYS_ADMIN`. This is the minimum required for `pcloudcc` and `bindfs` to create FUSE mounts inside Docker.

To limit the blast radius:

- `no-new-privileges:true` prevents privilege escalation via setuid/setgid binaries.
- `read_only: true` makes the root filesystem read-only; only the named volume and tmpfs mounts are writable.
- `CAP_SYS_ADMIN` is the only added capability; all others remain at Docker's defaults.

A custom AppArmor profile that restricts the allowed syscalls to exactly those needed by FUSE would further reduce the attack surface but is not included here, as profiles are host-specific.

### Secrets in environment variables

`PCLOUD_CRYPT` (and `PCLOUD_2FA`) are passed via environment variables, which are briefly visible in `/proc/<pid>/environ` and via `docker inspect` until they are `unset` inside the entrypoint. For higher security, consider using Docker secrets (Swarm) or a bind-mounted secrets file instead of env vars.

### Interactive login and `stdin_open`/`tty`

The compose file enables `stdin_open: true` and `tty: true` so you can attach to the container during first-time login. **Remove both options once credentials are saved** to `/root/.pcloud/data.db` to reduce the interactive attack surface.

### Supply chain

The image is built from the `lneely/pcloudcc-lneely` upstream. The `check-upstream.yml` workflow polls the upstream `main` branch every 6 hours and triggers an automatic rebuild on new commits. Every published image is:

- Scanned with Trivy (CRITICAL/HIGH/MEDIUM CVEs reported to the GitHub Security tab)
- Signed with cosign keyless signing (verifiable via `cosign verify`)
- Shipped with an SBOM and provenance attestation

To pin to a specific upstream revision, set `PCLOUDCC_REF` to a tag or commit SHA in your `docker-compose.yml` build args.

## Updating

To pull the latest version of pcloudcc:

```bash
docker compose build --no-cache
docker compose up -d
```

To pin to a specific version or commit of the lneely fork, edit `docker-compose.yml`:

```yaml
build:
  context: .
  args:
    PCLOUDCC_REF: v1.2.3   # or a commit hash / branch name
```

## Troubleshooting

**Container logs show `status is OFFLINE`:**
This usually means the SSL fingerprint check failed or credentials are wrong. Rebuild with `--no-cache` to pull the latest lneely fork with updated fingerprints.

**First-time login loop:**
If `data.db` is not being created after login, make sure the `pconfig` volume is persistent and not being recreated.

**Mount stuck after stop:**
```bash
fusermount -u /path/to/your/pcloud
```

## Migrating from DjSni/docker-image-pCloud

This project is a drop-in replacement for [DjSni/docker-image-pCloud](https://github.com/DjSni/docker-image-pCloud). The environment variables (`PCLOUD_USER`, `PCLOUD_MOUNT`, `PCLOUD_2FA`, `PCLOUD_CRYPT`) work the same way. Just swap the image in your compose file with a `build:` section pointing to this repo, rebuild, and you're set.

The main reason to migrate is that DjSni's image is based on the original `pcloudcom/console-client` v2.1.2, which stopped working after pCloud renewed their SSL certificates in early 2026. This image uses the actively maintained lneely fork with updated fingerprints.

## Acknowledgments

This project was created with the help of [Claude](https://claude.ai) (Anthropic). The Dockerfile, compose setup, and entrypoint script were iteratively developed and debugged in collaboration with Claude.

## License

MIT — see [LICENSE](LICENSE).

Note: `pcloudcc-lneely` itself is BSD-3-Clause licensed. This repository only contains the Docker packaging — all credit for the actual client goes to the lneely fork maintainers and the original pCloud developers.
