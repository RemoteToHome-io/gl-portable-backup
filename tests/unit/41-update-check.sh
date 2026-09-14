#!/bin/sh
# update-check: version compare, release query (404 / newer / same / prerelease / malformed / foreign URL /
# transport failure), and the not-installed-via-opkg case. The mock curl serves GET fixtures from
# $MOCK_CURL_DIR/get/<last URL component>; the API URL below ends in "latest", so the fixture is get/latest.
. "$(dirname "$0")/../lib.sh"
export GPB_UPDATE_STATE="$T/upd" GPB_UPDATE_API_URL="https://example.invalid/api/latest" GPB_UPDATE_BASE_URL="https://example.invalid/download"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }
gt() { ver_gt "$1" "$2" || { echo "  ver_gt FAILED: $1 should be newer than $2"; exit 1; }; }
le() { ver_gt "$1" "$2" && { echo "  ver_gt FAILED: $1 should NOT be newer than $2"; exit 1; }; return 0; }
gt 1.2.0 1.1.0; gt 1.10.0 1.9.0; gt 2.0 1.9.9; gt 1.1.1 1.1; gt 1.0.0 1.0.0-beta.2; gt 1.1.0-rc1 1.0.0; gt 1.0.0 ""
le 1.1.0 1.1.0; le 1.1 1.1.1; le 1.0.0-beta.2 1.0.0; le 1.0.0-beta.2 1.0.0-beta.1; le 0.9.9 1.0.0; le "" 1.0.0
assert_eq "$(ver_base 1.2.0-beta.1)" "1.2.0" "ver_base strips the suffix"

# 1. no fixture = GitHub 404 = no stable release; not installed via opkg (empty status)
out=$(cmd_update_check)
assert_contains "$out" '"installed":"'"$VERSION"'"' "installed falls back to the script version"
assert_contains "$out" '"installed_via_opkg":false' "not via opkg"
assert_contains "$out" '"latest":""' "no latest on 404"
assert_contains "$out" '"update_available":false' "nothing offered on 404"
assert_contains "$out" 'No stable release is published yet' "404 message"
assert_contains "$(cat "$MOCK_CURL_LOG")" "GET https://example.invalid/api/latest" "the API URL override is used"

# 2. installed 1.1.0 via opkg, latest v1.2.0 with a GitHub release URL -> offered
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
printf '{"tag_name":"v1.2.0","html_url":"https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.2.0"}' > "$MOCK_CURL_DIR/get/latest"
out=$(cmd_update_check)
assert_contains "$out" '"installed":"1.1.0"' "installed from opkg"
assert_contains "$out" '"installed_via_opkg":true' "via opkg"
assert_contains "$out" '"latest":"1.2.0"' "latest without the v"
assert_contains "$out" '"update_available":true' "offered"
assert_contains "$out" '"release_url":"https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.2.0"' "release url kept"
assert_contains "$out" '"message":""' "no message on success"

# 3. same version -> not offered
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.2.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
out=$(cmd_update_check); assert_contains "$out" '"update_available":false' "same version not offered"

# 4. a suffixed tag is a prerelease: never offered, reported as no latest
printf 'Package: luci-app-gl-portable-backup\nVersion: 1.1.0\nStatus: install user installed\n' > "$MOCK_OPKG_STATUS"
printf '{"tag_name":"v1.3.0-beta.1","html_url":"https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.3.0-beta.1"}' > "$MOCK_CURL_DIR/get/latest"
out=$(cmd_update_check); assert_contains "$out" '"latest":""' "prerelease tag not offered"; assert_contains "$out" '"update_available":false' "prerelease not offered"

# 5. a malformed tag (path characters) is rejected the same way
printf '{"tag_name":"v1.2.0/../x","html_url":"https://github.com/RemoteToHome-io/gl-portable-backup/"}' > "$MOCK_CURL_DIR/get/latest"
out=$(cmd_update_check); assert_contains "$out" '"latest":""' "malformed tag rejected"; assert_contains "$out" '"update_available":false' "malformed tag not offered"

# 6. a release URL outside the project is dropped, the version still offered
printf '{"tag_name":"v1.2.0","html_url":"https://evil.example/releases"}' > "$MOCK_CURL_DIR/get/latest"
out=$(cmd_update_check); assert_contains "$out" '"release_url":""' "foreign url dropped"; assert_contains "$out" '"update_available":true' "still offered"

# 7. transport failure -> message, nothing offered, exit 0 (the UI shows the message)
out=$(MOCK_CURL_EXIT=7 sh -c '. "$0"; cmd_update_check' "$BACKEND"); rc=$?
assert_eq "$rc" 0 "update-check exits 0 on a transport failure"
assert_contains "$out" '"update_available":false' "nothing offered on failure"
assert_contains "$out" 'cannot reach the release server (curl exit 7)' "failure message"

# 8. newer release exists but the plugin is not installed via opkg -> not offered
: > "$MOCK_OPKG_STATUS"
printf '{"tag_name":"v1.2.0","html_url":"https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v1.2.0"}' > "$MOCK_CURL_DIR/get/latest"
out=$(cmd_update_check); assert_contains "$out" '"installed_via_opkg":false' "not via opkg"; assert_contains "$out" '"update_available":false' "not offered without opkg"; assert_contains "$out" '"latest":"1.2.0"' "latest still reported"

# 9. the dispatcher knows the subcommand and prints one JSON line
out=$(GPB_LIB_ONLY= sh "$BACKEND" update-check 2>/dev/null); rc=$?
assert_eq "$rc" 0 "dispatch exit code"
assert_eq "$(printf '%s\n' "$out" | wc -l)" "1" "one line of JSON"
echo "ok 41-update-check"
