#!/bin/sh
# Tests for common.sh, entrypoint.sh and healthcheck.sh. No Docker needed:
# pcloudcc, mountpoint, fusermount3, oathtool and sleep are replaced by stubs.
#
# Run: sh tests/run.sh   (CI runs it with dash, the image's /bin/sh)
#      TEST_VERBOSE=1 sh tests/run.sh   shows the entrypoint output
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d) || exit 1
# Everything below deletes under ${WORK}; never let it be empty.
case "${WORK}" in /?*) ;; *) echo "mktemp failed" >&2; exit 1 ;; esac
trap 'rm -rf "${WORK}"' EXIT

TOTAL=0
FAILED=0

pass() { TOTAL=$((TOTAL + 1)); echo "ok   - $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1)); echo "FAIL - $1"; }

# check <description> <command...>: passes when the command succeeds.
check() {
  _desc="$1"; shift
  if "$@"; then pass "${_desc}"; else fail "${_desc}"; fi
}

# check_not <description> <command...>: passes when the command fails.
check_not() {
  _desc="$1"; shift
  if "$@"; then fail "${_desc}"; else pass "${_desc}"; fi
}

# check_eq <description> <expected> <actual>
check_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1"
    echo "       expected: $2"
    echo "       actual:   $3"
  fi
}

# ============================================================================
# common.sh
# ============================================================================

# Each helper runs in a subshell so state cannot leak between cases.
lib() { ( . "${ROOT}/common.sh"; "$@" ); }

check_eq "prompt_quote: plain value" '"my pass"' "$(lib prompt_quote 'my pass')"
check_eq "prompt_quote: backslash and double quote" '"a\\b\"c"' "$(lib prompt_quote 'a\b"c')"
BACKTICK=$(printf '\140')
check_eq "prompt_quote: single quote and backtick" '"x\u0027y\u0060z"' "$(lib prompt_quote "x'y${BACKTICK}z")"
check_eq "prompt_quote: '=' before a quote survives" '"my-pass=\u0027x"' "$(lib prompt_quote "my-pass='x")"

fopts() { ( PCLOUD_FUSE_OPTS="$1"; . "${ROOT}/common.sh"; fuse_opt_present "$2" ); }
check "fuse_opt_present: key with value"        fopts "uid=1000,allow_other" uid
check "fuse_opt_present: flag"                  fopts "uid=1000,allow_other" allow_other
check_not "fuse_opt_present: missing key"         fopts "uid=1000,allow_other" gid
check_not "fuse_opt_present: no suffix match"     fopts "rouid=1" uid
check_not "fuse_opt_present: empty options"       fopts "" uid

check_eq "fuse_opt_append: to empty" "uid=1" \
  "$( PCLOUD_FUSE_OPTS=""; . "${ROOT}/common.sh"; fuse_opt_append uid=1; printf '%s' "${PCLOUD_FUSE_OPTS}" )"
check_eq "fuse_opt_append: to existing" "ro,uid=1" \
  "$( PCLOUD_FUSE_OPTS="ro"; . "${ROOT}/common.sh"; fuse_opt_append uid=1; printf '%s' "${PCLOUD_FUSE_OPTS}" )"

vpath() { lib validate_mount_path X "$1" 2>/dev/null; }
check "validate_mount_path: /pcloud"          vpath /pcloud
check "validate_mount_path: nested path"      vpath /mnt/pcloud
check_not "validate_mount_path: rejects /"      vpath /
check_not "validate_mount_path: rejects empty"  vpath ""
check_not "validate_mount_path: rejects /etc"   vpath /etc
check_not "validate_mount_path: rejects '..'"  vpath /mnt/../etc
check_not "validate_mount_path: rejects relative" vpath pcloud

# mount_is_stale reads the error text of `ls`, so the cases are driven by a
# stub `ls` on PATH, in a directory used by these subshells only.
STALE_BIN="${WORK}/stale-bin"
mkdir -p "${STALE_BIN}"
cat > "${STALE_BIN}/ls" <<'EOF'
#!/bin/sh
# Mimics coreutils/BusyBox `ls` on a path whose FUSE server is gone.
case " $* " in
  *" /stale "*)
    echo "ls: cannot access '/stale': Transport endpoint is not connected" >&2
    exit 2 ;;
  *" /denied "*)
    echo "ls: cannot access '/denied': Permission denied" >&2
    exit 2 ;;
esac
exit 0
EOF
chmod +x "${STALE_BIN}/ls"
stale() { ( PATH="${STALE_BIN}:${PATH}"; . "${ROOT}/common.sh"; mount_is_stale "$1" ); }
check "mount_is_stale: ENOTCONN path"                stale /stale
check_not "mount_is_stale: reachable path"             stale /fine
check_not "mount_is_stale: other stat error is not stale" stale /denied
check_not "mount_is_stale: real, existing directory"   lib mount_is_stale "${ROOT}"

check_eq "effective_mount: PCLOUD_MOUNT" "/data" \
  "$(PCLOUD_MOUNT=/data ENABLE_BINDFS=0 lib effective_mount)"
check_eq "effective_mount: ENABLE_BINDFS=1 uses BINDFS_TARGET" "/b" \
  "$(PCLOUD_MOUNT=/data ENABLE_BINDFS=1 BINDFS_TARGET=/b lib effective_mount)"

mkdir -p "${WORK}/sec"
check_not "crypto_configured: nothing set" \
  env -i PCLOUD_SECRETS_DIR="${WORK}/sec" sh -c ". '${ROOT}/common.sh'; crypto_configured"
: > "${WORK}/sec/pcloud_crypt"
check_not "crypto_configured: empty secret file does not count" \
  env -i PCLOUD_SECRETS_DIR="${WORK}/sec" sh -c ". '${ROOT}/common.sh'; crypto_configured"
printf 'x' > "${WORK}/sec/pcloud_crypt"
check "crypto_configured: secret file" \
  env -i PCLOUD_SECRETS_DIR="${WORK}/sec" sh -c ". '${ROOT}/common.sh'; crypto_configured"
rm -f "${WORK}/sec/pcloud_crypt"
check "crypto_configured: PCLOUD_CRYPT_FILE" \
  env -i PCLOUD_SECRETS_DIR="${WORK}/sec" PCLOUD_CRYPT_FILE=/x sh -c ". '${ROOT}/common.sh'; crypto_configured"

# ============================================================================
# Stubs for entrypoint.sh / healthcheck.sh
# ============================================================================

BIN="${WORK}/bin"
OUT="${WORK}/out"        # what the stubs record
MNT="${WORK}/mnt"
DB="${WORK}/state/data.db"
SECRETS="${WORK}/secrets"
mkdir -p "${BIN}" "${OUT}" "${MNT}" "${WORK}/state" "${SECRETS}"

# pcloudcc: records argv, environment and (for -k) stdin, and "mounts" by
# creating ${OUT}/mounted plus an entry in the mount directory.
cat > "${BIN}/pcloudcc" <<EOF
#!/bin/sh
case " \$* " in
  *" -k "*) cat > "${OUT}/k-stdin"; env > "${OUT}/env-k"; exit 0 ;;
  *" -s "*) echo "\$*" > "${OUT}/argv-login"; env > "${OUT}/env-login"
            touch "${DB}" ;;
  *)        echo "\$*" > "${OUT}/argv-daemon"; env > "${OUT}/env-daemon" ;;
esac
touch "${OUT}/mounted" "${MNT}/file"
mkdir -p "${MNT}/Crypto Folder"
EOF
cat > "${BIN}/mountpoint" <<EOF
#!/bin/sh
[ -e "${OUT}/mounted" ]
EOF
cat > "${BIN}/fusermount3" <<EOF
#!/bin/sh
rm -f "${OUT}/mounted"
EOF
cat > "${BIN}/oathtool" <<'EOF'
#!/bin/sh
cat > /dev/null
echo 123456
EOF
# The scripts poll in 1-2s steps; a 0.1s sleep keeps the tests fast while
# still giving the background pcloudcc stub time to run. An absolute path is
# required: a BusyBox ash built as a standalone shell answers `command -v
# sleep` with the bare applet name, and the stub would then re-exec itself
# through PATH forever.
REAL_SLEEP=$(command -v sleep)
case "${REAL_SLEEP}" in
  /*) ;;
  *) for d in /bin /usr/bin; do [ -x "$d/sleep" ] && REAL_SLEEP="$d/sleep" && break; done ;;
esac
printf '#!/bin/sh\nexec %s 0.1\n' "${REAL_SLEEP}" > "${BIN}/sleep"
chmod +x "${BIN}"/*

reset_state() {
  rm -rf "${OUT}" "${MNT}" "${DB}" "${SECRETS}"
  mkdir -p "${OUT}" "${MNT}" "${SECRETS}"
}

# run_entrypoint [VAR=value...]: runs entrypoint.sh with a clean environment,
# output in ${OUT}/log, exit status in ${OUT}/rc.
# TEST_PATH_PREFIX lets a single case shadow a stub (set it, run, clear it).
TEST_PATH_PREFIX=""

run_entrypoint() {
  env -i PATH="${TEST_PATH_PREFIX:+${TEST_PATH_PREFIX}:}${BIN}:/usr/bin:/bin" \
    PCLOUDCC_LIB="${ROOT}/common.sh" \
    PCLOUD_DATA_DB="${DB}" \
    PCLOUD_SECRETS_DIR="${SECRETS}" \
    PCLOUD_USER=user@example.com \
    PCLOUD_MOUNT="${MNT}" \
    MOUNT_TIMEOUT=20 \
    "$@" sh "${ROOT}/entrypoint.sh" > "${OUT}/log" 2>&1
  echo $? > "${OUT}/rc"
  # TEST_VERBOSE=1 shows each run's output.
  [ -z "${TEST_VERBOSE:-}" ] || sed 's/^/       | /' "${OUT}/log"
}

run_healthcheck() {
  env -i PATH="${TEST_PATH_PREFIX:+${TEST_PATH_PREFIX}:}${BIN}:/usr/bin:/bin" \
    PCLOUDCC_LIB="${ROOT}/common.sh" \
    PCLOUD_DATA_DB="${DB}" \
    PCLOUD_SECRETS_DIR="${SECRETS}" \
    PCLOUD_MOUNT="${MNT}" \
    "$@" sh "${ROOT}/healthcheck.sh" > "${OUT}/hc-log" 2>&1
}
hc_log() { cat "${OUT}/hc-log"; }

no_secrets_in() {
  [ -f "$1" ] && ! grep -Eq '^PCLOUD_(PASSWORD|TOTP_SECRET|CRYPT|2FA|ACCOUNT_PASSWORD)=' "$1"
}
log_has() { grep -q "$1" "${OUT}/log"; }

# check_log <description> <literal text>: like `check ... log_has`, but prints
# the captured log when the text is missing - a failure that only shows up on
# another platform is otherwise invisible in CI.
check_log() {
  if grep -qF "$2" "${OUT}/log"; then
    pass "$1"
  else
    fail "$1"
    echo "       expected to find: $2"
    sed 's/^/       | /' "${OUT}/log"
  fi
}
rc_is() { [ "$(cat "${OUT}/rc")" = "$1" ]; }

# ============================================================================
# entrypoint.sh
# ============================================================================

reset_state
run_entrypoint PCLOUD_USER=
check "entrypoint: PCLOUD_USER is required" rc_is 1
check "entrypoint: ...with an error message" log_has "PCLOUD_USER is required"

reset_state
run_entrypoint PCLOUD_CACHE_SIZE=2000
check "entrypoint: rejects PCLOUD_CACHE_SIZE out of range" rc_is 1

reset_state
run_entrypoint PCLOUD_FUSE_OPTS="uid=1 ro"
check "entrypoint: rejects spaces in PCLOUD_FUSE_OPTS" rc_is 1

reset_state
run_entrypoint PCLOUD_MOUNT=/etc
check "entrypoint: rejects a system directory as mount point" rc_is 1

# Normal start with credentials saved and secrets in the environment.
reset_state
touch "${DB}"
run_entrypoint PCLOUD_PASSWORD=envpw PCLOUD_TOTP_SECRET=ENVTOTP PCLOUD_2FA=111111 \
  PCLOUD_CRYPT=envcrypt
check "start: exits cleanly" rc_is 0
check "start: daemon environment has no secrets" no_secrets_in "${OUT}/env-daemon"
check "start: -k client environment has no secrets" no_secrets_in "${OUT}/env-k"
check "start: notice for secrets passed via environment" log_has "NOTICE: PCLOUD_PASSWORD is set as an environment variable"
check_eq "start: crypto password sent quoted on stdin" 'crypto start "envcrypt"' "$(cat "${OUT}/k-stdin")"
check "start: mount torn down on exit" test ! -e "${OUT}/mounted"

# Secret files win over the environment.
reset_state
touch "${DB}"
printf 'filecrypt' > "${SECRETS}/pcloud_crypt"
run_entrypoint PCLOUD_CRYPT=envcrypt
check_eq "secrets: /run/secrets file wins over environment" 'crypto start "filecrypt"' "$(cat "${OUT}/k-stdin")"

reset_state
touch "${DB}"
printf 'default' > "${SECRETS}/pcloud_crypt"
printf 'explicit' > "${WORK}/explicit_crypt"
run_entrypoint PCLOUD_CRYPT_FILE="${WORK}/explicit_crypt"
check_eq "secrets: *_FILE wins over /run/secrets" 'crypto start "explicit"' "$(cat "${OUT}/k-stdin")"
check_not "secrets: no notice when only files are used" log_has "NOTICE: PCLOUD_CRYPT"

reset_state
touch "${DB}"
run_entrypoint PCLOUD_CRYPT_FILE="${WORK}/does-not-exist"
check "secrets: unreadable *_FILE is fatal" rc_is 1

# Automatic first-time login from secret files.
reset_state
printf 'filepw' > "${SECRETS}/pcloud_password"
printf 'JBSW Y3DP' > "${SECRETS}/pcloud_totp_secret"
run_entrypoint
check "first login: exits cleanly" rc_is 0
check "first login: password handed over as PCLOUD_ACCOUNT_PASSWORD" \
  grep -qx 'PCLOUD_ACCOUNT_PASSWORD=filepw' "${OUT}/env-login"
check "first login: TOTP code passed with -t" grep -q -- '-s -t 123456' "${OUT}/argv-login"
check "first login: restarted daemon has no secrets" no_secrets_in "${OUT}/env-daemon"

# No password and no saved credentials: print instructions and idle.
reset_state
run_entrypoint
check "manual login: prints instructions" log_has "pcloudcc -u user@example.com -m ${MNT} -p -s"
check "manual login: does not start pcloudcc" test ! -e "${OUT}/argv-daemon"

# Deprecated ENABLE_BINDFS=1 is translated into mount point and FUSE options.
reset_state
touch "${DB}"
mkdir -p "${WORK}/bindfs"
run_entrypoint ENABLE_BINDFS=1 BINDFS_TARGET="${WORK}/bindfs" UID=1001 GID=1002
check "bindfs compat: mounts at BINDFS_TARGET" grep -q -- "-m ${WORK}/bindfs" "${OUT}/argv-daemon"
check "bindfs compat: adds uid/gid/allow_other/default_permissions" \
  grep -q -- '--fuse-opts uid=1001,gid=1002,allow_other,default_permissions' "${OUT}/argv-daemon"

reset_state
touch "${DB}"
run_entrypoint PCLOUD_FUSE_OPTS=allow_other
check "warns about allow_other without default_permissions" log_has "WARNING: PCLOUD_FUSE_OPTS enables 'allow_other'"

reset_state
touch "${DB}"
run_entrypoint GROUP=users
check "notice for the removed GROUP/USER variables" log_has "NOTICE: GROUP (and USER) are no longer used"

# A stale FUSE mount left by an unclean shutdown: ${MNT} cannot be stat'ed
# until it has been unmounted. The stubs below shadow `ls` and the unmount
# helpers for one entrypoint run; `unmounts` counts the attempts, and the
# path becomes reachable again after ${STALE_DEPTH} of them, which is how
# several stacked dead mounts behave.
STALE_RUN="${WORK}/stale-run"
mkdir -p "${STALE_RUN}"
cat > "${STALE_RUN}/ls" <<EOF
#!/bin/sh
# Stale as long as fewer than \${STALE_DEPTH} unmounts have been recorded.
if [ -z "\${STALE_DEPTH:-}" ]; then exec /bin/ls "\$@"; fi
_done=0
[ ! -f "${OUT}/unmounts" ] || _done=\$(wc -l < "${OUT}/unmounts")
case " \$* " in
  *" ${MNT} "*)
    if [ "\${_done}" -lt "\${STALE_DEPTH}" ]; then
      echo "ls: cannot access '${MNT}': Transport endpoint is not connected" >&2
      exit 2
    fi ;;
esac
exec /bin/ls "\$@"
EOF
cat > "${STALE_RUN}/fusermount3" <<EOF
#!/bin/sh
echo "\$*" >> "${OUT}/unmounts"
rm -f "${OUT}/mounted"
EOF
chmod +x "${STALE_RUN}"/*

# A mount point that cannot be created: the failure names mkdir's own reason.
reset_state
touch "${DB}" "${WORK}/not-a-dir"
run_entrypoint PCLOUD_MOUNT="${WORK}/not-a-dir"
check "unusable mount point: entrypoint fails" rc_is 1
check_log "unusable mount point: names mkdir's reason" "mkdir:"
check "unusable mount point: keeps the read_only hint" log_has "read_only: true"

unmount_count() { [ ! -f "${OUT}/unmounts" ] || wc -l < "${OUT}/unmounts"; }

TEST_PATH_PREFIX="${STALE_RUN}"

# One dead mount on the path: cleared, then the normal start proceeds.
reset_state
touch "${DB}"
run_entrypoint STALE_DEPTH=1
check "stale mount: entrypoint starts after clearing it" rc_is 0
check "stale mount: ...and says what it found" log_has "holds a stale FUSE mount"
check "stale mount: ...and reports it cleared" log_has "Cleared stale FUSE mount"
check "stale mount: ...and still starts pcloudcc" test -e "${OUT}/argv-daemon"

# Three stacked dead mounts: unmounted repeatedly until the path is reachable.
reset_state
touch "${DB}"
run_entrypoint STALE_DEPTH=3
check "stacked stale mounts: entrypoint starts" rc_is 0
check "stacked stale mounts: unmounted until reachable" \
  test "$(unmount_count)" -ge 3

# Unmounting does not help (e.g. no privileges): fail with the host recipe
# instead of the misleading "cannot create mount point" message.
reset_state
touch "${DB}"
run_entrypoint STALE_DEPTH=999
check "unclearable stale mount: entrypoint fails" rc_is 1
check "unclearable stale mount: names the path as unreachable" log_has "is still unreachable after"
check "unclearable stale mount: prints the host unmount command" log_has "umount -l"
check "unclearable stale mount: does not start pcloudcc" test ! -e "${OUT}/argv-daemon"
check_not "unclearable stale mount: no misleading read_only hint" log_has "read_only: true"

# The healthcheck names a stale mount instead of just failing.
reset_state
touch "${DB}" "${OUT}/mounted" "${MNT}/file"
check_not "healthcheck: unhealthy on a stale mount" run_healthcheck STALE_DEPTH=1
check_eq "healthcheck: ...and says so" \
  "stale FUSE mount at ${MNT} - Transport endpoint is not connected" "$(hc_log)"

TEST_PATH_PREFIX=""

# ============================================================================
# healthcheck.sh
# ============================================================================

reset_state
check "healthcheck: healthy before first login" run_healthcheck

touch "${DB}"
check_not "healthcheck: unhealthy when not mounted" run_healthcheck

touch "${OUT}/mounted"
check_not "healthcheck: unhealthy when mounted but empty" run_healthcheck

touch "${MNT}/file"
check "healthcheck: healthy when mounted and populated" run_healthcheck

printf 'x' > "${SECRETS}/pcloud_crypt"
check_not "healthcheck: unhealthy when crypto configured but folder missing" run_healthcheck

mkdir -p "${MNT}/Crypto Folder"
check "healthcheck: healthy when crypto folder is readable" run_healthcheck

# ============================================================================

echo
echo "${TOTAL} tests, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
