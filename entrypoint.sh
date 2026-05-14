#!/bin/sh
# Bootstraps pcloudcc inside the container.
#
# Lifecycle (see main() at the bottom):
#   1. validate environment / mount paths
#   2. load secrets from *_FILE variables (Docker secrets compatible)
#   3. prepare the mount point
#   4. start pcloudcc (saved credentials, automatic first-time login, or
#      pause for a manual interactive login via `docker exec`)
#   5. unlock the crypto folder if configured
#   6. spawn the bindfs overlay if enabled
#   7. wait for pcloudcc; clean up child processes on signal

set -eu

# =============================================================================
# Configuration & defaults
# =============================================================================

: "${PCLOUD_USER:=}"
: "${PCLOUD_PASSWORD:=}"
: "${PCLOUD_PASSWORD_FILE:=}"
: "${PCLOUD_2FA:=}"
: "${PCLOUD_TOTP_SECRET:=}"
: "${PCLOUD_TOTP_SECRET_FILE:=}"
: "${PCLOUD_CRYPT:=}"
: "${PCLOUD_CRYPT_FILE:=}"
: "${PCLOUD_MOUNT:=/pcloud_internal}"
: "${USER:=nobody}"
: "${GROUP:=users}"
: "${ENABLE_BINDFS:=0}"
: "${BINDFS_TARGET:=/pcloud}"
: "${UID:=1000}"
: "${GID:=1000}"
: "${MOUNT_TIMEOUT:=60}"

DATA_DB=/root/.pcloud/data.db

# Backgrounded child PIDs. Populated by start_daemon / first_time_login /
# start_bindfs, consumed by cleanup() on signal.
PCLOUD_PID=""
BINDFS_PID=""

# =============================================================================
# Logging helpers
# =============================================================================

warn() { echo "WARNING: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

# =============================================================================
# Validation
# =============================================================================

# Guard against typos that would make the recursive chown below disastrous.
# Both mount paths must be absolute and must not be the root filesystem or a
# well-known system directory.
validate_mount_path() {
  _name="$1"
  _path="$2"
  case "${_path}" in
    ""|"/")
      die "${_name}='${_path}' must not be empty or '/'" ;;
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "${_name}='${_path}' is a top-level system directory; refusing to chown -R there" ;;
    /*)
      case "${_path}" in
        *..*) die "${_name}='${_path}' must not contain '..'" ;;
      esac
      ;;
    *)
      die "${_name}='${_path}' must be an absolute path" ;;
  esac
}

validate_env() {
  [ -n "${PCLOUD_USER}" ] || die "PCLOUD_USER is required"

  case "${UID}" in
    ''|*[!0-9]*) die "UID must be numeric, got '${UID}'" ;;
  esac
  case "${GID}" in
    ''|*[!0-9]*) die "GID must be numeric, got '${GID}'" ;;
  esac
  case "${USER}" in
    ''|*[!a-zA-Z0-9._-]*) die "USER contains invalid characters, got '${USER}'" ;;
  esac
  case "${GROUP}" in
    ''|*[!a-zA-Z0-9._-]*) die "GROUP contains invalid characters, got '${GROUP}'" ;;
  esac

  validate_mount_path PCLOUD_MOUNT "${PCLOUD_MOUNT}"
  if [ "${ENABLE_BINDFS}" = "1" ]; then
    validate_mount_path BINDFS_TARGET "${BINDFS_TARGET}"
    [ "${BINDFS_TARGET}" != "${PCLOUD_MOUNT}" ] \
      || die "BINDFS_TARGET must differ from PCLOUD_MOUNT"
  fi
}

# =============================================================================
# Secrets & authentication
# =============================================================================

# Read a secret from a file (e.g. Docker secrets at /run/secrets/).
# Prints the file contents on stdout; returns 1 if the file is unreadable.
# Callers capture via $(read_secret_file ...).
read_secret_file() {
  _file="$1"
  _name="$2"
  [ -r "${_file}" ] || { err "${_name} '${_file}' is not readable"; return 1; }
  cat "${_file}"
}

load_secrets() {
  if [ -n "${PCLOUD_CRYPT_FILE}" ]; then
    PCLOUD_CRYPT=$(read_secret_file "${PCLOUD_CRYPT_FILE}" PCLOUD_CRYPT_FILE) || exit 1
  fi
  if [ -n "${PCLOUD_PASSWORD_FILE}" ]; then
    PCLOUD_PASSWORD=$(read_secret_file "${PCLOUD_PASSWORD_FILE}" PCLOUD_PASSWORD_FILE) || exit 1
  fi
  if [ -n "${PCLOUD_TOTP_SECRET_FILE}" ]; then
    PCLOUD_TOTP_SECRET=$(read_secret_file "${PCLOUD_TOTP_SECRET_FILE}" PCLOUD_TOTP_SECRET_FILE) || exit 1
  fi
  # Strip whitespace from the TOTP base32 secret (paste-friendly).
  if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
    PCLOUD_TOTP_SECRET=$(printf '%s' "${PCLOUD_TOTP_SECRET}" | tr -d '[:space:]')
  fi
}

# Prints a fresh 6-digit TOTP code on stdout (computed from PCLOUD_TOTP_SECRET
# via oathtool, or echoed from PCLOUD_2FA as a single-shot fallback). Returns 0
# on success — including the no-2FA case, where stdout is empty — and 1 only on
# hard failure (oathtool missing or secret invalid). Caller captures via $(...).
compute_tfa_code() {
  _code=""
  if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
    command -v oathtool >/dev/null 2>&1 \
      || { err "PCLOUD_TOTP_SECRET set but 'oathtool' is not installed"; return 1; }
    if ! _code="$(oathtool --totp -b "${PCLOUD_TOTP_SECRET}" 2>/dev/null)"; then
      err "failed to generate TOTP code (invalid base32 secret?)"
      return 1
    fi
  elif [ -n "${PCLOUD_2FA}" ]; then
    _code="${PCLOUD_2FA}"
  fi
  printf '%s' "${_code}"
  return 0
}

# =============================================================================
# Mount / process helpers
# =============================================================================

wait_for_mount() {
  _path="$1"
  _tag="$2"
  echo "[${_tag}] Waiting for mount at ${_path} (timeout: ${MOUNT_TIMEOUT}s)..."
  _elapsed=0
  until mountpoint -q "${_path}" && [ -n "$(ls -A "${_path}" 2>/dev/null)" ]; do
    _elapsed=$((_elapsed + 2))
    if [ "${_elapsed}" -ge "${MOUNT_TIMEOUT}" ]; then
      err "[${_tag}] Mount at ${_path} did not become ready within ${MOUNT_TIMEOUT}s"
      return 1
    fi
    sleep 2
  done
  echo "[${_tag}] Mount ready."
}

cleanup() {
  trap - TERM INT EXIT
  echo "Shutting down..."

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
# Mount-point setup
# =============================================================================

setup_mount_point() {
  # With read_only: true the container FS is immutable; PCLOUD_MOUNT must be
  # listed under tmpfs (or pre-created in the image) so mkdir/chown can succeed.
  if ! mkdir -p "${PCLOUD_MOUNT}" 2>/dev/null; then
    err "Cannot create mount point '${PCLOUD_MOUNT}'."
    echo "       When using read_only: true, add '${PCLOUD_MOUNT}' to the tmpfs list in docker-compose.yml." >&2
    exit 1
  fi
  if chown -R "${USER}:${GROUP}" "${PCLOUD_MOUNT}" 2>/dev/null; then
    echo "Setting owner rights (${USER}:${GROUP}) on ${PCLOUD_MOUNT}"
  else
    warn "Could not set ownership on '${PCLOUD_MOUNT}' (read-only filesystem?)."
    echo "         Add '${PCLOUD_MOUNT}' to the tmpfs list in docker-compose.yml." >&2
  fi
}

announce_credentials() {
  [ -n "${PCLOUD_2FA}" ]         && echo "2FA code: provided"
  [ -n "${PCLOUD_TOTP_SECRET}" ] && echo "TOTP secret: provided (codes generated automatically)"
  [ -n "${PCLOUD_PASSWORD}" ]    && echo "Account password: provided"
  return 0
}

# =============================================================================
# Daemon / first-time login
# =============================================================================

has_saved_credentials() {
  [ -f "${DATA_DB}" ]
}

can_auto_login() {
  [ -n "${PCLOUD_PASSWORD}" ]
}

print_manual_login_instructions() {
  echo "No saved credentials found. Either set PCLOUD_PASSWORD (and"
  echo "PCLOUD_TOTP_SECRET or PCLOUD_2FA if 2FA is enabled) for automatic login,"
  echo "or run the following inside the container:"
  echo "  docker exec -it <container> pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s"
  if [ -n "${PCLOUD_2FA}" ]; then
    echo "  (2FA is enabled — append '-t <code>' with a fresh code from your authenticator app;"
    echo "   codes expire every ~30s, so don't reuse PCLOUD_2FA here.)"
  fi
  echo "After 'status is READY' appears, press Ctrl+C and restart the container."
}

# Polls for the credentials database while the background pcloudcc process is
# still alive. Relies on PCLOUD_PID set by first_time_login().
wait_for_login() {
  _elapsed=0
  until [ -f "${DATA_DB}" ]; do
    if ! kill -0 "${PCLOUD_PID}" 2>/dev/null; then
      err "pcloudcc exited during first-time login — check credentials/2FA"
      return 1
    fi
    _elapsed=$((_elapsed + 2))
    if [ "${_elapsed}" -ge "${MOUNT_TIMEOUT}" ]; then
      err "first-time login did not complete within ${MOUNT_TIMEOUT}s"
      kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
      return 1
    fi
    sleep 2
  done
}

start_daemon() {
  echo "Starting pCloud command client"
  pcloudcc -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" &
  PCLOUD_PID=$!
}

first_time_login() {
  echo "No saved credentials found — performing automatic first-time login."
  _tfa_code="$(compute_tfa_code)" || exit 1

  # pcloudcc reads the account password from PCLOUD_ACCOUNT_PASSWORD when
  # the interactive -p flag is not set. -s saves credentials to data.db.
  set -- -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" -s
  if [ -n "${_tfa_code}" ]; then
    set -- "$@" -t "${_tfa_code}"
  fi

  echo "Starting pCloud command client (first-time login mode)"
  PCLOUD_ACCOUNT_PASSWORD="${PCLOUD_PASSWORD}" pcloudcc "$@" &
  PCLOUD_PID=$!

  # Wipe the password from the environment as soon as pcloudcc has it.
  unset PCLOUD_PASSWORD _tfa_code

  wait_for_login || exit 1
  echo "First-time login: credentials saved to ${DATA_DB}"
}

# Picks the appropriate startup path: existing credentials DB, automatic
# first-time login, or pause-and-wait for a manual interactive login.
start_pcloudcc() {
  if has_saved_credentials; then
    start_daemon
  elif can_auto_login; then
    first_time_login
  else
    print_manual_login_instructions
    exec sleep infinity
  fi
}

# =============================================================================
# Optional features
# =============================================================================

# A failed crypto unlock (e.g. wrong password) must not abort the entrypoint
# and take the pcloudcc daemon down with it — log the failure and keep going.
unlock_crypto() {
  [ -n "${PCLOUD_CRYPT}" ] || return 0

  echo "Crypto password: provided"
  if ! wait_for_mount "${PCLOUD_MOUNT}" "pcloud"; then
    warn "skipping crypto unlock — pcloud mount did not become ready."
    unset PCLOUD_CRYPT
    return 0
  fi

  _crypto_log=$(mktemp)
  if printf 'crypto start %s\n' "${PCLOUD_CRYPT}" \
       | pcloudcc -u "${PCLOUD_USER}" -k > "${_crypto_log}" 2>&1; then
    echo "Crypto folder unlock requested."
  else
    warn "crypto unlock command failed (wrong password?). pcloudcc keeps running."
    sed 's/^/  pcloudcc: /' "${_crypto_log}" >&2 || true
  fi
  rm -f "${_crypto_log}"
  unset PCLOUD_CRYPT _crypto_log
}

start_bindfs() {
  [ "${ENABLE_BINDFS}" = "1" ] || return 0
  (
    wait_for_mount "${PCLOUD_MOUNT}" "bindfs"
    echo "[bindfs] Mounting ${PCLOUD_MOUNT} -> ${BINDFS_TARGET} (uid=${UID}, gid=${GID})"
    exec bindfs -f -u "${UID}" -g "${GID}" "${PCLOUD_MOUNT}" "${BINDFS_TARGET}"
  ) &
  BINDFS_PID=$!
}

# Clear sensitive data from the environment after startup is complete.
# pcloudcc already has what it needs; anything still set here would leak
# into child processes (e.g. bindfs) and into `docker inspect` output.
clear_sensitive_env() {
  unset PCLOUD_2FA PCLOUD_TOTP_SECRET PCLOUD_PASSWORD 2>/dev/null || true
}

# =============================================================================
# Main
# =============================================================================

main() {
  validate_env
  load_secrets
  setup_mount_point
  announce_credentials

  trap cleanup TERM INT EXIT

  start_pcloudcc
  unlock_crypto
  clear_sensitive_env
  start_bindfs

  wait "${PCLOUD_PID}"
}

main "$@"
