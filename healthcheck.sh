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
# the "Crypto Folder" must be unlocked. The folder itself always exists in
# the pcloud mount — even when locked — so a plain `[ -d ]` test is
# insufficient. Access to its contents, however, is denied by pcloudcc's
# FUSE layer until `crypto start` succeeds, producing errors like:
#
#   ls: fts_read: Permission denied
#
# We exercise that path with `ls -al` (which forces stat on `.`/`..` and
# triggers the FUSE permission check) and rely on its non-zero exit code
# to flag a locked or failed-unlock state. LC_ALL=C keeps the message
# locale-independent for the belt-and-suspenders grep fallback.
if [ -n "${PCLOUD_CRYPT}" ] || [ -n "${PCLOUD_CRYPT_FILE}" ]; then
  crypto_dir="${mnt}/Crypto Folder"
  [ -d "${crypto_dir}" ] || exit 1
  crypto_out=$(LC_ALL=C ls -al "${crypto_dir}" 2>&1)
  crypto_rc=$?
  [ "${crypto_rc}" -eq 0 ] || exit 1
  case "${crypto_out}" in
    *"Permission denied"*) exit 1 ;;
  esac
fi

exit 0
