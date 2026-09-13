#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }
R="$T/root"; : > "$R/usr/lib/oui-httpd/rpc/vlan_subnet"; : > "$R/usr/lib/oui-httpd/rpc/wifi"; : > "$R/usr/lib/oui-httpd/rpc/dns"
: > "$R/usr/lib/oui-httpd/rpc/timer"; : > "$R/usr/lib/oui-httpd/rpc/firewall"
: > "$R/usr/lib/oui-httpd/rpc/vpn-client"; : > "$R/usr/lib/oui-httpd/rpc/repeater"; : > "$R/usr/lib/oui-httpd/rpc/cloud"
printf 'root:$5$x:0:0:99999:7:::\n' > "$R/etc/shadow"
printf '{"id":1,"jsonrpc":"2.0","result":{"nonce":"n","hash-method":"sha256"}}' > "$MOCK_CURL_DIR/challenge.json"
printf '{"id":2,"jsonrpc":"2.0","result":{"sid":"S"}}' > "$MOCK_CURL_DIR/login.json"
printf '{"id":1,"jsonrpc":"2.0","result":{"subnets":[{"network":"lan","vlan_id":1}]}}' > "$MOCK_CURL_DIR/vlan_subnet.get_subnets.json"
printf '{"id":1,"jsonrpc":"2.0","result":{"res":[]}}' > "$MOCK_CURL_DIR/wifi.get_config.json"
# A result of its own may carry "error"/"message" fields — the reply is still data, and its body
# must never reach stderr (a wifi result body is SSIDs and keys).
printf '{"id":1,"jsonrpc":"2.0","result":{"enable":true,"error":0,"message":"not-an-error"}}' > "$MOCK_CURL_DIR/timer.get_led.json"
# A JSON-RPC error need not carry a message.
printf '{"id":1,"jsonrpc":"2.0","error":{"code":-32000}}' > "$MOCK_CURL_DIR/firewall.get_rule_list.json"
# Profile carries the user's VPN keys and saved-AP passwords by design, so both secret-bearing
# getters MUST be captured; cloud.get_config (the GoodCloud binding — device identity) MUST NOT be,
# even though its module is present and a reply is available.
printf '{"id":1,"jsonrpc":"2.0","result":{"tunnel":"wgclient1"}}' > "$MOCK_CURL_DIR/vpn-client.get_tunnel.json"
printf '{"id":1,"jsonrpc":"2.0","result":[{"name":"t","private_key":"FAKE-NOT-A-KEY"}]}' > "$MOCK_CURL_DIR/vpn-client.get_all_config_list.json"
printf '{"id":1,"jsonrpc":"2.0","result":[{"ssid":"neighbour","key":"FAKE-NOT-A-PASSWORD"}]}' > "$MOCK_CURL_DIR/repeater.get_saved_ap_list.json"
printf '{"id":1,"jsonrpc":"2.0","result":{"bind":true,"email":"FAKE-NOT-AN-EMAIL","username":"FAKE-NOT-A-USERNAME"}}' > "$MOCK_CURL_DIR/cloud.get_config.json"
out=$(capture_profile "$T/api" 2>&1)
assert_file "$T/api/vpn-client.get_tunnel.json"
assert_file "$T/api/vpn-client.get_all_config_list.json"
assert_file "$T/api/repeater.get_saved_ap_list.json"
assert_contains "$(cat "$T/api/vpn-client.get_all_config_list.json")" 'FAKE-NOT-A-KEY' "the whole VPN reply is stored"
assert_contains "$(cat "$T/api/repeater.get_saved_ap_list.json")" 'FAKE-NOT-A-PASSWORD' "the whole saved-AP reply is stored"
not_contains "$out" "vpn-client.get_all_config_list" "no WARNING names a captured getter"
not_contains "$out" "repeater.get_saved_ap_list" "no WARNING names a captured getter"
assert_no_file "$T/api/cloud.get_config.json"
assert_file "$T/api/vlan_subnet.get_subnets.json"; assert_no_file "$T/api/lan.get_config_list.json"
assert_contains "$(cat "$T/api/vlan_subnet.get_subnets.json")" '"vlan_id":1' "stored reply"
assert_contains "$out" "WARNING: dns.get_config" "error surfaced, not silenced"
assert_file "$T/api/timer.get_led.json"
not_contains "$out" "timer.get_led" "a result carrying an error field is data, not an error"
assert_contains "$out" "WARNING: firewall.get_rule_list" "error reply without a message still warns"
assert_no_file "$T/api/firewall.get_rule_list.json"

# An api/ directory comes out empty when the firmware ships none of the modules; the manifest's
# section list must then be empty rather than the unmatched glob.
rm -f "$R/usr/lib/oui-httpd/rpc/vlan_subnet" "$R/usr/lib/oui-httpd/rpc/wifi" "$R/usr/lib/oui-httpd/rpc/dns" \
      "$R/usr/lib/oui-httpd/rpc/timer" "$R/usr/lib/oui-httpd/rpc/firewall" \
      "$R/usr/lib/oui-httpd/rpc/vpn-client" "$R/usr/lib/oui-httpd/rpc/repeater" "$R/usr/lib/oui-httpd/rpc/cloud"
cat > "$R/etc/board.json" <<'JSON'
{"model":{"id":"glinet,mt3000-snand","name":"Test Router"},"network":{"lan":{"macaddr":"02:00:00:00:00:01"}},
 "system":{"label_macaddr":"02:00:00:00:00:01"}}
JSON
echo "4.11.0" > "$R/etc/glversion"
printf "DISTRIB_RELEASE='21.02.0'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$R/etc/openwrt_release"
echo 'system.@system[0].hostname=TESTHOST' >> "$MOCK_UCI_FILE"
mkdir -p "$T/out" "$T/x"
archive=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode profile --output "$T/out" 2>/dev/null)
assert_file "$archive"
tar -xzf "$archive" -C "$T/x"
assert_eq "$(jsonfilter -i "$T/x/gl-portable-backup/manifest.json" -e '@.sections')" "[]" "sections for an empty api dir"
echo "ok 19-profile-capture"
