#!/bin/sh
set -eu

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
: "${PCLOUD_MOUNT:=/pcloud_internal}"
: "${USER:=nobody}"
: "${GROUP:=users}"
: "${ENABLE_BINDFS:=0}"
: "${BINDFS_TARGET:=/pcloud}"
: "${UID:=1000}"
: "${GID:=1000}"
: "${MOUNT_TIMEOUT:=60}"
# Optional pass-through for upstream options added in 2026 (lneely#396 onwards).
# All three default to empty, which means "do not pass the flag at all", so the
# defaults baked into pcloudcc itself stay in force.
: "${PCLOUD_CACHE_SIZE:=}"
: "${PCLOUD_LOG_LEVEL:=}"
: "${PCLOUD_FUSE_OPTS:=}"

PCLOUD_PID=""

# ============================================================================
# Filesystem / process helpers
# ============================================================================

# Upstream libfuse installs the helper as `fusermount3`; Debian's fuse3 package
# additionally ships it under the fuse 2.x name `fusermount` (which is why it
# conflicts with the old fuse package). Both names work on this base image, but
# only the versioned one is guaranteed elsewhere, so resolve whichever exists
# once and fall back to `umount` (we run as root with CAP_SYS_ADMIN).
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

# Unmount a FUSE mount point, retrying lazily when the mount is still busy and
# warning when even that fails — the previous inline `fusermount -u ... || true`
# gave up on a busy mount without a trace, leaving it stale on the host.
# No-op when nothing is mounted there.
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

# Non-empty directory test that stops at the first entry instead of reading and
# formatting the whole listing the way `ls -A` does. A minor saving, but this
# runs on the startup poll loop and (via healthcheck.sh) every 60s against a
# mount that pcloudcc services itself. findutils is Essential in Debian, so
# `find` is as guaranteed to be present as `ls`.
dir_not_empty() {
  [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

# Wait up to $2 seconds for pid $1 to exit. Returns 0 if it did, 1 on timeout.
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

# ============================================================================
# Validation helpers
# ============================================================================

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

validate_inputs() {
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
  case "${MOUNT_TIMEOUT}" in
    ''|*[!0-9]*) echo "ERROR: MOUNT_TIMEOUT must be numeric (seconds), got '${MOUNT_TIMEOUT}'" >&2; exit 1 ;;
  esac
  case "${USER}" in
    ''|*[!a-zA-Z0-9._-]*) echo "ERROR: USER contains invalid characters, got '${USER}'" >&2; exit 1 ;;
  esac
  case "${GROUP}" in
    ''|*[!a-zA-Z0-9._-]*) echo "ERROR: GROUP contains invalid characters, got '${GROUP}'" >&2; exit 1 ;;
  esac

  # pcloudcc itself rejects anything outside 1..1024, but it does so after the
  # daemon has already been spawned, so catch it here where the error is
  # attributable to the variable that caused it.
  case "${PCLOUD_CACHE_SIZE}" in
    '') ;;
    *[!0-9]*)
      echo "ERROR: PCLOUD_CACHE_SIZE must be numeric (GB), got '${PCLOUD_CACHE_SIZE}'" >&2; exit 1 ;;
    *)
      if [ "${PCLOUD_CACHE_SIZE}" -lt 1 ] || [ "${PCLOUD_CACHE_SIZE}" -gt 1024 ]; then
        echo "ERROR: PCLOUD_CACHE_SIZE must be between 1 and 1024 (GB), got '${PCLOUD_CACHE_SIZE}'" >&2; exit 1
      fi ;;
  esac
  case "${PCLOUD_LOG_LEVEL}" in
    ''|NONE|ERROR|WARNING|INFO|NOTICE|DEBUG) ;;
    *)
      echo "ERROR: PCLOUD_LOG_LEVEL must be one of NONE, ERROR, WARNING, INFO, NOTICE, DEBUG; got '${PCLOUD_LOG_LEVEL}'" >&2; exit 1 ;;
  esac
  # A single argv element, so there is no shell to inject into — but a stray
  # space would silently split it into two arguments and pcloudcc would take
  # the tail as a positional. Keep it to the character set FUSE options use.
  case "${PCLOUD_FUSE_OPTS}" in
    '') ;;
    *[!a-zA-Z0-9_,=./-]*)
      echo "ERROR: PCLOUD_FUSE_OPTS contains invalid characters, got '${PCLOUD_FUSE_OPTS}'" >&2; exit 1 ;;
  esac

  validate_mount_path PCLOUD_MOUNT "${PCLOUD_MOUNT}"
  # Checked before apply_bindfs_compat() promotes it to PCLOUD_MOUNT. The two
  # are no longer required to differ: with bindfs gone there is no second layer
  # to stack on top, so BINDFS_TARGET *becomes* the pcloudcc mount point.
  if [ "${ENABLE_BINDFS}" = "1" ]; then
    validate_mount_path BINDFS_TARGET "${BINDFS_TARGET}"
  fi
}

# ============================================================================
# Secret loading
# ============================================================================

# Reads the file referenced by <file_var> and stores its contents in <value_var>.
# No-op when <file_var> is empty. Aborts when the file is unreadable.
load_secret_file() {
  _value_var="$1"
  _file_var="$2"
  eval "_file=\${${_file_var}}"
  [ -n "${_file}" ] || return 0
  if [ ! -r "${_file}" ]; then
    echo "ERROR: ${_file_var} '${_file}' is not readable" >&2
    exit 1
  fi
  eval "${_value_var}=\$(cat \"\${_file}\")"
}

load_secrets() {
  load_secret_file PCLOUD_CRYPT       PCLOUD_CRYPT_FILE
  load_secret_file PCLOUD_PASSWORD    PCLOUD_PASSWORD_FILE
  load_secret_file PCLOUD_TOTP_SECRET PCLOUD_TOTP_SECRET_FILE

  # Strip any whitespace from the TOTP base32 secret (paste-friendly).
  if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
    PCLOUD_TOTP_SECRET="$(printf '%s' "${PCLOUD_TOTP_SECRET}" | tr -d '[:space:]')"
  fi
}

# Prints a fresh 6-digit TOTP code on stdout (computed from PCLOUD_TOTP_SECRET
# via oathtool, or echoed from PCLOUD_2FA as a single-shot fallback). Returns 0
# on success — including the no-2FA case, where stdout is empty — and 1 only on
# hard failure (oathtool missing or secret invalid). Caller captures via $(...).
compute_tfa_code() {
  _code=""
  if [ -n "${PCLOUD_TOTP_SECRET}" ]; then
    if ! command -v oathtool >/dev/null 2>&1; then
      echo "ERROR: PCLOUD_TOTP_SECRET set but 'oathtool' is not installed" >&2
      return 1
    fi
    # Pass the secret via stdin so it never appears in /proc/<pid>/cmdline.
    if ! _code="$(printf '%s' "${PCLOUD_TOTP_SECRET}" | oathtool --totp -b - 2>/dev/null)"; then
      echo "ERROR: failed to generate TOTP code (invalid base32 secret?)" >&2
      return 1
    fi
  elif [ -n "${PCLOUD_2FA}" ]; then
    _code="${PCLOUD_2FA}"
  fi
  printf '%s' "${_code}"
  return 0
}

# ============================================================================
# pcloudcc lifecycle
# ============================================================================

# Spawns pcloudcc in the background with the mandatory flags plus whatever is
# passed to this function, and records its PID in PCLOUD_PID.
#
# stdin is redirected from /dev/null on purpose. When stdin is not a TTY,
# pcloudcc reads a single line from it and executes that line as a control
# command instead of starting up (main.cpp: `has_piped_input`). With
# `stdin_open: true` but no `tty: true` — a plausible half-way compose config,
# and what you get by dropping only `tty` after first-time login as the README
# suggests — stdin is an open pipe that never delivers a line, so the daemon
# would block there forever. /dev/null yields EOF immediately and makes startup
# behave identically no matter how the container was configured.
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

# Stop the pcloudcc background process and tear down its FUSE mount.
# Used between first-time-login mode and the normal daemon (the `-s`
# invocation must be replaced by a plain daemon before IPC commands such
# as `crypto start` can reach it reliably) and again from cleanup() on
# container shutdown.
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

wait_for_mount() {
  echo "[$2] Waiting for mount at $1 (timeout: ${MOUNT_TIMEOUT}s)..."
  _elapsed=0
  until mountpoint -q "$1" && dir_not_empty "$1"; do
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
# Shutdown
# ============================================================================

cleanup() {
  trap - TERM INT EXIT
  echo "Shutting down..."

  # There is exactly one FUSE mount left to tear down (PCLOUD_MOUNT, wherever
  # apply_bindfs_compat() pointed it), and stop_pcloudcc() owns it.
  #
  # Graceful pcloudcc shutdown - give it time to finish pending transfers
  if [ -n "${PCLOUD_PID}" ] && kill -0 "${PCLOUD_PID}" 2>/dev/null; then
    echo "Stopping pcloudcc gracefully..."
  fi
  stop_pcloudcc
}

# ============================================================================
# Phases
# ============================================================================

# bindfs is no longer installed (see the Dockerfile for why). ENABLE_BINDFS,
# BINDFS_TARGET, UID and GID are still read and validated so existing .env
# files and compose overrides start rather than abort.
#
# ENABLE_BINDFS=1 used to mean: pcloudcc mounts at PCLOUD_MOUNT, and bindfs
# re-exports that at BINDFS_TARGET with ownership rewritten to UID:GID. Of
# those two halves, the path is the one deployments actually depend on —
# BINDFS_TARGET is what docker-compose.yml bind-mounts to the host — so it is
# preserved by moving the pcloudcc mount there directly. The ownership rewrite
# is gone with the overlay that performed it; PCLOUD_FUSE_OPTS is the remaining
# lever, and the warning below points at it rather than failing silently.
apply_bindfs_compat() {
  [ "${ENABLE_BINDFS}" = "1" ] || return 0

  echo "WARNING: ENABLE_BINDFS=1 is deprecated - bindfs is no longer part of this image." >&2
  echo "         Mounting pcloudcc directly at BINDFS_TARGET ('${BINDFS_TARGET}') instead," >&2
  echo "         so the path stays where your volume mapping expects it." >&2
  echo "         UID=${UID}/GID=${GID} are no longer applied. If you need that remapping," >&2
  echo "         try PCLOUD_FUSE_OPTS=uid=${UID},gid=${GID} and verify the mount comes up." >&2

  PCLOUD_MOUNT="${BINDFS_TARGET}"
}

# With read_only: true the container FS is immutable; the mount point must be
# listed under tmpfs, bind-mounted from the host, or pre-created in the image
# so mkdir/chown can succeed.
prepare_mount_point() {
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
}

log_provided_secrets() {
  [ -n "${PCLOUD_2FA}" ]          && echo "2FA code: provided"
  [ -n "${PCLOUD_TOTP_SECRET}" ]  && echo "TOTP secret: provided (codes generated automatically)"
  [ -n "${PCLOUD_PASSWORD}" ]     && echo "Account password: provided"
  return 0
}

# Run pcloudcc once with -s to populate /root/.pcloud/data.db, then restart it
# in normal-daemon mode so crypto IPC commands work afterwards.
first_time_login() {
  if [ -z "${PCLOUD_PASSWORD}" ]; then
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

  echo "No saved credentials found — performing automatic first-time login."
  _tfa_code="$(compute_tfa_code)" || exit 1

  # pcloudcc reads the account password from PCLOUD_ACCOUNT_PASSWORD when
  # the interactive -p flag is not set. -s saves credentials to data.db.
  # It has to be exported rather than set as a one-shot prefix because
  # spawn_pcloudcc is a shell function, where a preceding assignment would
  # leak into the entrypoint's own environment in most POSIX shells anyway.
  echo "Starting pCloud command client (first-time login mode)"
  export PCLOUD_ACCOUNT_PASSWORD="${PCLOUD_PASSWORD}"
  if [ -n "${_tfa_code}" ]; then
    spawn_pcloudcc -s -t "${_tfa_code}"
  else
    spawn_pcloudcc -s
  fi

  # Wipe the password from the environment as soon as pcloudcc has it; the
  # child already holds its own copy.
  unset PCLOUD_ACCOUNT_PASSWORD PCLOUD_PASSWORD _tfa_code

  # data.db is created early in the login flow — well before the server
  # actually authenticates the account and the FUSE mount becomes usable.
  # Tearing the daemon down at that point would leave it in a half-initialized
  # state and a subsequent `crypto start` would land on a daemon that is not
  # yet ready to honour it. Wait for the FUSE mount to come up populated,
  # which is the earliest reliable signal that login truly succeeded.
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

  if ! wait_for_mount "${PCLOUD_MOUNT}" "first-login"; then
    echo "ERROR: first-time login completed but pcloud mount did not become ready" >&2
    kill -TERM "${PCLOUD_PID}" 2>/dev/null || true
    exit 1
  fi
  echo "First-time login: pCloud mount ready — login fully successful."

  # The first-time-login invocation (`pcloudcc … -s [-t TFA]`) leaves the
  # daemon in a transient state that does not reliably answer IPC commands
  # like `crypto start`. Replace it with a clean daemon before continuing
  # so the optional crypto unlock below has a stable target.
  echo "Restarting pcloudcc in normal mode after first-time login..."
  stop_pcloudcc
  start_pcloudcc
}

# Quotes a value for the pcloudcc control prompt. Since upstream swapped
# Boost.Program_options for CLI11 (lneely#396) the prompt no longer takes the
# rest of the line as one argument: CLI11::App::parse(std::string) tokenizes it
# shell-style, so `crypto start my pass phrase` arrives as four tokens and only
# "my" ever reaches the password option.
#
# CLI11 treats "..." as an escaping string (outer quotes stripped, then
# remove_escaped_characters() applied) and '...'/`...` as literal strings with
# no escape mechanism at all — so a value containing a single quote cannot be
# passed inside single quotes. Hence: wrap in double quotes and escape
# backslash and double quote, which is all remove_escaped_characters()
# recognises besides \0 and \uXXXX.
#
# Single quote and backtick are additionally rewritten to their \uXXXX form.
# They would survive inside "..." untouched, but CLI11 runs escape_detect()
# over the whole line *before* tokenizing and rewrites an '=' into a space
# when the '=' is directly followed by ' " or ` and the nearest preceding
# -/ "'` character is a '-'. A password such as `my-pass='x` would silently
# lose its '='. The \uXXXX form keeps those characters out of the raw line;
# remove_escaped_characters() decodes them back to ASCII.
prompt_quote() {
  printf '"%s"' "$(printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' \
          -e 's/"/\\"/g' \
          -e "s/'/\\\\u0027/g" \
          -e 's/`/\\u0060/g')"
}

# True when the crypto folder is currently unlocked. The folder exists in the
# mount either way, so its presence proves nothing — but pcloudcc's FUSE layer
# denies access to its contents until `crypto start` has succeeded. Same probe
# healthcheck.sh uses; LC_ALL=C keeps the message locale-independent.
crypto_unlocked() {
  _dir="${PCLOUD_MOUNT}/Crypto Folder"
  [ -d "${_dir}" ] || return 1
  _out=$(LC_ALL=C ls -al "${_dir}" 2>&1) || return 1
  case "${_out}" in
    *"Permission denied"*) return 1 ;;
  esac
  return 0
}

# A failed unlock (e.g. wrong password) must not abort the entrypoint and take
# the pcloudcc daemon down with it — log the failure and keep going.
unlock_crypto() {
  [ -n "${PCLOUD_CRYPT}" ] || return 0

  echo "Crypto password: provided"
  if ! wait_for_mount "${PCLOUD_MOUNT}" "pcloud"; then
    echo "WARNING: skipping crypto unlock — pcloud mount did not become ready." >&2
    unset PCLOUD_CRYPT
    return 0
  fi

  # `pcloudcc -k` exits 0 whatever happens: process_commands() throws away the
  # return value of process_command(), and main() calls exit(0) straight after.
  # Branching on its exit status therefore reported every unlock as successful
  # and discarded pcloudcc's actual error message together with the temp file.
  # Issue the command, ignore the status, and check the resulting state.
  _crypto_log=$(mktemp)
  printf 'crypto start %s\n' "$(prompt_quote "${PCLOUD_CRYPT}")" \
    | pcloudcc -u "${PCLOUD_USER}" -k > "${_crypto_log}" 2>&1 || true
  unset PCLOUD_CRYPT

  # The RPC is answered once the daemon has processed it, but the folder can
  # take a moment to become readable, so poll briefly before giving up.
  _waited=0
  _unlocked=0
  while [ "${_waited}" -lt 10 ]; do
    if crypto_unlocked; then
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
load_secrets
prepare_mount_point
log_provided_secrets

# Installed only once startup validation has passed: a failed validation exits
# before anything is mounted or spawned, and running cleanup() there would just
# print a misleading "Shutting down..." after the actual error.
trap cleanup TERM INT EXIT

if [ ! -f /root/.pcloud/data.db ]; then
  first_time_login
else
  start_pcloudcc
fi

unlock_crypto

# Clear remaining secrets from the environment after startup.
unset PCLOUD_2FA PCLOUD_TOTP_SECRET PCLOUD_PASSWORD 2>/dev/null || true

wait "${PCLOUD_PID}"
