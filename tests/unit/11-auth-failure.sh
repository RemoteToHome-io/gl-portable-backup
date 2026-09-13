#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
# curl unreachable
out=$( MOCK_CURL_EXIT=7 sh -c '. "$0"; capture_profile "$1"' "$BACKEND" "$T/api" 2>&1 ); rc=$?
assert_eq "$rc" 1 "exit code"
assert_contains "$out" "ERROR: Failed to authenticate" "loud error"
assert_contains "$out" "curl exit 7" "reason"
# login refused
printf '{"id":1,"jsonrpc":"2.0","result":{"nonce":"n","hash-method":"sha256"}}' > "$MOCK_CURL_DIR/challenge.json"
printf '{"id":2,"jsonrpc":"2.0","error":{"code":-32000,"message":"login failed"}}' > "$MOCK_CURL_DIR/login.json"
printf 'root:$5$x:0:0:99999:7:::\n' > "$T/root/etc/shadow"
out=$( GPB_LIB_ONLY=1 GPB_ROOT="$T/root" sh -c '. "$0"; capture_profile "$1"' "$BACKEND" "$T/api" 2>&1 ); rc=$?
assert_eq "$rc" 1 "exit code (login refused)"
assert_contains "$out" "login refused" "reason (login refused)"
# no password hash (shadow file missing)
rm -f "$T/root/etc/shadow"
out=$( GPB_LIB_ONLY=1 GPB_ROOT="$T/root" sh -c '. "$0"; capture_profile "$1"' "$BACKEND" "$T/api" 2>&1 ); rc=$?
assert_eq "$rc" 1 "exit code (no shadow hash)"
assert_contains "$out" "no password hash" "reason (no shadow hash)"
# reinitialize_ddns non-fatal tail: auth fails but preference re-apply + service restart still run
mkdir -p "$T/x/config"
echo "config gl_ddns 'glddns'" > "$T/x/config/gl_ddns"
out=$( MOCK_CURL_EXIT=7 sh -c '. "$0"; reinitialize_ddns "$1"' "$BACKEND" "$T/x" 2>&1 ); rc=$?
assert_eq "$rc" 0 "exit code (ddns non-fatal)"
assert_contains "$out" "WARNING: local API auth failed" "ddns warning"
assert_contains "$out" "DDNS operational preferences restored" "ddns tail still runs"
assert_contains "$(cat "$MOCK_UCI_LOG")" "commit gl_ddns" "ddns commit still runs"
# restore_profile fatal path
mkdir -p "$T/y/api"
out=$( MOCK_CURL_EXIT=7 sh -c '. "$0"; restore_profile "$1"' "$BACKEND" "$T/y" 2>&1 ); rc=$?
assert_eq "$rc" 1 "exit code (restore_profile)"
assert_contains "$out" "ERROR: Failed to authenticate" "loud error (restore_profile)"
# A failing API write must warn, not abort the restore half-way: an unguarded simple command under
# set -e would exit after the configs were written and before the preference re-apply, the uci
# commit, the service restart and (in Remote-Safe) the preserved-config copy-back.
printf '{"id":1,"jsonrpc":"2.0","result":{"nonce":"n","hash-method":"sha256"}}' > "$MOCK_CURL_DIR/challenge.json"
printf '{"id":2,"jsonrpc":"2.0","result":{"sid":"S"}}' > "$MOCK_CURL_DIR/login.json"
printf 'root:$5$x:0:0:99999:7:::\n' > "$T/root/etc/shadow"
out=$( MOCK_CURL_FAIL_KEY=ddns.set_config sh -c '. "$0"; reinitialize_ddns "$1"' "$BACKEND" "$T/x" 2>&1 ); rc=$?
assert_eq "$rc" 0 "exit code (failing API write is not fatal)"
assert_contains "$out" "WARNING: ddns.set_config failed" "failing write surfaced"
assert_contains "$out" "DDNS operational preferences restored" "tail still runs after a failing write"
# The same call with the mock not primed to fail must NOT warn — otherwise the check above would
# pass for an instrument that always warns.
out=$( sh -c '. "$0"; reinitialize_ddns "$1"' "$BACKEND" "$T/x" 2>&1 ); rc=$?
assert_eq "$rc" 0 "exit code (successful API write)"
case "$out" in *"WARNING: ddns.set_config failed"*) echo "  warning printed for a successful write"; exit 1 ;; esac
echo "ok 11-auth-failure"
