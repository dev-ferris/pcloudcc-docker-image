#!/bin/sh
set -eu

# --- Defaults ---
: "${PCLOUD_USER:=}"
: "${PCLOUD_2FA:=}"
: "${PCLOUD_CRYPT:=}"
: "${PCLOUD_MOUNT:=/pcloud_internal}"
: "${USER:=nobody}"
: "${GROUP:=users}"
: "${ENABLE_BINDFS:=0}"
: "${BINDFS_TARGET:=/pcloud}"
: "${UID:=1000}"
: "${GID:=1000}"

# --- Validation ---
if [ -z "${PCLOUD_USER}" ]; then
  echo "ERROR: PCLOUD_USER is required" >&2
  exit 1
fi

# --- Helpers ---
wait_for_mount() {
  echo "[$2] Waiting for mount at $1..."
  until mountpoint -q "$1" && [ -n "$(ls -A "$1" 2>/dev/null)" ]; do
    sleep 2
  done
  echo "[$2] Mount ready."
}

cleanup() {
  trap - TERM INT EXIT
  echo "Shutting down..."

  if [ -n "${BINDFS_PID:-}" ]; then
    kill "${BINDFS_PID}" 2>/dev/null || true
  fi
  if [ "${ENABLE_BINDFS}" = "1" ] && mountpoint -q "${BINDFS_TARGET}" 2>/dev/null; then
    fusermount -u "${BINDFS_TARGET}" 2>/dev/null || true
  fi

  # Graceful pcloudcc shutdown - give it time to finish pending transfers
  if [ -n "${PCLOUD_PID:-}" ] && kill -0 "${PCLOUD_PID}" 2>/dev/null; then
    echo "Stopping pcloudcc gracefully..."
    kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
    # Wait up to 10 seconds for clean exit
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "${PCLOUD_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${PCLOUD_PID}" 2>/dev/null || true
  fi
}
trap cleanup TERM INT EXIT

# --- Setup ---
mkdir -p "${PCLOUD_MOUNT}"
echo "Setting owner rights (${USER}:${GROUP} to ${PCLOUD_MOUNT})"
chown -R "${USER}:${GROUP}" "${PCLOUD_MOUNT}"

[ -n "${PCLOUD_2FA}" ] && echo "2FA code: provided"

# --- First-time login ---
if [ ! -f /root/.pcloud/data.db ]; then
  echo "No saved credentials found. Run the following inside the container:"
  echo "  pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s${PCLOUD_2FA:+ -t ${PCLOUD_2FA}}"
  exec sleep infinity
fi

# --- Start pcloudcc daemon ---
echo "Starting pCloud command client"
pcloudcc -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" &
PCLOUD_PID=$!

# --- Optional crypto unlock ---
if [ -n "${PCLOUD_CRYPT}" ]; then
  echo "Crypto password: provided"
  wait_for_mount "${PCLOUD_MOUNT}" "pcloud"

  printf 'crypto start %s\n' "${PCLOUD_CRYPT}" | pcloudcc -u "${PCLOUD_USER}" -k > /dev/null 2>&1

  echo "Crypto folder unlock requested."
fi

# --- Optional bindfs overlay ---
if [ "${ENABLE_BINDFS}" = "1" ]; then
  (
    wait_for_mount "${PCLOUD_MOUNT}" "bindfs"
    echo "[bindfs] Mounting ${PCLOUD_MOUNT} -> ${BINDFS_TARGET} (uid=${UID}, gid=${GID})"
    bindfs -f -u "${UID}" -g "${GID}" "${PCLOUD_MOUNT}" "${BINDFS_TARGET}"
  ) &
  BINDFS_PID=$!
fi

wait "${PCLOUD_PID}"
