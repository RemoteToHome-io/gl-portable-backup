#!/bin/sh
# The update worker, run synchronously with mocked curl (GET fixtures), the real sha256sum and mocked opkg.
# Every case ends in a terminal status: the worker's EXIT trap turns a still-"running" file into an error.
. "$(dirname "$0")/../lib.sh"
export GPB_UPDATE_DIR="$T/upd" GPB_UPDATE_API_URL="https://example.invalid/api/latest" GPB_UPDATE_BASE_URL="https://example.invalid/download"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }
status() { cat "$T/upd.status" 2>/dev/null; }
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
assert_contains "$(cat "$MOCK_OPKG_LOG")" "install $T/upd/$IPK" "opkg installed the downloaded file"
assert_contains "$(cat "$MOCK_CURL_LOG")" "GET https://example.invalid/download/v1.2.0/$IPK" "asset url"
assert_contains "$(cat "$MOCK_CURL_LOG")" "GET https://example.invalid/download/v1.2.0/SHA256SUMS" "sums url"
assert_no_file "$T/upd" "working directory removed"
not_contains "$(cat "$MOCK_CURL_LOG")" "_latest_all.ipk" "the alias asset is never fetched"

# b. checksum mismatch: nothing installed, error names it
: > "$MOCK_OPKG_LOG"; printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
sed -i "s/^[0-9a-f]\{4\}/0000/" "$G/SHA256SUMS"
run_worker; rc=$?
assert_eq "$rc" 1 "mismatch exit"
assert_contains "$(status)" '"status":"error"' "mismatch status"
assert_contains "$(status)" 'Checksum mismatch' "mismatch message"
assert_eq "$(cat "$MOCK_OPKG_LOG")" "" "nothing installed after a mismatch"
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

# e. already up to date
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.2.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
run_worker; assert_contains "$(status)" 'Already up to date (1.2.0)' "up to date"

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

# j. opkg failure is reported with its last line
: > "$MOCK_OPKG_LOG"; MOCK_OPKG_INSTALL_EXIT=1 sh -c '. "$0"; cmd_update_install' "$BACKEND" >"$T/worker.out" 2>&1; rc=$?
assert_eq "$rc" 1 "opkg failure exit"; assert_contains "$(status)" 'opkg install failed' "opkg failure message"

# k. update-status: idle without a file, the file's content with one
rm -f "$T/upd.status"; assert_eq "$(cmd_update_status)" '{"status":"idle","message":""}' "idle"
upd_set_status running "Downloading"; assert_contains "$(cmd_update_status)" '"status":"running"' "status passthrough"
rm -f "$T/upd.status"

# l. update-start: refuses while the lock is held; otherwise stages the worker and reports started
( exec 9>>"$T/upd.lock"; flock -n 9; out=$(sh -c '. "$0"; cmd_update_start' "$BACKEND"); case "$out" in *'"already running"'*|*'already running'*) exit 0;; *) echo "  update-start FAILED: [$out]"; exit 1;; esac ) || exit 1
out=$(sh -c '. "$0"; cmd_update_start --fetch-only' "$BACKEND")
assert_contains "$out" '"status":"started"' "started"
assert_file "$T/upd/worker.sh"
assert_contains "$(status)" '"status":"running"' "status primed before the worker runs"
# the detached worker (fetch-only, mocks inherited through PATH) must reach a terminal state on its own
i=0; while [ $i -lt 20 ] && grep -q '"status":"running"' "$T/upd.status" 2>/dev/null; do sleep 0.25; i=$((i+1)); done
assert_contains "$(status)" 'install skipped' "detached worker finished"
echo "ok 42-update-install"
