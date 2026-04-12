#!/bin/sh
set -eu

# =============================================================================
# pcloudcc Docker Entrypoint
#
# Two operational modes (auto-detected):
#   Console-only:  No shared volume → CLI login prompt, plain daemon
#   WebUI-enabled: /pcloud-shared mounted → file-based IPC with sidecar
#
# The mode is determined by whether SHARED_DIR exists and is writable.
# All webui-specific code is isolated in clearly named functions.
# =============================================================================

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

# PIDs tracked for cleanup.
PCLOUD_PID=""
STATUS_LOOP_PID=""
LOG_TAIL_PID=""
BINDFS_PID=""

# =============================================================================
# Validation
# =============================================================================

validate_env() {
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
}

# =============================================================================
# Helpers
# =============================================================================

# Check if the shared directory is available (mounted as a volume).
shared_available() {
  [ -d "${SHARED_DIR}" ] && [ -w "${SHARED_DIR}" ]
}

# Write the status file atomically. No-op if shared dir is unavailable.
# Usage: write_status <state> [pid] [mounted] [started_at] [crypto_unlocked]
write_status() {
  shared_available || return 0
  printf '{"state":"%s","pid":%d,"mounted":%s,"started_at":"%s","crypto_unlocked":%s}\n' \
    "$1" "${2:-0}" "${3:-false}" "${4:-}" "${5:-false}" \
    > "${SHARED_DIR}/status.json.tmp"
  mv "${SHARED_DIR}/status.json.tmp" "${SHARED_DIR}/status.json"
}

# Wait for a FUSE mount to become ready.
# Usage: wait_for_mount <path> <label>
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

# =============================================================================
# Cleanup (signal handler)
# =============================================================================

cleanup() {
  trap - TERM INT EXIT
  echo "Shutting down..."

  # Signal stopped to webui sidecar.
  write_status "stopped"

  if [ -n "${STATUS_LOOP_PID}" ]; then
    kill "${STATUS_LOOP_PID}" 2>/dev/null || true
  fi
  if [ -n "${LOG_TAIL_PID}" ]; then
    kill "${LOG_TAIL_PID}" 2>/dev/null || true
  fi
  if [ -n "${BINDFS_PID}" ]; then
    kill "${BINDFS_PID}" 2>/dev/null || true
  fi
  if [ "${ENABLE_BINDFS}" = "1" ] && mountpoint -q "${BINDFS_TARGET}" 2>/dev/null; then
    fusermount -u "${BINDFS_TARGET}" 2>/dev/null || true
  fi

  # Graceful pcloudcc shutdown — give it time to finish pending transfers.
  if [ -n "${PCLOUD_PID}" ] && kill -0 "${PCLOUD_PID}" 2>/dev/null; then
    echo "Stopping pcloudcc gracefully..."
    kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "${PCLOUD_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${PCLOUD_PID}" 2>/dev/null || true
  fi
}

# =============================================================================
# First-time login: WebUI mode
# =============================================================================

# Poll for login credentials written by the webui sidecar.
# Blocks until data.db is created or a login attempt fails.
login_via_webui() {
  write_status "setup_required"
  echo "Waiting for login via webui (${SHARED_DIR}) or CLI..."
  echo "  CLI: docker exec -it <container> pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s${PCLOUD_2FA:+ -t ${PCLOUD_2FA}}"

  while [ ! -f /root/.pcloud/data.db ]; do
    if [ -f "${SHARED_DIR}/login-trigger" ]; then
      echo "[webui] Login request received."
      _handle_login_request
    fi
    sleep 2
  done
}

# Process a single login request from the webui sidecar.
_handle_login_request() {
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
  else
    _err="Login failed."
    if [ -f "${SHARED_DIR}/login-output.log" ]; then
      _err=$(cat "${SHARED_DIR}/login-output.log")
    fi
    echo "[webui] Login failed: ${_err}" >&2
    printf '%s' "${_err}" > "${SHARED_DIR}/login-result"
    rm -f "${SHARED_DIR}/login-output.log"
  fi
}

# =============================================================================
# First-time login: Console-only mode
# =============================================================================

# Print CLI instructions and block forever. The user must exec into the
# container to run pcloudcc manually.
login_via_cli() {
  echo "Run the following inside the container:"
  echo "  pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s${PCLOUD_2FA:+ -t ${PCLOUD_2FA}}"
  exec sleep infinity
}

# =============================================================================
# Daemon start
# =============================================================================

# Start pcloudcc with log redirect and status writer (webui mode).
start_daemon_webui() {
  pcloudcc -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" \
    > "${SHARED_DIR}/pcloudcc.log" 2>&1 &
  PCLOUD_PID=$!

  # Tail log to stdout so `docker logs` still works.
  tail -f "${SHARED_DIR}/pcloudcc.log" 2>/dev/null &
  LOG_TAIL_PID=$!

  # Start background status writer + crypto watcher.
  start_status_loop &
  STATUS_LOOP_PID=$!
}

# Start pcloudcc in plain console mode.
start_daemon_console() {
  pcloudcc -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" &
  PCLOUD_PID=$!
}

# =============================================================================
# Background status writer + crypto watcher (webui mode)
# =============================================================================

# Runs in a subshell. Updates status.json every 5 seconds and watches
# for crypto unlock requests from the webui sidecar.
# Crypto state is tracked via a marker file (.crypto-unlocked) so that
# both env-var unlocks (parent shell) and webui unlocks (this subshell)
# are visible.
start_status_loop() {
  while kill -0 "${PCLOUD_PID}" 2>/dev/null; do
    _mounted="false"
    mountpoint -q "${PCLOUD_MOUNT}" 2>/dev/null && _mounted="true"
    _crypto="false"
    [ -f "${SHARED_DIR}/.crypto-unlocked" ] && _crypto="true"
    write_status "running" "${PCLOUD_PID}" "${_mounted}" "${_start_time}" "${_crypto}"

    # Check for crypto unlock request from webui sidecar.
    if [ -f "${SHARED_DIR}/crypto-trigger" ]; then
      _handle_crypto_request
    fi

    sleep 5
  done
  write_status "stopped" "0" "false" "${_start_time}" "false"
}

# Process a single crypto unlock request from the webui sidecar.
_handle_crypto_request() {
  echo "[webui] Crypto unlock request received."
  rm -f "${SHARED_DIR}/crypto-trigger"

  if [ -f "${SHARED_DIR}/crypto-pass" ]; then
    _cpass=$(cat "${SHARED_DIR}/crypto-pass")
    rm -f "${SHARED_DIR}/crypto-pass"

    if printf 'crypto start %s\n' "${_cpass}" \
         | pcloudcc -u "${PCLOUD_USER}" -k > /dev/null 2>&1; then
      touch "${SHARED_DIR}/.crypto-unlocked"
      echo "[webui] Crypto folder unlocked."
      printf 'ok' > "${SHARED_DIR}/crypto-result"
    else
      echo "[webui] Crypto unlock failed." >&2
      printf 'Crypto unlock failed. Check your password.' > "${SHARED_DIR}/crypto-result"
    fi
    unset _cpass
  else
    echo "[webui] ERROR: Missing crypto-pass file." >&2
    printf 'Missing crypto password.' > "${SHARED_DIR}/crypto-result"
  fi
}

# =============================================================================
# Crypto unlock via environment variable
# =============================================================================

unlock_crypto_env() {
  [ -z "${PCLOUD_CRYPT}" ] && return 0

  echo "Crypto password: provided (via environment variable)"
  wait_for_mount "${PCLOUD_MOUNT}" "pcloud"

  if printf 'crypto start %s\n' "${PCLOUD_CRYPT}" \
       | pcloudcc -u "${PCLOUD_USER}" -k > /dev/null 2>&1; then
    # Signal crypto state to the status writer subshell via marker file.
    shared_available && touch "${SHARED_DIR}/.crypto-unlocked"
  fi
  unset PCLOUD_CRYPT

  echo "Crypto folder unlock requested."
}

# =============================================================================
# Optional bindfs overlay
# =============================================================================

start_bindfs() {
  [ "${ENABLE_BINDFS}" != "1" ] && return 0

  (
    wait_for_mount "${PCLOUD_MOUNT}" "bindfs"
    echo "[bindfs] Mounting ${PCLOUD_MOUNT} -> ${BINDFS_TARGET} (uid=${UID}, gid=${GID})"
    bindfs -f -u "${UID}" -g "${GID}" "${PCLOUD_MOUNT}" "${BINDFS_TARGET}"
  ) &
  BINDFS_PID=$!
}

# =============================================================================
# Main
# =============================================================================

main() {
  validate_env
  trap cleanup TERM INT EXIT

  # Prepare mount point.
  mkdir -p "${PCLOUD_MOUNT}"
  echo "Setting owner rights (${USER}:${GROUP} to ${PCLOUD_MOUNT})"
  chown -R "${USER}:${GROUP}" "${PCLOUD_MOUNT}"

  [ -n "${PCLOUD_2FA}" ] && echo "2FA code: provided"

  # --- First-time login (if no saved credentials) ---
  if [ ! -f /root/.pcloud/data.db ]; then
    echo "No saved credentials found."

    if shared_available; then
      login_via_webui
    else
      login_via_cli
      # login_via_cli calls exec, so we never reach here.
    fi

    # Safety check.
    if [ ! -f /root/.pcloud/data.db ]; then
      echo "ERROR: Login completed but data.db not found." >&2
      exit 1
    fi
  fi

  # --- Start pcloudcc daemon ---
  _start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "Starting pCloud command client"

  if shared_available; then
    start_daemon_webui
  else
    start_daemon_console
  fi

  # --- Post-start tasks ---
  unlock_crypto_env

  # Clear 2FA code from environment after startup.
  unset PCLOUD_2FA 2>/dev/null || true

  start_bindfs

  # Block until pcloudcc exits.
  wait "${PCLOUD_PID}"
}

main "$@"
