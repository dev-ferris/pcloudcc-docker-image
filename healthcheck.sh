#!/bin/sh
# Container healthcheck for pcloudcc.
#
# Exit codes:
#   0 = healthy (or bootstrap phase: still waiting for first-time login)
#   1 = unhealthy
set -u

: "${PCLOUD_MOUNT:=/pcloud_internal}"
: "${ENABLE_BINDFS:=0}"
: "${BINDFS_TARGET:=/pcloud}"
: "${PCLOUD_CRYPT:=}"
: "${PCLOUD_CRYPT_FILE:=}"

# Bootstrap: no saved credentials yet. The entrypoint either waits for a
# manual first-time login (sleep infinity) or is currently performing one.
# Either way, report healthy so Docker does not kill the container before
# the user can finish setup.
[ -f /root/.pcloud/data.db ] || exit 0

# Determine the user-facing mount: bindfs overlay if enabled, otherwise
# the raw pcloudcc mount.
if [ "${ENABLE_BINDFS}" = "1" ]; then
  mnt="${BINDFS_TARGET}"
else
  mnt="${PCLOUD_MOUNT}"
fi

# The pCloud filesystem must be mounted and populated. An empty directory
# means pcloudcc has not (yet) finished mounting.
mountpoint -q "${mnt}" || exit 1
[ -n "$(ls -A "${mnt}" 2>/dev/null)" ] || exit 1

# When a crypto password is configured (either inline or via secrets file),
# the "Crypto Folder" must be unlocked: pcloudcc only exposes its contents
# after a successful `crypto start`. A locked or failed unlock leaves the
# folder either missing or empty, which we treat as unhealthy so the
# container is restarted instead of silently serving a locked vault.
if [ -n "${PCLOUD_CRYPT}" ] || [ -n "${PCLOUD_CRYPT_FILE}" ]; then
  crypto_dir="${mnt}/Crypto Folder"
  [ -d "${crypto_dir}" ] || exit 1
  [ -n "$(ls -A "${crypto_dir}" 2>/dev/null)" ] || exit 1
fi

exit 0
