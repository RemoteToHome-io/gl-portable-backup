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
echo "ok 11-auth-failure"
