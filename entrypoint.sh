#!/bin/sh
set -eu

# --- Defaults ---
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
case "${USER}" in
  ''|*[!a-zA-Z0-9._-]*) echo "ERROR: USER contains invalid characters, got '${USER}'" >&2; exit 1 ;;
esac
case "${GROUP}" in
  ''|*[!a-zA-Z0-9._-]*) echo "ERROR: GROUP contains invalid characters, got '${GROUP}'" >&2; exit 1 ;;
esac

# Guard against typos that would make the recursive chown below disastrous.
# Both mount paths must be absolute and must not be the root filesystem or a
# well-known system directory.
validate_mount_path() {
  _name="$1"
  _path="$2"
  case "${_path}" in
    ""|"/")
      echo "ERROR: ${_name}='${_path}' must not be empty or '/'" >&2; exit 1 ;;
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      echo "ERROR: ${_name}='${_path}' is a top-level system directory; refusing to chown -R there" >&2; exit 1 ;;
    /*)
      case "${_path}" in
        *..*) echo "ERROR: ${_name}='${_path}' must not contain '..'" >&2; exit 1 ;;
      esac
      ;;
    *)
      echo "ERROR: ${_name}='${_path}' must be an absolute path" >&2; exit 1 ;;
  esac
}
validate_mount_path PCLOUD_MOUNT "${PCLOUD_MOUNT}"
if [ "${ENABLE_BINDFS}" = "1" ]; then
  validate_mount_path BINDFS_TARGET "${BINDFS_TARGET}"
  if [ "${BINDFS_TARGET}" = "${PCLOUD_MOUNT}" ]; then
    echo "ERROR: BINDFS_TARGET must differ from PCLOUD_MOUNT" >&2; exit 1
  fi
fi

# --- Helpers ---
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

# --- Load secrets from files (e.g. Docker secrets at /run/secrets/) ---
if [ -n "${PCLOUD_CRYPT_FILE}" ]; then
  if [ ! -r "${PCLOUD_CRYPT_FILE}" ]; then
    echo "ERROR: PCLOUD_CRYPT_FILE '${PCLOUD_CRYPT_FILE}' is not readable" >&2
    exit 1
  fi
  PCLOUD_CRYPT="$(cat "${PCLOUD_CRYPT_FILE}")"
fi
if [ -n "${PCLOUD_PASSWORD_FILE}" ]; then
  if [ ! -r "${PCLOUD_PASSWORD_FILE}" ]; then
    echo "ERROR: PCLOUD_PASSWORD_FILE '${PCLOUD_PASSWORD_FILE}' is not readable" >&2
    exit 1
  fi
  PCLOUD_PASSWORD="$(cat "${PCLOUD_PASSWORD_FILE}")"
fi
if [ -n "${PCLOUD_TOTP_SECRET_FILE}" ]; then
  if [ ! -r "${PCLOUD_TOTP_SECRET_FILE}" ]; then
    echo "ERROR: PCLOUD_TOTP_SECRET_FILE '${PCLOUD_TOTP_SECRET_FILE}' is not readable" >&2
    exit 1
  fi
  PCLOUD_TOTP_SECRET="$(cat "${PCLOUD_TOTP_SECRET_FILE}")"
fi
# Strip any whitespace from the TOTP base32 secret (paste-friendly).
if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
  PCLOUD_TOTP_SECRET="$(printf '%s' "${PCLOUD_TOTP_SECRET}" | tr -d '[:space:]')"
fi

# --- Setup ---
# With read_only: true the container FS is immutable; /pcloud_internal must be
# listed under tmpfs (or pre-created in the image) so mkdir/chown can succeed.
if ! mkdir -p "${PCLOUD_MOUNT}" 2>/dev/null; then
  echo "ERROR: Cannot create mount point '${PCLOUD_MOUNT}'." >&2
  echo "       When using read_only: true, add '${PCLOUD_MOUNT}' to the tmpfs list in docker-compose.yml." >&2
  exit 1
fi
if chown -R "${USER}:${GROUP}" "${PCLOUD_MOUNT}" 2>/dev/null; then
  echo "Setting owner rights (${USER}:${GROUP}) on ${PCLOUD_MOUNT}"
else
  echo "WARNING: Could not set ownership on '${PCLOUD_MOUNT}' (read-only filesystem?)." >&2
  echo "         Add '${PCLOUD_MOUNT}' to the tmpfs list in docker-compose.yml." >&2
fi

[ -n "${PCLOUD_2FA}" ] && echo "2FA code: provided"
[ -n "${PCLOUD_TOTP_SECRET}" ] && echo "TOTP secret: provided (codes generated automatically)"
[ -n "${PCLOUD_PASSWORD}" ] && echo "Account password: provided"

# --- Compute a fresh TOTP code from PCLOUD_TOTP_SECRET if available ---
# Prints the resulting 6-digit code on stdout; returns 0 on success (including
# the no-2FA case, where stdout is empty) and 1 on hard failure (oathtool
# missing or secret invalid). The caller captures the code via $(...).
compute_tfa_code() {
  _code=""
  if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
    if ! command -v oathtool >/dev/null 2>&1; then
      echo "ERROR: PCLOUD_TOTP_SECRET set but 'oathtool' is not installed" >&2
      return 1
    fi
    if ! _code="$(oathtool --totp -b "${PCLOUD_TOTP_SECRET}" 2>/dev/null)"; then
      echo "ERROR: failed to generate TOTP code (invalid base32 secret?)" >&2
      return 1
    fi
  elif [ -n "${PCLOUD_2FA}" ]; then
    _code="${PCLOUD_2FA}"
  fi
  printf '%s' "${_code}"
  return 0
}

# --- First-time login ---
if [ ! -f /root/.pcloud/data.db ]; then
  if [ -n "${PCLOUD_PASSWORD}" ]; then
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

    # Wait for data.db to be created (proof that login succeeded).
    _elapsed=0
    until [ -f /root/.pcloud/data.db ]; do
      if ! kill -0 "${PCLOUD_PID}" 2>/dev/null; then
        echo "ERROR: pcloudcc exited during first-time login — check credentials/2FA" >&2
        exit 1
      fi
      _elapsed=$((_elapsed + 2))
      if [ "${_elapsed}" -ge "${MOUNT_TIMEOUT}" ]; then
        echo "ERROR: first-time login did not complete within ${MOUNT_TIMEOUT}s" >&2
        kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
        exit 1
      fi
      sleep 2
    done
    echo "First-time login: credentials saved to /root/.pcloud/data.db"
  else
    echo "No saved credentials found. Either set PCLOUD_PASSWORD (and"
    echo "PCLOUD_TOTP_SECRET or PCLOUD_2FA if 2FA is enabled) for automatic login,"
    echo "or run the following inside the container:"
    echo "  docker exec -it <container> pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s"
    if [ -n "${PCLOUD_2FA}" ]; then
      echo "  (2FA is enabled — append '-t <code>' with a fresh code from your authenticator app;"
      echo "   codes expire every ~30s, so don't reuse PCLOUD_2FA here.)"
    fi
    echo "After 'status is READY' appears, press Ctrl+C and restart the container."
    exec sleep infinity
  fi
else
  # --- Start pcloudcc daemon ---
  echo "Starting pCloud command client"
  pcloudcc -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" &
  PCLOUD_PID=$!
fi

# --- Optional crypto unlock ---
# A failed unlock (e.g. wrong password) must not abort the entrypoint and take
# the pcloudcc daemon down with it — log the failure and keep going.
if [ -n "${PCLOUD_CRYPT}" ]; then
  echo "Crypto password: provided"
  if wait_for_mount "${PCLOUD_MOUNT}" "pcloud"; then
    _crypto_log=$(mktemp)
    if printf 'crypto start %s\n' "${PCLOUD_CRYPT}" \
         | pcloudcc -u "${PCLOUD_USER}" -k > "${_crypto_log}" 2>&1; then
      echo "Crypto folder unlock requested."
    else
      echo "WARNING: crypto unlock command failed (wrong password?). pcloudcc keeps running." >&2
      sed 's/^/  pcloudcc: /' "${_crypto_log}" >&2 || true
    fi
    rm -f "${_crypto_log}"
    unset _crypto_log
  else
    echo "WARNING: skipping crypto unlock — pcloud mount did not become ready." >&2
  fi
  unset PCLOUD_CRYPT
fi

# Clear 2FA code and TOTP secret from environment after startup
unset PCLOUD_2FA PCLOUD_TOTP_SECRET PCLOUD_PASSWORD 2>/dev/null || true

# --- Optional bindfs overlay ---
if [ "${ENABLE_BINDFS}" = "1" ]; then
  (
    wait_for_mount "${PCLOUD_MOUNT}" "bindfs"
    echo "[bindfs] Mounting ${PCLOUD_MOUNT} -> ${BINDFS_TARGET} (uid=${UID}, gid=${GID})"
    exec bindfs -f -u "${UID}" -g "${GID}" "${PCLOUD_MOUNT}" "${BINDFS_TARGET}"
  ) &
  BINDFS_PID=$!
fi

wait "${PCLOUD_PID}"
