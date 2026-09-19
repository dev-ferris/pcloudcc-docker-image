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
- Optional 2FA support, with unattended first-time login via `PCLOUD_TOTP_SECRET` (TOTP shared secret)
- Optional crypto folder unlock
- Built-in `bindfs` for UID/GID remapping (useful on NAS setups)
- Healthcheck included
- POSIX-compliant entrypoint script with graceful shutdown
- Compatible environment variables with the `DjSni/docker-image-pCloud` setup

## Is a FUSE mount what you actually need?

In September 2026 pCloud opened up [rsync, WebDAV, SFTP and SCP access in
beta](https://blog.pcloud.com/efficient-nas-backup/), aimed squarely at NAS
backups. That changes the picture for some of the people who end up here, so
it is worth being explicit about what this image is and is not.

**This image gives you a mounted filesystem.** `pcloudcc` keeps a FUSE mount
live for as long as the container runs, so your pCloud storage behaves like a
local directory: applications can open files in place, Docker containers can
bind-mount subdirectories, and files arrive without an explicit sync step.

**pCloud's new protocols give you a transfer channel.** They move files on
demand, on your schedule. For a nightly "push this NAS share to the cloud"
job that is a much better fit: `rsync` and friends do delta transfers,
resume, parallelism and integrity checking, none of which a FUSE mount does
well. Copying a large tree *through* a FUSE mount means every byte crosses
the kernel/userspace boundary and the client's cache, which is slower and
more fragile than letting a transfer tool talk to the service directly.

So, roughly:

| What you want to do | Use |
|---|---|
| Back up a NAS share to pCloud on a schedule | `rsync`/SFTP/SCP, or [rclone](https://rclone.org/pcloud/) |
| Bulk-copy or mirror large trees | `rclone` (native pCloud API backend, not WebDAV) |
| Mount pCloud so apps can read/write files in place | **this image** |
| Use the Crypto Folder from Linux | **this image** — see below |
| Attach pCloud to an app that speaks WebDAV | WebDAV directly, no container needed |

Two caveats worth knowing before you migrate anything:

- **The Crypto Folder is not reachable over WebDAV, rsync, SFTP or SCP.**
  pCloud's client-side encryption is only implemented in their own clients,
  and `pcloudcc` is the only one of those that runs headless on Linux. If you
  use Crypto, this image stays the only option — that is not a limitation this
  packaging can lift.
- **WebDAV is a paid-plan feature, and rsync/SFTP/SCP are still in beta.** Check
  pCloud's [help center](https://help.pcloud.com/article/connect-to-pcloud-using-webdav-and-rsync)
  for the current endpoints and status rather than trusting a hostname copied
  out of a blog post.

Using both is perfectly reasonable: mount with this image for interactive
access, and back up with `rclone` or `rsync` against the service directly.

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
    init: true               # zombie reaping + signal forwarding
    stop_grace_period: 30s   # allow graceful pcloudcc shutdown + FUSE unmount
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
      - /pcloud_internal
    security_opt:
      - apparmor:unconfined
      - no-new-privileges:true
    devices:
      - /dev/fuse
    cap_drop:
      - ALL
    cap_add:
      - SYS_ADMIN    # FUSE mount/umount
      - CHOWN        # entrypoint chowns the internal mount point
    stdin_open: true
    tty: true
    logging:                 # cap the log file for a long-running daemon
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

> **Note:** `/pcloud_internal` must be in the `tmpfs` list when `read_only: true` is used, otherwise the entrypoint can't create or chown the mount point.
> Once first-time login is complete, remove `stdin_open` and `tty` to reduce the interactive attack surface.

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
# Set these only for the first start — once data.db is saved you can remove them.
PCLOUD_PASSWORD=your_account_password
PCLOUD_TOTP_SECRET=JBSWY3DPEHPK3PXP   # base32 secret from your authenticator (if 2FA is enabled)
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

On the very first start, the container has no saved credentials yet. There are
two ways to handle this.

##### Option 1 — Unattended (recommended)

Set `PCLOUD_PASSWORD` in your `.env` file. If 2FA is enabled, also set
`PCLOUD_TOTP_SECRET` (the base32 shared secret your authenticator showed you
when you set up 2FA — usually labeled *secret key* or *manual entry key*).
The entrypoint will then perform the first-time login automatically, generate
a fresh TOTP code via `oathtool`, and save credentials to `data.db`.

```env
PCLOUD_PASSWORD=your_account_password
PCLOUD_TOTP_SECRET=JBSWY3DPEHPK3PXP
```

Alternatively, you can provide a single fresh 6-digit code via `PCLOUD_2FA`
instead of `PCLOUD_TOTP_SECRET` — but note that codes expire after ~30 seconds,
so the container must start within that window.

**Once `data.db` has been created, remove `PCLOUD_PASSWORD`, `PCLOUD_TOTP_SECRET`
and `PCLOUD_2FA` from `.env`** — they are only needed for the initial setup
and would otherwise sit in the container environment unnecessarily.

##### Option 2 — Interactive

Leave `PCLOUD_PASSWORD` unset. The container logs will show:

```
No saved credentials found. Either set PCLOUD_PASSWORD (and PCLOUD_TOTP_SECRET
or PCLOUD_2FA if 2FA is enabled) for automatic login, or run the following
inside the container:
  docker exec -it <container> pcloudcc -u your@email.com -m /pcloud_internal -p -s
```

Run that command (substituting your container name, e.g. `pcloud`):

```bash
docker exec -it pcloud pcloudcc -u your@email.com -m /pcloud_internal -p -s
```

Enter your password when prompted. If you have 2FA enabled, append `-t <code>`
with a fresh code from your authenticator app. Once you see `status is READY`,
press `Ctrl+C` and restart the container:

```bash
docker compose restart pcloud
```

From now on, the container will start automatically without manual intervention.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `PCLOUD_USER` | Yes | — | Your pCloud account email |
| `PCLOUD_PASSWORD` | No | — | Account password. If set, the entrypoint performs the first-time login automatically and can be removed once `data.db` exists. |
| `PCLOUD_PASSWORD_FILE` | No | — | Path to a file with the account password (e.g. `/run/secrets/pcloud_password`); takes precedence over `PCLOUD_PASSWORD` |
| `PCLOUD_TOTP_SECRET` | No | — | TOTP shared secret (base32). If set, fresh 6-digit codes are generated on demand with `oathtool`, so first-time login works unattended. |
| `PCLOUD_TOTP_SECRET_FILE` | No | — | Path to a file with the TOTP secret; takes precedence over `PCLOUD_TOTP_SECRET` |
| `PCLOUD_2FA` | No | — | Single-use 2FA code (alternative to `PCLOUD_TOTP_SECRET` — codes expire after ~30s) |
| `PCLOUD_CRYPT` | No | — | Crypto folder password (auto-unlocks on start) |
| `PCLOUD_CRYPT_FILE` | No | — | Path to a file with the crypto password (e.g. `/run/secrets/pcloud_crypt`); takes precedence over `PCLOUD_CRYPT` |
| `PCLOUD_MOUNT` | No | `/pcloud_internal` | Internal mount point (where pcloudcc mounts) |
| `ENABLE_BINDFS` | No | `0` | Set to `1` to enable bindfs UID/GID remapping |
| `BINDFS_TARGET` | No | `/pcloud` | Target path for bindfs overlay |
| `UID` | No | `1000` | User ID for bindfs remapping |
| `GID` | No | `1000` | Group ID for bindfs remapping |
| `USER` | No | `nobody` | Username that owns the internal mount point |
| `GROUP` | No | `users` | Group that owns the internal mount point |
| `MOUNT_TIMEOUT` | No | `60` | Seconds to wait for a mount to become ready (raise to 120+ on slow ARM devices or high-latency links) |
| `PCLOUD_CACHE_SIZE` | No | — | pcloudcc's local cache limit in GB (its own default is 5). The cache lives in the `pconfig` volume. |
| `PCLOUD_LOG_LEVEL` | No | — | Verbosity of pcloudcc's own `debug.log`: `NONE`, `ERROR`, `WARNING`, `INFO` (its own default), `NOTICE`, `DEBUG` |
| `PCLOUD_FUSE_OPTS` | No | — | Extra FUSE mount options, comma-separated (e.g. `uid=1000,gid=1000`, `allow_other`) |

The last three are passed straight through to `pcloudcc` and are omitted entirely
when unset, so its built-in defaults apply. They need an upstream build from
2026-05 or newer — with an older `PCLOUDCC_REF` the flags do not exist and the
daemon will refuse to start.

### Disk usage inside the `pconfig` volume

Two things grow inside `/root/.pcloud`, and neither is covered by the `logging:`
limits in `docker-compose.yml` — those only cap Docker's capture of the
container's stdout/stderr:

- **the file cache**, up to 5 GB by default. Lower it with `PCLOUD_CACHE_SIZE`
  if that volume lives on a small system partition (a common situation on NAS
  boxes, where `/var/lib/docker` sits on the boot device).
- **`debug.log`**, written at `INFO` level by default. `PCLOUD_LOG_LEVEL=ERROR`
  is a reasonable setting for an unattended container; upstream also ships a
  `logrotate` snippet and rotates on `SIGUSR2`.

## How it works

When `ENABLE_BINDFS=1` (the default in the compose file), the container mounts two filesystems:

1. **pcloudcc** mounts your pCloud drive to `/pcloud_internal` (owned by root inside the container)
2. **bindfs** overlays `/pcloud_internal` to `/pcloud` with the UID/GID you specified

The `/pcloud` path is then shared to the host via the `rshared` volume mount, so files appear with the correct ownership on your host system.

If you don't need UID/GID remapping, set `ENABLE_BINDFS=0` **and** change the host bind mount in `docker-compose.yml` from `:/pcloud:rshared` to `:/pcloud_internal:rshared` (and drop the `/pcloud_internal` entry from `tmpfs` — otherwise the host mount would be shadowed by the tmpfs and data would not persist).

## Security considerations

### Why root and SYS_ADMIN?

FUSE mounts require mounting capabilities that are not available to unprivileged processes. The container therefore runs as root with `CAP_SYS_ADMIN`. This is the minimum required for `pcloudcc` and `bindfs` to create FUSE mounts inside Docker.

To limit the blast radius:

- `no-new-privileges:true` prevents privilege escalation via setuid/setgid binaries.
- `read_only: true` makes the root filesystem read-only; only the named volume and tmpfs mounts are writable.
- All default capabilities are dropped via `cap_drop: [ALL]`; only `SYS_ADMIN` (FUSE mount) and `CHOWN` (internal mount-point ownership) are re-added.

A custom AppArmor profile that restricts the allowed syscalls to exactly those needed by FUSE would further reduce the attack surface but is not included here, as profiles are host-specific.

### Secrets in environment variables

`PCLOUD_CRYPT`, `PCLOUD_PASSWORD`, `PCLOUD_TOTP_SECRET` and `PCLOUD_2FA` are passed via environment variables, which are briefly visible in `/proc/<pid>/environ` and via `docker inspect` until they are `unset` inside the entrypoint. For higher security, use the corresponding `*_FILE` variants (`PCLOUD_CRYPT_FILE`, `PCLOUD_PASSWORD_FILE`, `PCLOUD_TOTP_SECRET_FILE`) to point to a file (or Docker secret) that contains the value:

```yaml
# docker-compose.yml (Docker Swarm)
secrets:
  pcloud_crypt:
    external: true

services:
  pcloud:
    secrets:
      - pcloud_crypt
    environment:
      - PCLOUD_CRYPT_FILE=/run/secrets/pcloud_crypt
```

Or with a plain bind-mounted file (Compose standalone):

```yaml
services:
  pcloud:
    volumes:
      - ./secrets/pcloud_crypt.txt:/run/secrets/pcloud_crypt:ro
    environment:
      - PCLOUD_CRYPT_FILE=/run/secrets/pcloud_crypt
```

### Interactive login and `stdin_open`/`tty`

The compose file enables `stdin_open: true` and `tty: true` so you can attach to the container during first-time login. **Remove both options once credentials are saved** to `/root/.pcloud/data.db` to reduce the interactive attack surface. If you use the unattended login flow (`PCLOUD_PASSWORD` + `PCLOUD_TOTP_SECRET`), `stdin_open`/`tty` are not needed at all.

### Supply chain

The image is built from the `lneely/pcloudcc-lneely` upstream. The `check-upstream.yml` workflow polls the upstream `main` branch every 6 hours and triggers an automatic rebuild on new commits, dispatching the **resolved commit SHA** rather than the branch name — `PCLOUDCC_REF` is part of the Docker layer cache key, so a moving branch name would let a "successful" rebuild silently reuse the previously compiled binary. The weekly scheduled build additionally runs with the layer cache disabled, so it genuinely re-resolves `apt-get install` against the current Debian archive instead of republishing an identical image.

Every published image is:

- Scanned with Trivy — CRITICAL/HIGH CVEs with an available fix block the build; the full scan results (all severities, including findings without an available fix) are uploaded to the GitHub Security tab
- Signed with cosign keyless signing (verifiable via `cosign verify`)
- Shipped with an SBOM and provenance attestation

The exact upstream commit compiled into an image is recorded inside it:

```bash
docker run --rm --entrypoint cat ghcr.io/dev-ferris/pcloudcc-docker-image:latest \
  /usr/local/share/pcloudcc/upstream-commit
```

To pin to a specific upstream revision, set `PCLOUDCC_REF` to a tag or commit SHA in your `docker-compose.yml` build args.

## Updating

To pull the latest version of pcloudcc:

```bash
docker compose build --no-cache
docker compose up -d
```

`--no-cache` is required, not optional: with `PCLOUDCC_REF: main` the layer that
fetches and compiles upstream has an unchanged cache key even after upstream
moves on, so a plain `docker compose build` would rebuild nothing. Alternatively,
pin `PCLOUDCC_REF` to the commit SHA you want — a changed SHA busts the cache on
its own.

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
# Debian/Ubuntu's fuse3 package provides both names; on other distributions
# the fuse 3.x helper is only installed as `fusermount3`.
fusermount3 -u /path/to/your/pcloud || fusermount -u /path/to/your/pcloud
```

## Migrating from DjSni/docker-image-pCloud

This project is a drop-in replacement for [DjSni/docker-image-pCloud](https://github.com/DjSni/docker-image-pCloud). The environment variables (`PCLOUD_USER`, `PCLOUD_MOUNT`, `PCLOUD_2FA`, `PCLOUD_CRYPT`) work the same way; this image additionally accepts `PCLOUD_PASSWORD` and `PCLOUD_TOTP_SECRET` for fully unattended first-time login. Just swap the image in your compose file with a `build:` section pointing to this repo, rebuild, and you're set.

The main reason to migrate is that DjSni's image is based on the original `pcloudcom/console-client` v2.1.2, which stopped working after pCloud renewed their SSL certificates in early 2026. This image uses the actively maintained lneely fork with updated fingerprints.

## Acknowledgments

This project was created with the help of [Claude](https://claude.ai) (Anthropic). The Dockerfile, compose setup, and entrypoint script were iteratively developed and debugged in collaboration with Claude.

## License

MIT — see [LICENSE](LICENSE).

Note: `pcloudcc-lneely` itself is BSD-3-Clause licensed. This repository only contains the Docker packaging — all credit for the actual client goes to the lneely fork maintainers and the original pCloud developers.
