# shellcheck shell=sh
# Helpers shared by entrypoint.sh and healthcheck.sh. Sourced, not executed.
# Installed at /usr/local/lib/pcloudcc/common.sh.

# Fixed paths inside the container. Overridable only so tests can run the
# scripts outside of it; pcloudcc itself always uses /root/.pcloud.
: "${PCLOUD_DATA_DB:=/root/.pcloud/data.db}"
: "${PCLOUD_SECRETS_DIR:=/run/secrets}"

# The mount point pcloudcc uses. ENABLE_BINDFS=1 is a deprecated alias that
# moves it to BINDFS_TARGET (see apply_bindfs_compat in entrypoint.sh).
effective_mount() {
  if [ "${ENABLE_BINDFS:-0}" = "1" ]; then
    printf '%s' "${BINDFS_TARGET:-/pcloud}"
  else
    printf '%s' "${PCLOUD_MOUNT:-/pcloud}"
  fi
}

# True when directory $1 has at least one entry. Stops at the first one, so a
# large pCloud root is not listed in full on every probe.
dir_not_empty() {
  [ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

# True when $1 is mounted and populated: the earliest reliable sign that
# pcloudcc is logged in and serving the filesystem.
mount_ready() {
  mountpoint -q "$1" 2>/dev/null && dir_not_empty "$1"
}

# True when a crypto password is configured through any supported source.
# -s on the default secret so an empty placeholder file does not count.
crypto_configured() {
  [ -n "${PCLOUD_CRYPT:-}" ] || [ -n "${PCLOUD_CRYPT_FILE:-}" ] \
    || [ -s "${PCLOUD_SECRETS_DIR}/pcloud_crypt" ]
}

# True when "<mount $1>/Crypto Folder" is unlocked. The folder exists either
# way; pcloudcc's FUSE layer denies access to its contents until
# `crypto start` succeeded. `ls -al` stats `.`/`..`, which triggers that
# check; LC_ALL=C keeps the error message locale-independent.
crypto_unlocked() {
  _dir="$1/Crypto Folder"
  [ -d "${_dir}" ] || return 1
  _out=$(LC_ALL=C ls -al "${_dir}" 2>&1) || return 1
  case "${_out}" in
    *"Permission denied"*) return 1 ;;
  esac
  return 0
}

# True when PCLOUD_FUSE_OPTS already carries option $1, matched on the key
# (`uid=0` counts as `uid`). Padding with commas keeps `uid` from matching
# the tail of another option.
fuse_opt_present() {
  case ",${PCLOUD_FUSE_OPTS:-}," in
    *",$1,"*|*",$1="*) return 0 ;;
  esac
  return 1
}

fuse_opt_append() {
  if [ -z "${PCLOUD_FUSE_OPTS:-}" ]; then
    PCLOUD_FUSE_OPTS="$1"
  else
    PCLOUD_FUSE_OPTS="${PCLOUD_FUSE_OPTS},$1"
  fi
}

# Prints an error and returns 1 unless $2 is a safe mount path: absolute, no
# `..`, and not `/` or a top-level system directory. $1 names the variable.
validate_mount_path() {
  case "$2" in
    ""|"/")
      echo "ERROR: $1='$2' must not be empty or '/'" >&2; return 1 ;;
    /bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      echo "ERROR: $1='$2' is a top-level system directory" >&2; return 1 ;;
    *..*)
      echo "ERROR: $1='$2' must not contain '..'" >&2; return 1 ;;
    /*) return 0 ;;
    *)
      echo "ERROR: $1='$2' must be an absolute path" >&2; return 1 ;;
  esac
}

# Quotes $1 for pcloudcc's control prompt (`pcloudcc -k`), which CLI11
# tokenizes shell-style. Inside "..." CLI11 only unescapes \\, \", \0 and
# \uXXXX, so backslash and double quote are escaped. Single quote and
# backtick are sent as \u0027 / \u0060: CLI11 pre-scans the raw line and
# turns `-x='` style sequences into `-x '`, which would drop an `=` from a
# password like `my-pass='x`.
prompt_quote() {
  printf '"%s"' "$(printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' \
          -e 's/"/\\"/g' \
          -e "s/'/\\\\u0027/g" \
          -e 's/`/\\u0060/g')"
}
