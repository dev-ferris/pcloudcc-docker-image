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
- Based on `debian:trixie-slim` (Debian 13, mbedTLS 3.x native), or on Alpine
  Linux for a much smaller image (see [Alpine variant](#alpine-variant))
- Supports EU and US pCloud regions
- Optional 2FA support, with unattended first-time login via `PCLOUD_TOTP_SECRET` (TOTP shared secret)
- Optional crypto folder unlock
- Minimal runtime layer: no `bindfs`, no `ca-certificates`/`openssl` (see [How it works](#how-it-works))
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
    # image: devferris/pcloudcc-docker-image:latest
    restart: unless-stopped
    init: true               # zombie reaping + signal forwarding
    stop_grace_period: 30s   # allow graceful pcloudcc shutdown + FUSE unmount
    volumes:
      - pconfig:/root/.pcloud:rw
      - /path/to/your/pcloud:/pcloud:rshared
    env_file:
      - .env
    environment:
      - PCLOUD_MOUNT=/pcloud
      - PCLOUD_FUSE_OPTS=uid=1000,gid=1000,allow_other,default_permissions
    read_only: true
    tmpfs:
      - /tmp
      - /run
    security_opt:
      - apparmor:unconfined
      - no-new-privileges:true
    devices:
      - /dev/fuse
    cap_drop:
      - ALL
    cap_add:
      - SYS_ADMIN    # FUSE mount/umount
    stdin_open: true
    tty: true
    logging:                 # cap the log file for a long-running daemon
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

> **Note:** with `read_only: true` the entrypoint can only create `PCLOUD_MOUNT` if that path is writable — either bind-mounted from the host as above, or listed under `tmpfs`. If you point `PCLOUD_MOUNT` somewhere that is neither, startup fails with an explicit error.
> Once first-time login is complete, remove `stdin_open` and `tty` to reduce the interactive attack surface.

Then jump straight to [step 2](#2-create-your-env-file).

You can verify the image signature with cosign:

```bash
cosign verify \
  --certificate-identity-regexp 'https://github.com/dev-ferris/pcloudcc-docker-image/' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/dev-ferris/pcloudcc-docker-image:latest
```

### Image tags

Every image is built from one upstream commit. Which one decides its channel:

- **release** — built from the default branch or a `v*` tag of this
  repository, always with the upstream commit pinned in the `Dockerfile`.
  Only these take `latest`.
- **edge** — a newer upstream commit that has not been reviewed yet (see
  [Supply chain](#supply-chain)). Built, scanned and smoke-tested like a
  release, but published only under `edge` tags.
- **dev** — any other branch of this repository.

| Tag | Channel | Produced by |
|---|---|---|
| `latest` | release | every push to the default branch |
| `main` | release | every push to the default branch |
| `1.2.3`, `1.2` | release | a pushed `v*` git tag |
| `YYYY-MM-DD` | release | any non-PR release build that day |
| `weekly` (`nightly`) | release | the weekly scheduled rebuild; `nightly` is the old name, kept for compatibility |
| `edge` | edge | the most recent build of a new upstream commit or tag |
| `edge-<ref>` | edge | same, for one upstream commit SHA or tag |
| `dev-<branch>` | dev | a manual run of the build workflow on that branch |
| `dev-<sha>` | dev | same, pinned to one commit |

The channel is also recorded in the image itself, so it survives being pulled
and re-tagged:

```bash
docker image inspect --format '{{index .Config.Labels "pcloudcc.build.channel"}}' \
  ghcr.io/dev-ferris/pcloudcc-docker-image:latest
```

Edge and development images pass the same Trivy gate, smoke test and signing
as release images, but contain unreviewed code — don't run them in production.

### Alpine variant

Every image also exists as an Alpine Linux (musl) build, with the same tags
plus an `-alpine` suffix: `latest-alpine`, `1.2.3-alpine`, `edge-alpine`, and
so on. It is built from `Dockerfile.alpine`, runs the same entrypoint and
healthcheck, takes the same environment variables and secrets, and passes the
same gates. Only the base image differs, and with it the size: the Alpine
image is much smaller.

```yaml
services:
  pcloud:
    image: ghcr.io/dev-ferris/pcloudcc-docker-image:latest-alpine
```

Differences worth knowing:

- **Experimental.** Upstream develops and tests against glibc. pcloudcc builds
  on musl with one small shim (`execinfo.h`, which musl lacks), whose only
  effect is that a crash prints no backtrace. It links Alpine's `mbedtls3`
  (the 3.6 LTS branch, like Debian), since pcloudcc does not support
  mbedTLS 4 yet. If you hit a problem, check
  whether the Debian image has it too before reporting it upstream.
- **No package manager.** `apk` is removed from the final image, which also
  removes OpenSSL — the Debian image leaves it out for the same reason. To add
  packages, build your own image from `Dockerfile.alpine` and install them
  before the `apk del` line.
- **BusyBox** provides `/bin/sh` and the small tools (`mountpoint`, `find`,
  `ls`). CI runs the script test suite under BusyBox as well as under dash.

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

Edit `.env` and set at least `PCLOUD_USER`:

```env
PCLOUD_USER=your@email.com
```

Passwords and the TOTP secret do not belong in `.env` — put them in secret
files instead (see [Secrets](#secrets-use-files-not-environment-variables)):

```bash
mkdir -p secrets && chmod 700 secrets
printf '%s' 'your-account-password' > secrets/pcloud_password      # first start only
printf '%s' 'JBSWY3DPEHPK3PXP'      > secrets/pcloud_totp_secret   # first start only, if 2FA is enabled
printf '%s' 'your-crypto-password'  > secrets/pcloud_crypt         # if you use the Crypto Folder
chmod 600 secrets/*
```

Then uncomment the `secrets:` blocks in `docker-compose.yml`, keeping only the
entries whose files you created. (Commands like the above end up in your shell
history; creating the files with an editor avoids that.)

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

Provide the account password as the `pcloud_password` secret. If 2FA is
enabled, also provide `pcloud_totp_secret` (the base32 shared secret your
authenticator showed you when you set up 2FA — usually labeled *secret key* or
*manual entry key*). See step 2 above. The environment variables
`PCLOUD_PASSWORD` / `PCLOUD_TOTP_SECRET` still work, but stay visible via
`docker inspect`.

The entrypoint will then perform the first-time login automatically, generate
a fresh TOTP code via `oathtool`, and save credentials to `data.db`.

Alternatively, you can provide a single fresh 6-digit code via `PCLOUD_2FA`
instead of `PCLOUD_TOTP_SECRET` — but note that codes expire after ~30 seconds,
so the container must start within that window.

**Once `data.db` has been created, remove the `pcloud_password` and
`pcloud_totp_secret` secrets (files and compose entries), and `PCLOUD_2FA` if
you used it** — they are only needed for the initial setup.

##### Option 2 — Interactive

Provide no account password. The container logs will show:

```
No saved credentials found. Either provide the account password as the
pcloud_password secret (and pcloud_totp_secret if 2FA is enabled) for
automatic login, or run the following inside the container:
  docker exec -it <container> pcloudcc -u your@email.com -m /pcloud -p -s
```

Run that command (substituting your container name, e.g. `pcloud`). The `-m`
path is whatever `PCLOUD_MOUNT` is set to — the message above already contains
the right one, so copy it from your own logs rather than from here:

```bash
docker exec -it pcloud pcloudcc -u your@email.com -m /pcloud -p -s
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
| `PCLOUD_PASSWORD_FILE` | No | `/run/secrets/pcloud_password` if present | Path to a file with the account password; takes precedence over `PCLOUD_PASSWORD`. See [Secrets](#secrets-use-files-not-environment-variables) |
| `PCLOUD_TOTP_SECRET` | No | — | TOTP shared secret (base32). If set, fresh 6-digit codes are generated on demand with `oathtool`, so first-time login works unattended. |
| `PCLOUD_TOTP_SECRET_FILE` | No | `/run/secrets/pcloud_totp_secret` if present | Path to a file with the TOTP secret; takes precedence over `PCLOUD_TOTP_SECRET` |
| `PCLOUD_2FA` | No | — | Single-use 2FA code (alternative to `PCLOUD_TOTP_SECRET` — codes expire after ~30s) |
| `PCLOUD_CRYPT` | No | — | Crypto folder password (auto-unlocks on start) |
| `PCLOUD_CRYPT_FILE` | No | `/run/secrets/pcloud_crypt` if present | Path to a file with the crypto password; takes precedence over `PCLOUD_CRYPT` |
| `PCLOUD_MOUNT` | No | `/pcloud` | Where pcloudcc mounts the pCloud filesystem. Must match the host bind mount in `docker-compose.yml` |
| `ENABLE_BINDFS` | No | `0` | **Deprecated.** `1` mounts at `BINDFS_TARGET` and fills `PCLOUD_FUSE_OPTS` with `uid=$UID,gid=$GID,allow_other,default_permissions` |
| `BINDFS_TARGET` | No | `/pcloud` | **Deprecated.** Becomes `PCLOUD_MOUNT` when `ENABLE_BINDFS=1` |
| `UID` | No | `1000` | **Deprecated.** Applied as the FUSE `uid=` option when `ENABLE_BINDFS=1` |
| `GID` | No | `1000` | **Deprecated.** Applied as the FUSE `gid=` option when `ENABLE_BINDFS=1` |
| `MOUNT_TIMEOUT` | No | `60` | Seconds to wait for a mount to become ready (raise to 120+ on slow ARM devices or high-latency links) |
| `PCLOUD_CACHE_SIZE` | No | — | pcloudcc's local cache limit in GB (its own default is 5). The cache lives in the `pconfig` volume. |
| `PCLOUD_LOG_LEVEL` | No | — | Verbosity of pcloudcc's own `debug.log`: `NONE`, `ERROR`, `WARNING`, `INFO` (its own default), `NOTICE`, `DEBUG` |
| `PCLOUD_FUSE_OPTS` | No | — | Extra FUSE mount options, comma-separated (e.g. `uid=1000,gid=1000,allow_other,default_permissions`). Options set here are never overwritten by `ENABLE_BINDFS=1`. Always pair `allow_other` with `default_permissions` — see [Security considerations](#security-considerations) |

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

There is exactly one filesystem in play: **pcloudcc** mounts your pCloud drive at
`PCLOUD_MOUNT`, which the compose file sets to `/pcloud` and shares to the host
via the `rshared` volume mount. Point `PCLOUD_MOUNT` and the host bind mount at
the same path and you are done.

File ownership inside the mount comes from the FUSE options `uid=`/`gid=` in
`PCLOUD_FUSE_OPTS`. The directory underneath is hidden by the mount and is not
touched: earlier versions ran `chown -R USER:GROUP` on it, which also rewrote
the ownership of everything already in the bind-mounted host directory. That
step, the `USER`/`GROUP` variables and the `CHOWN` capability are gone; the
entrypoint logs a notice if `GROUP` is still set.

### What happened to bindfs

Earlier versions ran a second FUSE process: pcloudcc mounted at
`/pcloud_internal` and `bindfs` re-exported that at `/pcloud` with file
ownership rewritten to `UID:GID`. That is gone. It doubled the FUSE layers for
what is really a mount-option concern, and `bindfs` is packaged only in
Debian/Ubuntu — Alpine carries it in `edge/testing` only — which tied the image
to a Debian base and kept its CVE feed attached to the scan results.

Existing configurations keep working, including the UID/GID remapping. Both
halves of the old behaviour are reproduced on pcloudcc's own mount, so
`ENABLE_BINDFS=1` needs no change on your side:

| | Before | Now |
|---|---|---|
| Path | pcloudcc at `/pcloud_internal`, bindfs re-exports at `BINDFS_TARGET` | pcloudcc mounts at `BINDFS_TARGET` directly |
| Ownership | `bindfs -u $UID -g $GID` rewrites it | `--fuse-opts uid=$UID,gid=$GID` makes pcloudcc report it |
| Access control | bindfs adds `allow_other` + `default_permissions` | the same two options, added alongside |
| Processes | `pcloudcc` + `bindfs` | `pcloudcc` |

`allow_other` is part of the set rather than an extra: the mount is created by
root, and without it the kernel denies access to every other uid — including
the one the files are now reported as belonging to, which would make the
remapping pointless. `default_permissions` is equally non-optional, and for a
less obvious reason — see [Security considerations](#security-considerations).

Options you set in `PCLOUD_FUSE_OPTS` yourself are never overwritten, matched
per option key. That is also the escape hatch if your kernel/libfuse rejects
one of these: set `PCLOUD_FUSE_OPTS` explicitly, or move to `PCLOUD_MOUNT` and
`ENABLE_BINDFS=0`. The entrypoint logs the options it ended up passing, and a
one-off deprecation notice, at startup.

## Security considerations

### Why root and SYS_ADMIN?

FUSE mounts require mounting capabilities that are not available to unprivileged processes. The container therefore runs as root with `CAP_SYS_ADMIN`. This is the minimum required for `pcloudcc` to create a FUSE mount inside Docker.

To limit the blast radius:

- `no-new-privileges:true` prevents privilege escalation via setuid/setgid binaries.
- `read_only: true` makes the root filesystem read-only; only the named volume and tmpfs mounts are writable.
- All default capabilities are dropped via `cap_drop: [ALL]`; only `SYS_ADMIN` (FUSE mount) is re-added.
- `allow_other` — set explicitly via `PCLOUD_FUSE_OPTS`, or implicitly by `ENABLE_BINDFS=1` — makes the mount reachable by every uid, not just the one that created it. That is what lets the remapped `UID`/`GID` reach the files at all, but it is a widening: leave it off if nothing but `root` needs the mount.

### Why `allow_other` must be paired with `default_permissions`

FUSE does not enforce the mode bits a filesystem reports unless the mount carries `default_permissions`; without it, access control is the filesystem's own job. `pcloudcc` does not do that job — upstream's `psync_oper` binds 29 handlers and `access` is not one of them, and the `PSYNC_PERM_MODIFY` checks in `pfs_open` are pCloud's per-path *account* permissions, which are identical no matter which local uid is calling.

So `allow_other` on its own means every uid that can reach the mount has full read/write over the entire pCloud account — including the decrypted `Crypto Folder` after unlock — regardless of the `1000:1000` / `0644` ownership `ls` displays. Since the mount is normally the `rshared` bind mount, "every uid that can reach it" means every local account on the host, including service accounts.

`bindfs` never had this gap: it added `-odefault_permissions` unconditionally next to its own `-oallow_other`. `ENABLE_BINDFS=1` and the shipped compose file therefore set both, and the entrypoint prints a warning if it finds `allow_other` in a hand-written `PCLOUD_FUSE_OPTS` without it.
- The runtime layer carries no `ca-certificates` package and therefore no `openssl`/`libssl3`. pcloudcc validates pCloud's TLS certificates against fingerprints compiled into the binary, and nothing else in the image opens an outbound TLS connection; the generated CA bundle is still copied in from the build stage as a plain file at `/etc/ssl/certs/ca-certificates.crt`.

A custom AppArmor profile that restricts the allowed syscalls to exactly those needed by FUSE would further reduce the attack surface but is not included here, as profiles are host-specific.

### Secrets: use files, not environment variables

Environment variables are the wrong place for credentials. Whatever is passed
through `environment:` or `env_file:` stays readable for the container's whole
lifetime — via `docker inspect`, and in the environment of PID 1 — no matter
what the entrypoint unsets later. A TOTP secret stored that way sits right
next to the password, which makes the second factor pointless.

So provide `PCLOUD_PASSWORD`, `PCLOUD_TOTP_SECRET` and `PCLOUD_CRYPT` as secret
files. Plain `docker compose` supports file-based secrets without Swarm:

```bash
mkdir -p secrets && chmod 700 secrets
printf '%s' 'your-account-password' > secrets/pcloud_password
printf '%s' 'JBSWY3DPEHPK3PXP'      > secrets/pcloud_totp_secret   # only with 2FA
printf '%s' 'your-crypto-password'  > secrets/pcloud_crypt         # only with Crypto Folder
chmod 600 secrets/*
```

```yaml
# docker-compose.yml
secrets:
  pcloud_password:
    file: ./secrets/pcloud_password
  pcloud_totp_secret:
    file: ./secrets/pcloud_totp_secret
  pcloud_crypt:
    file: ./secrets/pcloud_crypt

services:
  pcloud:
    secrets:
      - pcloud_password
      - pcloud_totp_secret
      - pcloud_crypt
```

Only list the secrets you use — Compose refuses to start when a listed file is
missing. The entrypoint picks up `/run/secrets/pcloud_password`,
`/run/secrets/pcloud_totp_secret` and `/run/secrets/pcloud_crypt` on its own;
the `*_FILE` variables are only needed for other paths. The shipped
`docker-compose.yml` contains this block commented out, and `.gitignore`
keeps `secrets/` and `.env` out of git. With Docker Swarm, declare the same
names as `external: true` secrets instead.

Order of precedence per secret: `*_FILE` → `/run/secrets/<name>` → plain
environment variable. The plain variables keep working for compatibility, but
the entrypoint logs a notice for each one it finds.

Whichever source is used, the entrypoint keeps the values to itself: they are
no longer exported, so neither the long-running `pcloudcc` daemon nor any
helper it starts carries them in its `/proc/<pid>/environ`. The one exception
is the automatic first-time login, where `pcloudcc` receives the account
password through `PCLOUD_ACCOUNT_PASSWORD`; that process is replaced by a
clean daemon as soon as the login has succeeded.

`pcloud_password` and `pcloud_totp_secret` are only needed until
`/root/.pcloud/data.db` exists — remove them afterwards. `pcloud_crypt` is
read on every start to unlock the Crypto Folder.

### Interactive login and `stdin_open`/`tty`

The compose file enables `stdin_open: true` and `tty: true` so you can attach to the container during first-time login. **Remove both options once credentials are saved** to `/root/.pcloud/data.db` to reduce the interactive attack surface. If you use the unattended login flow (`PCLOUD_PASSWORD` + `PCLOUD_TOTP_SECRET`), `stdin_open`/`tty` are not needed at all.

### Supply chain

The image compiles `lneely/pcloudcc-lneely`, a fork maintained by a single
person. Its code runs as root next to your pCloud credentials, so new upstream
code is never published as `latest` without review:

- The `Dockerfile` pins the upstream commit (`ARG PCLOUDCC_REF=<sha>`). Every
  release build — pushes, tags and the weekly rebuild — compiles exactly that
  commit.
- `check-upstream.yml` polls upstream every 6 hours. For a new commit on
  `main` it opens (or updates) a pull request that moves the pin, with a link
  to the upstream diff. **Merging that PR is what releases the new code.**
- At the same time it dispatches an `edge` build of the new commit (and of new
  upstream tags), so it is compiled, scanned and smoke-tested right away and
  can be tried as `:edge` before the PR is merged.
- The Debian base image is pinned by digest as well; Dependabot proposes
  updates as pull requests. The weekly rebuild runs without the layer cache, so
  `apt-get install` picks up current package versions on top of that base.

Two repository settings matter for the pin PRs: *Settings → Actions → General
→ Allow GitHub Actions to create and approve pull requests* must be enabled.
PRs opened with the default `GITHUB_TOKEN` do not trigger CI on their own; add
a fine-grained token with *contents* and *pull requests* write access as the
`UPSTREAM_BUMP_TOKEN` secret to have CI run on them automatically. Without it,
the edge build of the same commit is the check to look at.

Every published image is:

- Scanned with Trivy — CRITICAL/HIGH CVEs with an available fix block the build; the full scan results (all severities, including findings without an available fix) are uploaded to the GitHub Security tab
- Signed with cosign keyless signing (verifiable via `cosign verify`)
- Shipped with an SBOM and provenance attestation

Release and development images are separated by tag namespace and carry a
`pcloudcc.build.channel` label — see [Image tags](#image-tags). Only release
builds write to the shared registry build cache, so a branch build cannot push
its layers into the cache that default-branch builds restore from.

The exact upstream commit compiled into an image is recorded inside it:

```bash
docker run --rm --entrypoint cat ghcr.io/dev-ferris/pcloudcc-docker-image:latest \
  /usr/local/share/pcloudcc/upstream-commit
```

When building yourself, the pinned commit is used unless you override
`PCLOUDCC_REF` (see [Updating](#updating)).

## Updating

With the pre-built image:

```bash
docker compose pull
docker compose up -d
```

When building from source, `git pull` brings in the latest pinned upstream
commit; a changed `PCLOUDCC_REF` invalidates the build cache on its own:

```bash
git pull
docker compose build
docker compose up -d
```

To build a different upstream commit or tag, override the pin in
`docker-compose.yml`. A commit SHA or tag is preferable to a branch name: with
a branch, the build cache keeps reusing the old binary until you build with
`--no-cache`.

```yaml
build:
  context: .
  # dockerfile: Dockerfile.alpine    # build the Alpine variant instead
  args:
    PCLOUDCC_REF: 20260707T123504Z   # upstream tag or commit SHA
```

## Development

The entrypoint and healthcheck have a test suite that runs without Docker, with
stubs in place of `pcloudcc` and the mount tools:

```bash
sh tests/run.sh                  # TEST_VERBOSE=1 shows the entrypoint output
```

CI runs it with both image shells (dash for Debian, BusyBox ash for Alpine),
together with hadolint, actionlint and shellcheck. When you change
`PCLOUDCC_REF` by hand, change it in both `Dockerfile` and `Dockerfile.alpine`;
CI fails if they differ.

## Troubleshooting

**Container logs show `status is OFFLINE`:**
This usually means the SSL fingerprint check failed or credentials are wrong. If pCloud rotated its certificates, a newer upstream commit is needed: try the `edge` image, or build with `PCLOUDCC_REF` set to the latest upstream commit (see [Updating](#updating)).

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
