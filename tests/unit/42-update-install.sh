#!/bin/sh
# The update worker, run synchronously with mocked curl (GET fixtures), the real sha256sum and mocked opkg.
# Every case ends in a terminal status: the worker's EXIT trap turns a still-"running" file into an error.
# GPB_UPDATE_STATE names the state directory (mode 700, owned by the caller) holding the fixed status and
# lock files; the per-run working directories are mktemp dirs under TMPDIR, so both are kept inside $T.
. "$(dirname "$0")/../lib.sh"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
export GPB_UPDATE_STATE="$T/upd" GPB_UPDATE_API_URL="https://example.invalid/api/latest" GPB_UPDATE_BASE_URL="https://example.invalid/download"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }
status() { cat "$T/upd/status" 2>/dev/null; }
workdirs() { ls -d "$TMPDIR"/gl-portable-backup-update.* 2>/dev/null; }
# A minimal ipk: control.tar.gz with a control file carrying the given Version, an empty data.tar.gz.
mk_ipk() {   # version outfile
    local d; d=$(mktemp -d)
    mkdir -p "$d/c" "$d/dd"
    printf 'Package: luci-app-gl-portable-backup\nVersion: %s\nArchitecture: all\n' "$1" > "$d/c/control"
    echo "2.0" > "$d/debian-binary"
    (cd "$d/c" && tar czf ../control.tar.gz .) && (cd "$d/dd" && tar czf ../data.tar.gz .)
    (cd "$d" && tar czf "$2" ./debian-binary ./control.tar.gz ./data.tar.gz)
    rm -rf "$d"
}
G="$MOCK_CURL_DIR/get"
IPK=luci-app-gl-portable-backup_1.2.0_all.ipk
mk_ipk 1.2.0 "$G/$IPK"
cp "$G/$IPK" "$G/luci-app-gl-portable-backup_latest_all.ipk"
(cd "$G" && sha256sum "$IPK" luci-app-gl-portable-backup_latest_all.ipk > SHA256SUMS)
printf '{"tag_name":"v1.2.0","html_url":"https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.2.0"}' > "$G/latest"
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.2.0\nStatus: install user installed\n' > "$T/status-after.txt"
export MOCK_OPKG_STATUS_AFTER="$T/status-after.txt"
mkdir -p "$T/root/overlay"
run_worker() { sh -c '. "$0"; cmd_update_install "$@"' "$BACKEND" "$@" >"$T/worker.out" 2>&1; }

# a. success: downloads the version-named asset and the sums, verifies, installs, confirms the new version
run_worker; rc=$?
assert_eq "$rc" 0 "success exit"
assert_contains "$(status)" '"status":"success"' "success status"
assert_contains "$(status)" 'Updated to 1.2.0' "success message"
case "$(cat "$MOCK_OPKG_LOG")" in "install $TMPDIR/gl-portable-backup-update."*"/$IPK") ;; *) echo "  opkg install path FAILED: [$(cat "$MOCK_OPKG_LOG")]"; exit 1;; esac
assert_contains "$(cat "$MOCK_CURL_LOG")" "GET https://example.invalid/download/v1.2.0/$IPK" "asset url"
assert_contains "$(cat "$MOCK_CURL_LOG")" "GET https://example.invalid/download/v1.2.0/SHA256SUMS" "sums url"
assert_eq "$(workdirs)" "" "working directory removed"
not_contains "$(cat "$MOCK_CURL_LOG")" "_latest_all.ipk" "the alias asset is never fetched"
assert_eq "$(ls "$T"/upd/status.* 2>/dev/null)" "" "no temporary status file left behind"

# b. checksum mismatch: nothing installed, error names it (the whole hash is replaced, so the corruption is never a no-op)
: > "$MOCK_OPKG_LOG"; printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
sed -i 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$G/SHA256SUMS"
run_worker; rc=$?
assert_eq "$rc" 1 "mismatch exit"
assert_contains "$(status)" '"status":"error"' "mismatch status"
assert_contains "$(status)" 'Checksum mismatch' "mismatch message"
assert_eq "$(cat "$MOCK_OPKG_LOG")" "" "nothing installed after a mismatch"
assert_eq "$(workdirs)" "" "working directory removed after a mismatch"
(cd "$G" && sha256sum "$IPK" luci-app-gl-portable-backup_latest_all.ipk > SHA256SUMS)

# c. the package's own version disagrees with the release tag
mk_ipk 1.2.1 "$G/$IPK"; (cd "$G" && sha256sum "$IPK" > SHA256SUMS)
run_worker; rc=$?
assert_eq "$rc" 1 "version mismatch exit"
assert_contains "$(status)" "says version '1.2.1' but the release is 1.2.0" "version mismatch message"
assert_eq "$(cat "$MOCK_OPKG_LOG")" "" "nothing installed after a version mismatch"
mk_ipk 1.2.0 "$G/$IPK"; (cd "$G" && sha256sum "$IPK" > SHA256SUMS)

# d. --fetch-only verifies and stops, even when the plugin is not installed via opkg
: > "$MOCK_OPKG_STATUS"
run_worker --fetch-only; rc=$?
assert_eq "$rc" 0 "fetch-only exit"
assert_contains "$(status)" "Verified $IPK (version 1.2.0); install skipped" "fetch-only message"
assert_eq "$(cat "$MOCK_OPKG_LOG")" "" "fetch-only never installs"

# e. already up to date: exit 0, nothing downloaded, nothing installed
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.2.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
: > "$MOCK_CURL_LOG"
run_worker; rc=$?
assert_eq "$rc" 0 "up-to-date exit"
assert_contains "$(status)" 'Already up to date (1.2.0)' "up to date"
not_contains "$(cat "$MOCK_CURL_LOG")" "download/" "nothing downloaded when up to date"
assert_eq "$(cat "$MOCK_OPKG_LOG")" "" "nothing installed when up to date"

# f. not installed via opkg -> refused
: > "$MOCK_OPKG_STATUS"
run_worker; rc=$?; assert_eq "$rc" 1 "not-via-opkg exit"; assert_contains "$(status)" 'not installed through opkg' "not-via-opkg message"

# g. transport failure -> terminal error, not a stuck "running"
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
MOCK_CURL_EXIT=7 sh -c '. "$0"; cmd_update_install' "$BACKEND" >"$T/worker.out" 2>&1; rc=$?
assert_eq "$rc" 1 "transport failure exit"; assert_contains "$(status)" 'cannot reach the release server' "transport message"
not_contains "$(status)" '"status":"running"' "terminal state after a transport failure"

# h. no stable release (404) -> error, nothing fetched
rm -f "$G/latest"; run_worker; assert_contains "$(status)" 'No stable release is published yet' "404 message"
printf '{"tag_name":"v1.2.0","html_url":"https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.2.0"}' > "$G/latest"

# i. the EXIT trap converts an interrupted run into an error naming the step
sh -c '. "$0"; upd_set_status running "x"; UPD_STEP="downloading"; trap upd_cleanup EXIT; exit 1' "$BACKEND"
assert_contains "$(status)" 'Interrupted during: downloading' "trap wrote the terminal error"

# j. opkg failure is reported with its last line; a TAB in that line does not break the JSON
: > "$MOCK_OPKG_LOG"
MOCK_OPKG_INSTALL_EXIT=1 sh -c '. "$0"; cmd_update_install' "$BACKEND" >"$T/worker.out" 2>&1; rc=$?
assert_eq "$rc" 1 "opkg failure exit"; assert_contains "$(status)" 'opkg install failed' "opkg failure message"
sh -c '. "$0"; upd_set_status error "$(printf "tab\there\033[0m end")"' "$BACKEND"
assert_eq "$(status)" '{"status":"error","message":"tabhere[0m end"}' "control characters stripped from the message"

# k. opkg reports success but the installed version did not change -> error
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$T/status-same.txt"
MOCK_OPKG_STATUS_AFTER="$T/status-same.txt" sh -c '. "$0"; cmd_update_install' "$BACKEND" >"$T/worker.out" 2>&1; rc=$?
assert_eq "$rc" 1 "unconfirmed install exit"; assert_contains "$(status)" "installed version is '1.1.0', not 1.2.0" "unconfirmed install message"

# l. SHA256SUMS without a line for the asset -> error before any checksum comparison
(cd "$G" && sha256sum luci-app-gl-portable-backup_latest_all.ipk > SHA256SUMS)
run_worker; rc=$?; assert_eq "$rc" 1 "no-entry exit"; assert_contains "$(status)" "SHA256SUMS carries no entry for $IPK" "no-entry message"
(cd "$G" && sha256sum "$IPK" luci-app-gl-portable-backup_latest_all.ipk > SHA256SUMS)

# m. an unknown option is refused, never treated as a real install
run_worker --fetchonly; rc=$?; assert_eq "$rc" 1 "unknown option exit"; assert_contains "$(cat "$T/worker.out")" "unknown option: --fetchonly" "unknown option message"
out=$(sh -c '. "$0"; cmd_update_start --fetchonly' "$BACKEND"); assert_contains "$out" 'Unknown option: --fetchonly' "update-start refuses an unknown option"

# n. update-status: idle without a file, the file's content with one, an error for a symlink at the path
rm -f "$T/upd/status"; assert_eq "$(cmd_update_status)" '{"status":"idle","message":""}' "idle"
sh -c '. "$0"; upd_set_status running "Downloading"' "$BACKEND"; assert_contains "$(cmd_update_status)" '"status":"running"' "status passthrough"
rm -f "$T/upd/status"; ln -s "$T/root/etc/shadow-not-here" "$T/upd/status"
assert_contains "$(cmd_update_status)" 'Unexpected file at' "symlink at the status path is refused"
out=$(sh -c '. "$0"; cmd_update_start' "$BACKEND"); assert_contains "$out" 'Unexpected file at' "update-start refuses a planted status path"
rm -f "$T/upd/status"

# o. update-start: refuses while the lock is held; reports a broken lock mechanism; otherwise stages and starts
( exec 9>>"$T/upd/lock"; flock -n 9; out=$(sh -c '. "$0"; cmd_update_start' "$BACKEND"); case "$out" in *'already running'*) exit 0;; *) echo "  update-start FAILED: [$out]"; exit 1;; esac ) || exit 1
mkdir -p "$T/nobin"; printf '#!/bin/sh\necho "flock: broken" >&2; exit 64\n' > "$T/nobin/flock"; chmod +x "$T/nobin/flock"
out=$(PATH="$T/nobin:$PATH" sh -c '. "$0"; cmd_update_start' "$BACKEND"); assert_contains "$out" 'Cannot take the update lock (exit 64): flock: broken' "broken flock reported, not mistaken for running"
PATH="$T/nobin:$PATH" sh -c '. "$0"; cmd_update_install --fetch-only' "$BACKEND" >"$T/worker.out" 2>&1; rc=$?
assert_eq "$rc" 1 "worker: broken flock exit"; assert_contains "$(status)" 'Cannot take the update lock (flock exit 64)' "worker: broken flock leaves a terminal error"
assert_eq "$(workdirs)" "" "worker: broken flock leaves no working directory"
rm -f "$T/upd/status"
out=$(sh -c '. "$0"; cmd_update_start --fetch-only' "$BACKEND")
assert_contains "$out" '"status":"started"' "started"
assert_file "$T/upd/status"   # primed by update-start; the detached worker may already have finished
# the detached worker (fetch-only, mocks inherited through PATH) must reach a terminal state on its own
i=0; while [ $i -lt 120 ] && grep -q '"status":"running"' "$T/upd/status" 2>/dev/null; do sleep 0.25; i=$((i+1)); done
assert_contains "$(status)" 'install skipped' "detached worker finished"
i=0; while [ $i -lt 120 ] && [ -n "$(workdirs)" ]; do sleep 0.25; i=$((i+1)); done
assert_eq "$(workdirs)" "" "detached worker removed its working directory"

# p. the worker exits silently, touching nothing, when another worker holds the lock
sh -c '. "$0"; upd_set_status success "earlier run"' "$BACKEND"
( exec 9>>"$T/upd/lock"; flock -n 9
  out=$(sh -c '. "$0"; cmd_update_install --fetch-only' "$BACKEND" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { echo "  lock-held worker exit $rc"; exit 1; }
  [ -z "$out" ] || { echo "  lock-held worker printed: [$out]"; exit 1; } ) || exit 1
assert_eq "$(status)" '{"status":"success","message":"earlier run"}' "lock-held worker leaves the status alone"
assert_eq "$(workdirs)" "" "lock-held worker leaves no working directory"

# q. the cleanup trap removes the working directory even when the status file cannot be written
mkdir -p "$T/failmk"; realmk=$(command -v mktemp)
printf '#!/bin/sh
case "$*" in *status.*) exit 1;; esac
exec %s "$@"
' "$realmk" > "$T/failmk/mktemp"; chmod +x "$T/failmk/mktemp"
sh -c '. "$0"; upd_set_status running "x"' "$BACKEND"
d=$(mktemp -d "$TMPDIR/gl-portable-backup-update.XXXXXX")
PATH="$T/failmk:$PATH" GPB_UPDATE_DIR="$d" sh -c '. "$0"; UPD_STEP=downloading; trap upd_cleanup EXIT; exit 1' "$BACKEND" 2>/dev/null; rc=$?
assert_eq "$rc" 1 "the worker's own exit status survives the trap"
assert_no_file "$d"
rm -f "$T/upd/status"

# r. the state location must be a directory of mode 700 owned by this user; nothing is opened otherwise
mkdir -p "$T/elsewhere"
rm -rf "$T/upd"; ln -s "$T/elsewhere" "$T/upd"
assert_contains "$(sh -c '. "$0"; cmd_update_start --fetch-only' "$BACKEND")" "Unexpected file at $T/upd" "symlinked state dir refused (start)"
rc=0; sh -c '. "$0"; cmd_update_install --fetch-only' "$BACKEND" >"$T/worker.out" 2>&1 || rc=$?
assert_eq "$rc" 1 "symlinked state dir refused (worker)"; assert_contains "$(cat "$T/worker.out")" "unexpected file at $T/upd" "worker names the path"
assert_contains "$(sh -c '. "$0"; cmd_update_status' "$BACKEND")" "Unexpected file at $T/upd" "symlinked state dir refused (status)"
assert_eq "$(ls -A "$T/elsewhere")" "" "nothing created through the symlink"
rm -f "$T/upd"; mkdir -m 755 "$T/upd"
assert_contains "$(sh -c '. "$0"; cmd_update_start --fetch-only' "$BACKEND")" "Unexpected file at $T/upd" "mode 755 refused (start)"
rc=0; sh -c '. "$0"; cmd_update_install --fetch-only' "$BACKEND" >/dev/null 2>&1 || rc=$?; assert_eq "$rc" 1 "mode 755 refused (worker)"
assert_eq "$(ls -A "$T/upd")" "" "nothing created in a mode-755 directory"
rmdir "$T/upd"; echo x > "$T/upd"
assert_contains "$(sh -c '. "$0"; cmd_update_start' "$BACKEND")" "Unexpected file at $T/upd" "a regular file at the state path refused"
rm -f "$T/upd"; mkdir -m 700 "$T/upd"; ln -s "$T/elsewhere/l" "$T/upd/lock"
assert_contains "$(sh -c '. "$0"; cmd_update_start' "$BACKEND")" "Unexpected file at" "symlinked lock in a valid directory refused"
assert_no_file "$T/elsewhere/l"
rm -rf "$T/upd"
assert_eq "$(sh -c '. "$0"; cmd_update_status' "$BACKEND")" '{"status":"idle","message":""}' "absent state dir = idle"
assert_no_file "$T/upd"
out=$(sh -c '. "$0"; cmd_update_start --fetch-only' "$BACKEND"); assert_contains "$out" '"status":"started"' "start creates the directory"
[ "$(ls -ldn "$T/upd" | awk '{print $1}')" = "drwx------" ] || { echo "  state dir mode: $(ls -ldn "$T/upd")"; exit 1; }
i=0; while [ $i -lt 120 ] && { grep -q '"status":"running"' "$T/upd/status" 2>/dev/null || [ -n "$(workdirs)" ]; }; do sleep 0.25; i=$((i+1)); done
echo "ok 42-update-install"
