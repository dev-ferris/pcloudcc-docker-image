#!/bin/sh
# Container healthcheck for pcloudcc.
#
# Exit codes:
#   0 = healthy (or bootstrap phase: still waiting for first-time login)
#   1 = unhealthy
set -u

# shellcheck source=common.sh
. "${PCLOUDCC_LIB:-/usr/local/lib/pcloudcc/common.sh}"

# No saved credentials yet: the entrypoint is waiting for or performing the
# first-time login. Report healthy so Docker does not kill the container
# before setup can finish.
[ -f "${PCLOUD_DATA_DB}" ] || exit 0

mnt="$(effective_mount)"

# A stale FUSE mount (ENOTCONN) looks like a missing directory to everything on
# the host, so name it explicitly: it is visible in `docker inspect` under
# State.Health and tells the operator what to clear.
if mount_is_stale "${mnt}"; then
  echo "stale FUSE mount at ${mnt} - Transport endpoint is not connected"
  exit 1
fi

# The pCloud filesystem must be mounted and populated.
mount_ready "${mnt}" || exit 1

# With a crypto password configured, the Crypto Folder must be unlocked.
if crypto_configured; then
  crypto_unlocked "${mnt}" || exit 1
fi

exit 0
