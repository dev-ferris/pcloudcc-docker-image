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
: "${MOUNT_TIMEOUT:=120}"
: "${SHARED_DIR:=/pcloud-shared}"

# --- Validation ---
if [ -z "${PCLOUD_USER}" ]; then
  echo "ERROR: PCLOUD_USER is required" >&2
  exit 1
fi

case "${UID}" in
  ''|*[!0-9]*) echo "ERROR: UID must be numeric, got '${UID}'" >&2; exit 1 ;;
esac
case "${GID}" in
  ''|*[!0-9]*) echo "ERROR: GID must be numeric, got '${GID}'" >&2; exit 1 ;;
esac

# --- Helpers ---

# Check if the shared directory is available (mounted as a volume).
shared_available() {
  [ -d "${SHARED_DIR}" ] && [ -w "${SHARED_DIR}" ]
}

# Write the status file atomically. No-op if shared dir is unavailable.
write_status() {
  shared_available || return 0
  printf '{"state":"%s","pid":%d,"mounted":%s,"started_at":"%s"}\n' \
    "$1" "${2:-0}" "${3:-false}" "${4:-}" \
    > "${SHARED_DIR}/status.json.tmp"
  mv "${SHARED_DIR}/status.json.tmp" "${SHARED_DIR}/status.json"
}

wait_for_mount() {
  echo "[$2] Waiting for mount at $1 (timeout: ${MOUNT_TIMEOUT}s)..."
  _elapsed=0
  until mountpoint -q "$1" && [ -n "$(ls -A "$1" 2>/dev/null)" ]; do
    _elapsed=$((_elapsed + 2))
    if [ "${_elapsed}" -ge "${MOUNT_TIMEOUT}" ]; then
      echo "ERROR: [$2] Mount at $1 did not become ready within ${MOUNT_TIMEOUT}s" >&2
      return 1
    fi
    sleep 2
  done
  echo "[$2] Mount ready."
}

cleanup() {
  trap - TERM INT EXIT
  echo "Shutting down..."

  # Signal stopped to webui sidecar.
  write_status "stopped"

  if [ -n "${STATUS_LOOP_PID:-}" ]; then
    kill "${STATUS_LOOP_PID}" 2>/dev/null || true
  fi
  if [ -n "${LOG_TAIL_PID:-}" ]; then
    kill "${LOG_TAIL_PID}" 2>/dev/null || true
  fi

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
  echo "No saved credentials found."

  if shared_available; then
    write_status "setup_required"
    echo "Waiting for login via webui (${SHARED_DIR}) or CLI..."
    echo "  CLI: docker exec -it <container> pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s${PCLOUD_2FA:+ -t ${PCLOUD_2FA}}"

    # Poll for login request from webui sidecar.
    while [ ! -f /root/.pcloud/data.db ]; do
      if [ -f "${SHARED_DIR}/login-trigger" ]; then
        echo "[webui] Login request received."

        # Read credentials from shared volume.
        _email=""
        _pass_file=""
        _tfa_flag=""

        if [ -f "${SHARED_DIR}/login-email" ]; then
          _email=$(cat "${SHARED_DIR}/login-email")
        fi
        _pass_file="${SHARED_DIR}/login-pass"

        if [ -f "${SHARED_DIR}/login-2fa" ]; then
          _tfa_code=$(cat "${SHARED_DIR}/login-2fa")
          if [ -n "${_tfa_code}" ]; then
            _tfa_flag="-t ${_tfa_code}"
          fi
        fi

        # Clean up trigger immediately to prevent re-execution.
        rm -f "${SHARED_DIR}/login-trigger"

        # Attempt login. pcloudcc -p reads password from stdin.
        _login_ok="no"
        if [ -n "${_email}" ] && [ -f "${_pass_file}" ]; then
          echo "[webui] Attempting pcloudcc login for ${_email}..."
          # shellcheck disable=SC2086
          if pcloudcc -u "${_email}" -m "${PCLOUD_MOUNT}" -p -s ${_tfa_flag} \
               < "${_pass_file}" > "${SHARED_DIR}/login-output.log" 2>&1; then
            _login_ok="yes"
          fi

          # Check if data.db was actually created (the real success indicator).
          if [ -f /root/.pcloud/data.db ]; then
            _login_ok="yes"
          fi
        else
          echo "[webui] ERROR: Missing email or password file." >&2
        fi

        # Shred credential files.
        rm -f "${SHARED_DIR}/login-pass" "${SHARED_DIR}/login-email" \
              "${SHARED_DIR}/login-2fa"

        # Write result for the sidecar to pick up.
        if [ "${_login_ok}" = "yes" ]; then
          echo "[webui] Login successful."
          printf 'ok' > "${SHARED_DIR}/login-result"
          break
        else
          _err="Login failed."
          if [ -f "${SHARED_DIR}/login-output.log" ]; then
            _err=$(cat "${SHARED_DIR}/login-output.log")
          fi
          echo "[webui] Login failed: ${_err}" >&2
          printf '%s' "${_err}" > "${SHARED_DIR}/login-result"
          rm -f "${SHARED_DIR}/login-output.log"
        fi
      fi
      sleep 2
    done
  else
    # No shared dir available — fall back to original CLI-only flow.
    echo "Run the following inside the container:"
    echo "  pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s${PCLOUD_2FA:+ -t ${PCLOUD_2FA}}"
    exec sleep infinity
  fi

  # If we get here without data.db, something went wrong.
  if [ ! -f /root/.pcloud/data.db ]; then
    echo "ERROR: Login completed but data.db not found." >&2
    exit 1
  fi
fi

# --- Start pcloudcc daemon ---
_start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Starting pCloud command client"

if shared_available; then
  # Redirect pcloudcc output to log file for the webui sidecar,
  # and also tee to stdout so `docker logs` still works.
  pcloudcc -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" \
    > "${SHARED_DIR}/pcloudcc.log" 2>&1 &
  PCLOUD_PID=$!

  # Tail the log file to stdout so `docker logs` still works.
  tail -f "${SHARED_DIR}/pcloudcc.log" 2>/dev/null &
  LOG_TAIL_PID=$!

  # Background status writer — updates status.json every 5 seconds.
  (
    while kill -0 "${PCLOUD_PID}" 2>/dev/null; do
      _mounted="false"
      mountpoint -q "${PCLOUD_MOUNT}" 2>/dev/null && _mounted="true"
      write_status "running" "${PCLOUD_PID}" "${_mounted}" "${_start_time}"
      sleep 5
    done
    write_status "stopped"
  ) &
  STATUS_LOOP_PID=$!
else
  pcloudcc -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" &
  PCLOUD_PID=$!
fi

# --- Optional crypto unlock ---
if [ -n "${PCLOUD_CRYPT}" ]; then
  echo "Crypto password: provided"
  wait_for_mount "${PCLOUD_MOUNT}" "pcloud"

  printf 'crypto start %s\n' "${PCLOUD_CRYPT}" | pcloudcc -u "${PCLOUD_USER}" -k > /dev/null 2>&1
  unset PCLOUD_CRYPT

  echo "Crypto folder unlock requested."
fi

# Clear 2FA code from environment after startup
unset PCLOUD_2FA 2>/dev/null || true

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
