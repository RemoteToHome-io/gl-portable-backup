#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
printf '{"id":1,"jsonrpc":"2.0","result":{"ok":true}}' > "$MOCK_CURL_DIR/mod.meth.json"
gl_api SID mod meth >/dev/null
gl_api SID mod meth '{}' >/dev/null
gl_api SID mod meth '{"a":1}' >/dev/null
assert_eq "$(sed -n 1p "$MOCK_CURL_LOG")" '{"jsonrpc":"2.0","id":1,"method":"call","params":["SID","mod","meth",{}]}' "no params"
assert_eq "$(sed -n 2p "$MOCK_CURL_LOG")" '{"jsonrpc":"2.0","id":1,"method":"call","params":["SID","mod","meth",{}]}' "explicit {}"
assert_eq "$(sed -n 3p "$MOCK_CURL_LOG")" '{"jsonrpc":"2.0","id":1,"method":"call","params":["SID","mod","meth",{"a":1}]}' "payload"
echo "ok 10-gl_api-params"
