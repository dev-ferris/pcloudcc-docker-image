#!/bin/sh
set -eu

# shellcheck source=common.sh
. "${PCLOUDCC_LIB:-/usr/local/lib/pcloudcc/common.sh}"

# ============================================================================
# Defaults
# ============================================================================
: "${PCLOUD_USER:=}"
: "${PCLOUD_PASSWORD:=}"
: "${PCLOUD_PASSWORD_FILE:=}"
: "${PCLOUD_2FA:=}"
: "${PCLOUD_TOTP_SECRET:=}"
: "${PCLOUD_TOTP_SECRET_FILE:=}"
: "${PCLOUD_CRYPT:=}"
: "${PCLOUD_CRYPT_FILE:=}"
: "${PCLOUD_MOUNT:=/pcloud}"
: "${MOUNT_TIMEOUT:=60}"
# Passed to pcloudcc only when set; empty keeps pcloudcc's own defaults.
: "${PCLOUD_CACHE_SIZE:=}"
: "${PCLOUD_LOG_LEVEL:=}"
: "${PCLOUD_FUSE_OPTS:=}"
# Deprecated: ENABLE_BINDFS=1 is translated by apply_bindfs_compat().
: "${ENABLE_BINDFS:=0}"
: "${BINDFS_TARGET:=/pcloud}"
: "${UID:=1000}"
: "${GID:=1000}"

PCLOUD_PID=""

# ============================================================================
# Process / mount helpers
# ============================================================================

# fusermount3 is the upstream libfuse name; Debian also ships `fusermount`.
# Fall back to umount (we run as root with CAP_SYS_ADMIN).
FUSERMOUNT=""
resolve_fusermount() {
  [ -z "${FUSERMOUNT}" ] || return 0
  for _cmd in fusermount3 fusermount; do
    if command -v "${_cmd}" >/dev/null 2>&1; then
      FUSERMOUNT="${_cmd}"
      return 0
    fi
  done
  FUSERMOUNT="umount"
}

# Unmounts $1, falling back to a lazy unmount when it is busy, and warns if
# the mount is still there afterwards. No-op when nothing is mounted.
fuse_unmount() {
  _mnt="$1"
  mountpoint -q "${_mnt}" 2>/dev/null || return 0
  resolve_fusermount
  if [ "${FUSERMOUNT}" = "umount" ]; then
    umount "${_mnt}" 2>/dev/null || umount -l "${_mnt}" 2>/dev/null || true
  else
    "${FUSERMOUNT}" -u "${_mnt}" 2>/dev/null \
      || "${FUSERMOUNT}" -u -z "${_mnt}" 2>/dev/null \
      || true
  fi
  if mountpoint -q "${_mnt}" 2>/dev/null; then
    echo "WARNING: could not unmount '${_mnt}' - it may be left stale on the host" >&2
  fi
}

# Waits up to $2 seconds for pid $1 to exit. Returns 0 if it did, 1 on timeout.
wait_for_exit() {
  _pid="$1"
  _secs="$2"
  while [ "${_secs}" -gt 0 ]; do
    kill -0 "${_pid}" 2>/dev/null || return 0
    _secs=$((_secs - 1))
    sleep 1
  done
  ! kill -0 "${_pid}" 2>/dev/null
}

wait_for_mount() {
  echo "[$2] Waiting for mount at $1 (timeout: ${MOUNT_TIMEOUT}s)..."
  _elapsed=0
  until mount_ready "$1"; do
    _elapsed=$((_elapsed + 2))
    if [ "${_elapsed}" -ge "${MOUNT_TIMEOUT}" ]; then
      echo "ERROR: [$2] Mount at $1 did not become ready within ${MOUNT_TIMEOUT}s" >&2
      return 1
    fi
    sleep 2
  done
  echo "[$2] Mount ready."
}

# ============================================================================
# Validation
# ============================================================================

die() {
  echo "ERROR: $*" >&2
  exit 1
}

validate_inputs() {
  [ -n "${PCLOUD_USER}" ] || die "PCLOUD_USER is required"

  case "${UID}" in ''|*[!0-9]*) die "UID must be numeric, got '${UID}'" ;; esac
  case "${GID}" in ''|*[!0-9]*) die "GID must be numeric, got '${GID}'" ;; esac
  case "${MOUNT_TIMEOUT}" in
    ''|*[!0-9]*) die "MOUNT_TIMEOUT must be numeric (seconds), got '${MOUNT_TIMEOUT}'" ;;
  esac

  # pcloudcc rejects values outside 1..1024 only after it has started.
  case "${PCLOUD_CACHE_SIZE}" in
    '') ;;
    *[!0-9]*) die "PCLOUD_CACHE_SIZE must be numeric (GB), got '${PCLOUD_CACHE_SIZE}'" ;;
    *)
      if [ "${PCLOUD_CACHE_SIZE}" -lt 1 ] || [ "${PCLOUD_CACHE_SIZE}" -gt 1024 ]; then
        die "PCLOUD_CACHE_SIZE must be between 1 and 1024 (GB), got '${PCLOUD_CACHE_SIZE}'"
      fi ;;
  esac
  case "${PCLOUD_LOG_LEVEL}" in
    ''|NONE|ERROR|WARNING|INFO|NOTICE|DEBUG) ;;
    *) die "PCLOUD_LOG_LEVEL must be one of NONE, ERROR, WARNING, INFO, NOTICE, DEBUG; got '${PCLOUD_LOG_LEVEL}'" ;;
  esac
  # One argv element, so nothing to inject into; restricting the characters
  # keeps a stray space from being misread as a separate argument.
  case "${PCLOUD_FUSE_OPTS}" in
    *[!a-zA-Z0-9_,=./-]*) die "PCLOUD_FUSE_OPTS contains invalid characters, got '${PCLOUD_FUSE_OPTS}'" ;;
  esac

  validate_mount_path PCLOUD_MOUNT "${PCLOUD_MOUNT}" || exit 1
  if [ "${ENABLE_BINDFS}" = "1" ]; then
    validate_mount_path BINDFS_TARGET "${BINDFS_TARGET}" || exit 1
  fi

  # USER/GROUP only fed the removed `chown -R` of the mount point.
  if [ -n "${GROUP:-}" ]; then
    echo "NOTICE: GROUP (and USER) are no longer used and can be removed;" >&2
    echo "        set ownership with PCLOUD_FUSE_OPTS=uid=...,gid=... instead." >&2
  fi
}

# ============================================================================
# Secrets
# ============================================================================

# Reads a secret into <value_var>. Source, highest priority first:
#   1. the file named by <file_var> (e.g. PCLOUD_PASSWORD_FILE)
#   2. ${PCLOUD_SECRETS_DIR}/<secret_name>, if it exists (Compose/Swarm secret)
#   3. the plain environment variable <value_var>
# Aborts when a file is configured but unreadable.
load_secret_file() {
  _value_var="$1"
  _file_var="$2"
  _default_file="${PCLOUD_SECRETS_DIR}/$3"
  eval "_file=\${${_file_var}}"
  eval "_env_value=\${${_value_var}}"

  # Environment variables stay visible in `docker inspect` and in PID 1's
  # environment for the container's lifetime, whatever this script unsets.
  if [ -n "${_env_value}" ]; then
    echo "NOTICE: ${_value_var} is set as an environment variable and stays readable via" >&2
    echo "        'docker inspect'. Prefer a secret file: ${_default_file} or ${_file_var}." >&2
  fi
  unset _env_value

  if [ -z "${_file}" ] && [ -e "${_default_file}" ]; then
    _file="${_default_file}"
  fi
  [ -n "${_file}" ] || return 0
  [ -r "${_file}" ] || die "secret file '${_file}' for ${_value_var} is not readable"
  eval "${_value_var}=\$(cat \"\${_file}\")"
}

# Secrets from the environment arrive exported, so every child process would
# inherit them in /proc/<pid>/environ. Re-create them as unexported shell
# variables: this script keeps the values, children no longer see them.
unexport_secrets() {
  for _var in PCLOUD_PASSWORD PCLOUD_TOTP_SECRET PCLOUD_CRYPT PCLOUD_2FA; do
    eval "_val=\${${_var}}"
    unset "${_var}"
    eval "${_var}=\${_val}"
  done
  unset _var _val
}

load_secrets() {
  load_secret_file PCLOUD_CRYPT       PCLOUD_CRYPT_FILE       pcloud_crypt
  load_secret_file PCLOUD_PASSWORD    PCLOUD_PASSWORD_FILE    pcloud_password
  load_secret_file PCLOUD_TOTP_SECRET PCLOUD_TOTP_SECRET_FILE pcloud_totp_secret
  unexport_secrets

  # Base32 is paste-friendly with spaces; oathtool is not.
  if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
    PCLOUD_TOTP_SECRET="$(printf '%s' "${PCLOUD_TOTP_SECRET}" | tr -d '[:space:]')"
  fi
}

log_provided_secrets() {
  [ -n "${PCLOUD_2FA}" ]          && echo "2FA code: provided"
  [ -n "${PCLOUD_TOTP_SECRET}" ]  && echo "TOTP secret: provided (codes generated automatically)"
  [ -n "${PCLOUD_PASSWORD}" ]     && echo "Account password: provided"
  return 0
}

# Prints a 6-digit 2FA code: generated from PCLOUD_TOTP_SECRET, or PCLOUD_2FA
# as given. Prints nothing when neither is set. Returns 1 only on failure.
compute_tfa_code() {
  _code=""
  if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
    if ! command -v oathtool >/dev/null 2>&1; then
      echo "ERROR: PCLOUD_TOTP_SECRET set but 'oathtool' is not installed" >&2
      return 1
    fi
    # Via stdin so the secret never shows up in /proc/<pid>/cmdline.
    if ! _code="$(printf '%s' "${PCLOUD_TOTP_SECRET}" | oathtool --totp -b - 2>/dev/null)"; then
      echo "ERROR: failed to generate TOTP code (invalid base32 secret?)" >&2
      return 1
    fi
  elif [ -n "${PCLOUD_2FA}" ]; then
    _code="${PCLOUD_2FA}"
  fi
  printf '%s' "${_code}"
}

# ============================================================================
# Mount configuration
# ============================================================================

# Deprecated ENABLE_BINDFS=1: bindfs used to re-export the mount at
# BINDFS_TARGET with ownership rewritten to UID:GID. The same result now comes
# from pcloudcc's own mount: mount at BINDFS_TARGET and add
# uid=,gid=,allow_other,default_permissions. Options already present in
# PCLOUD_FUSE_OPTS win per key.
apply_bindfs_compat() {
  [ "${ENABLE_BINDFS}" = "1" ] || return 0

  PCLOUD_MOUNT="${BINDFS_TARGET}"
  fuse_opt_present uid                 || fuse_opt_append "uid=${UID}"
  fuse_opt_present gid                 || fuse_opt_append "gid=${GID}"
  fuse_opt_present allow_other         || fuse_opt_append "allow_other"
  fuse_opt_present default_permissions || fuse_opt_append "default_permissions"

  echo "NOTICE: ENABLE_BINDFS=1 is deprecated - bindfs is no longer part of this image." >&2
  echo "        Mounting pcloudcc at BINDFS_TARGET ('${BINDFS_TARGET}') with" >&2
  echo "        --fuse-opts '${PCLOUD_FUSE_OPTS}' instead." >&2
  echo "        Set PCLOUD_MOUNT and PCLOUD_FUSE_OPTS directly to silence this." >&2
}

# allow_other lets every uid reach the mount; only default_permissions makes
# the kernel enforce the reported ownership and modes. pcloudcc does no access
# checks itself (no `access` handler; its permission checks are per pCloud
# account, not per local user), so allow_other alone gives every local account
# on the host full read/write on the whole pCloud account.
warn_unenforced_mount() {
  fuse_opt_present allow_other || return 0
  fuse_opt_present default_permissions && return 0

  echo "WARNING: PCLOUD_FUSE_OPTS enables 'allow_other' without 'default_permissions'." >&2
  echo "         pcloudcc performs no access checks of its own, so every uid that can" >&2
  echo "         reach '${PCLOUD_MOUNT}' gets full read/write access to your pCloud" >&2
  echo "         account, including the unlocked Crypto Folder. Add" >&2
  echo "         'default_permissions' unless that is what you want." >&2
}

# /pcloud_internal was the default mount point while bindfs existed. A host
# bind mount still pointing there would stay empty without any error.
warn_legacy_mount_point() {
  _legacy="/pcloud_internal"
  [ "${PCLOUD_MOUNT}" != "${_legacy}" ] || return 0
  mountpoint -q "${_legacy}" 2>/dev/null || return 0

  echo "WARNING: something is still mounted at '${_legacy}', but pcloudcc mounts at" >&2
  echo "         '${PCLOUD_MOUNT}'. If that is your host bind mount, repoint it at" >&2
  echo "         '${PCLOUD_MOUNT}' or set PCLOUD_MOUNT=${_legacy}." >&2
}

# Ownership of the directory itself does not matter: the FUSE mount hides it
# and reports its own (see PCLOUD_FUSE_OPTS uid=/gid=). It only has to exist.
prepare_mount_point() {
  if ! mkdir -p "${PCLOUD_MOUNT}" 2>/dev/null; then
    echo "ERROR: Cannot create mount point '${PCLOUD_MOUNT}'." >&2
    echo "       With read_only: true it must be bind-mounted or listed under tmpfs." >&2
    exit 1
  fi
}

# ============================================================================
# pcloudcc lifecycle
# ============================================================================

# Starts pcloudcc in the background with the common flags plus "$@" and
# records its PID. stdin is /dev/null on purpose: with a non-TTY stdin,
# pcloudcc reads one line from it as a control command instead of starting,
# and an open pipe without data (stdin_open without tty) would block forever.
spawn_pcloudcc() {
  set -- -u "${PCLOUD_USER}" -m "${PCLOUD_MOUNT}" "$@"
  [ -z "${PCLOUD_CACHE_SIZE}" ] || set -- "$@" --cache-size "${PCLOUD_CACHE_SIZE}"
  [ -z "${PCLOUD_LOG_LEVEL}" ]  || set -- "$@" --log-level  "${PCLOUD_LOG_LEVEL}"
  [ -z "${PCLOUD_FUSE_OPTS}" ]  || set -- "$@" --fuse-opts  "${PCLOUD_FUSE_OPTS}"
  pcloudcc "$@" < /dev/null &
  PCLOUD_PID=$!
}

start_pcloudcc() {
  echo "Starting pCloud command client"
  spawn_pcloudcc
}

# Stops pcloudcc (TERM, KILL after 10s) and tears down its FUSE mount.
stop_pcloudcc() {
  [ -n "${PCLOUD_PID}" ] || return 0
  if kill -0 "${PCLOUD_PID}" 2>/dev/null; then
    kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
    wait_for_exit "${PCLOUD_PID}" 10 || kill -KILL "${PCLOUD_PID}" 2>/dev/null || true
  fi
  wait "${PCLOUD_PID}" 2>/dev/null || true
  fuse_unmount "${PCLOUD_MOUNT}"
  PCLOUD_PID=""
}

cleanup() {
  trap - TERM INT EXIT
  echo "Shutting down..."
  if [ -n "${PCLOUD_PID}" ] && kill -0 "${PCLOUD_PID}" 2>/dev/null; then
    echo "Stopping pcloudcc gracefully..."
  fi
  stop_pcloudcc
}

# Logs in once with -s (saves credentials to data.db), then restarts pcloudcc
# as a normal daemon: the -s instance does not reliably answer IPC commands
# such as `crypto start`.
first_time_login() {
  if [ -z "${PCLOUD_PASSWORD}" ]; then
    echo "No saved credentials found. Either provide the account password as the"
    echo "pcloud_password secret (and pcloud_totp_secret if 2FA is enabled) for"
    echo "automatic login, or run the following inside the container:"
    echo "  docker exec -it <container> pcloudcc -u ${PCLOUD_USER} -m ${PCLOUD_MOUNT} -p -s"
    if [ -n "${PCLOUD_2FA}" ]; then
      echo "  (2FA is enabled — append '-t <code>' with a fresh code from your authenticator app;"
      echo "   codes expire every ~30s, so don't reuse PCLOUD_2FA here.)"
    fi
    echo "After 'status is READY' appears, press Ctrl+C and restart the container."
    exec sleep infinity
  fi

  echo "No saved credentials found — performing automatic first-time login."
  _tfa_code="$(compute_tfa_code)" || exit 1

  # Without -p, pcloudcc reads the password from PCLOUD_ACCOUNT_PASSWORD.
  # Exported for this one process only and removed again right after.
  echo "Starting pCloud command client (first-time login mode)"
  export PCLOUD_ACCOUNT_PASSWORD="${PCLOUD_PASSWORD}"
  if [ -n "${_tfa_code}" ]; then
    spawn_pcloudcc -s -t "${_tfa_code}"
  else
    spawn_pcloudcc -s
  fi
  unset PCLOUD_ACCOUNT_PASSWORD PCLOUD_PASSWORD _tfa_code

  # data.db appears early in the login; the populated mount is the first
  # reliable sign that login actually succeeded.
  _elapsed=0
  until [ -f "${PCLOUD_DATA_DB}" ]; do
    if ! kill -0 "${PCLOUD_PID}" 2>/dev/null; then
      die "pcloudcc exited during first-time login — check credentials/2FA"
    fi
    _elapsed=$((_elapsed + 2))
    if [ "${_elapsed}" -ge "${MOUNT_TIMEOUT}" ]; then
      kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
      die "first-time login did not complete within ${MOUNT_TIMEOUT}s"
    fi
    sleep 2
  done
  echo "First-time login: credentials saved to ${PCLOUD_DATA_DB}"

  if ! wait_for_mount "${PCLOUD_MOUNT}" "first-login"; then
    kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
    die "first-time login completed but pcloud mount did not become ready"
  fi
  echo "First-time login: pCloud mount ready — login fully successful."

  echo "Restarting pcloudcc in normal mode after first-time login..."
  stop_pcloudcc
  start_pcloudcc
}

# A failed unlock (e.g. wrong password) is logged but keeps pcloudcc running.
unlock_crypto() {
  [ -n "${PCLOUD_CRYPT}" ] || return 0

  echo "Crypto password: provided"
  if ! wait_for_mount "${PCLOUD_MOUNT}" "pcloud"; then
    echo "WARNING: skipping crypto unlock — pcloud mount did not become ready." >&2
    unset PCLOUD_CRYPT
    return 0
  fi

  # `pcloudcc -k` always exits 0, so check the resulting state instead.
  _crypto_log=$(mktemp)
  printf 'crypto start %s\n' "$(prompt_quote "${PCLOUD_CRYPT}")" \
    | pcloudcc -u "${PCLOUD_USER}" -k > "${_crypto_log}" 2>&1 || true
  unset PCLOUD_CRYPT

  # The folder can take a moment to become readable after the RPC returns.
  _waited=0
  _unlocked=0
  while [ "${_waited}" -lt 10 ]; do
    if crypto_unlocked "${PCLOUD_MOUNT}"; then
      _unlocked=1
      break
    fi
    _waited=$((_waited + 1))
    sleep 1
  done

  if [ "${_unlocked}" = "1" ]; then
    echo "Crypto folder unlocked."
  else
    echo "WARNING: crypto folder is still locked after 'crypto start' (wrong password?). pcloudcc keeps running." >&2
    sed 's/^/  pcloudcc: /' "${_crypto_log}" >&2 || true
  fi
  rm -f "${_crypto_log}"
  unset _crypto_log _waited _unlocked
}

# ============================================================================
# Main
# ============================================================================

validate_inputs
apply_bindfs_compat
warn_unenforced_mount
warn_legacy_mount_point
load_secrets
prepare_mount_point
log_provided_secrets

# Set only after validation, so an early error is not followed by a
# misleading "Shutting down...".
trap cleanup TERM INT EXIT

if [ ! -f "${PCLOUD_DATA_DB}" ]; then
  first_time_login
else
  start_pcloudcc
fi

unlock_crypto

# The secrets are not exported (see unexport_secrets); this just tidies up.
unset PCLOUD_2FA PCLOUD_TOTP_SECRET PCLOUD_PASSWORD

wait "${PCLOUD_PID}"
