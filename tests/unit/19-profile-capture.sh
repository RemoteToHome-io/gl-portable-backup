#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
R="$T/root"; : > "$R/usr/lib/oui-httpd/rpc/vlan_subnet"; : > "$R/usr/lib/oui-httpd/rpc/wifi"; : > "$R/usr/lib/oui-httpd/rpc/dns"
printf 'root:$5$x:0:0:99999:7:::\n' > "$R/etc/shadow"
printf '{"id":1,"jsonrpc":"2.0","result":{"nonce":"n","hash-method":"sha256"}}' > "$MOCK_CURL_DIR/challenge.json"
printf '{"id":2,"jsonrpc":"2.0","result":{"sid":"S"}}' > "$MOCK_CURL_DIR/login.json"
printf '{"id":1,"jsonrpc":"2.0","result":{"subnets":[{"network":"lan","vlan_id":1}]}}' > "$MOCK_CURL_DIR/vlan_subnet.get_subnets.json"
printf '{"id":1,"jsonrpc":"2.0","result":{"res":[]}}' > "$MOCK_CURL_DIR/wifi.get_config.json"
out=$(capture_profile "$T/api" 2>&1)
assert_file "$T/api/vlan_subnet.get_subnets.json"; assert_no_file "$T/api/lan.get_config_list.json"
assert_contains "$(cat "$T/api/vlan_subnet.get_subnets.json")" '"vlan_id":1' "stored reply"
assert_contains "$out" "WARNING: dns.get_config" "error surfaced, not silenced"
echo "ok 19-profile-capture"
