#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }
R="$T/root"; : > "$R/usr/lib/oui-httpd/rpc/vlan_subnet"; : > "$R/usr/lib/oui-httpd/rpc/wifi"; : > "$R/usr/lib/oui-httpd/rpc/dns"
: > "$R/usr/lib/oui-httpd/rpc/timer"; : > "$R/usr/lib/oui-httpd/rpc/firewall"
: > "$R/usr/lib/oui-httpd/rpc/vpn-client"; : > "$R/usr/lib/oui-httpd/rpc/repeater"; : > "$R/usr/lib/oui-httpd/rpc/cloud"
: > "$R/usr/lib/oui-httpd/rpc/system"
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
# system.get_info carries the serial number and the WAN MAC: device identity, never captured.
printf '{"id":1,"jsonrpc":"2.0","result":{"sn":"FAKE-NOT-A-SERIAL","mac":"02:00:00:00:00:99"}}' > "$MOCK_CURL_DIR/system.get_info.json"
# The radios' own addresses (bssid) and the port's factory address (defmacaddr) are hardware
# identity; the user's SSIDs and MAC-mode settings (macaddr) are not. Each field sits first,
# in the middle, last and (with spaces) loose in an object, and every object must stay valid.
: > "$R/usr/lib/oui-httpd/rpc/cable"
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"res":[{"bssid":"AA:AA:AA:AA:AA:01","ssid":"first-net"},{"ssid":"mid-net","bssid":"AA:AA:AA:AA:AA:02","key":"k2"},{"ssid":"last-net","bssid":"AA:AA:AA:AA:AA:03"},{"ssid":"spaced-net" , "bssid": "AA:AA:AA:AA:AA:04" , "key":"k4"}]}}' > "$MOCK_CURL_DIR/wifi.get_config.json"
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"ports":[{"name":"wan","macaddr":{"mode":"r","macaddr":"02:11:22:33:44:55","defmacaddr":"BB:BB:BB:BB:BB:01"}},{"name":"lan","macaddr":{"defmacaddr":"BB:BB:BB:BB:BB:02","mode":"f"}},{"name":"x","macaddr":{"defmacaddr": "BB:BB:BB:BB:BB:03"}}]}}' > "$MOCK_CURL_DIR/cable.get_ports_config.json"
out=$(capture_profile "$T/api" 2>&1)
assert_no_file "$T/api/system.get_info.json"
wifi_s=$(cat "$T/api/wifi.get_config.json"); cable_s=$(cat "$T/api/cable.get_ports_config.json")
not_contains "$wifi_s" "bssid" "radio addresses stripped"; not_contains "$wifi_s" "AA:AA:AA"
not_contains "$cable_s" "defmacaddr" "factory port addresses stripped"; not_contains "$cable_s" "BB:BB:BB"
for v in first-net mid-net last-net spaced-net '"key":"k2"' '"key":"k4"'; do assert_contains "$wifi_s" "$v" "wifi keeps $v"; done
assert_contains "$cable_s" '"macaddr":"02:11:22:33:44:55"' "MAC-mode setting kept"
assert_contains "$cable_s" '"mode":"f"' "port mode kept"
jsonfilter -i "$T/api/wifi.get_config.json" -e '@.result' >/dev/null || { echo "  stored wifi reply is not valid JSON"; exit 1; }
jsonfilter -i "$T/api/cable.get_ports_config.json" -e '@.result' >/dev/null || { echo "  stored cable reply is not valid JSON"; exit 1; }
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

# strip_json_string_field: removes every "FIELD":"value" pair with exactly one adjacent comma.
sf() { printf '%s' "$1" > "$T/sf.json"; strip_json_string_field "$T/sf.json" bssid; cat "$T/sf.json"; }
assert_eq "$(sf '{"bssid":"x","a":"1","b":"2"}')" '{"a":"1","b":"2"}' "field first"
assert_eq "$(sf '{"a":"1","bssid":"x","b":"2"}')" '{"a":"1","b":"2"}' "field middle"
assert_eq "$(sf '{"a":"1","b":"2","bssid":"x"}')" '{"a":"1","b":"2"}' "field last"
assert_eq "$(sf '{"bssid":"x"}')" '{}' "field alone"
assert_eq "$(sf '{"a":"1"}')" '{"a":"1"}' "field absent"
assert_eq "$(sf '[{"bssid":"x","a":"1"},{"a":"2","bssid":"y"}]')" '[{"a":"1"},{"a":"2"}]' "two occurrences"
assert_eq "$(sf '{"a":"1","bssid":"aa:bb:cc","b":"2"}')" '{"a":"1","b":"2"}' "value containing colons"
assert_eq "$(sf '{"a":"1" , "bssid" : "x" , "b":"2"}')" '{"a":"1" , "b":"2"}' "whitespace around colon and comma"
assert_eq "$(sf '{"mybssid":"keep","bssid":"x"}')" '{"mybssid":"keep"}' "a longer key is not matched"
strip_json_string_field "$T/does-not-exist.json" bssid || { echo "  missing file must be a no-op"; exit 1; }
assert_no_file "$T/does-not-exist.json"

# An api/ directory comes out empty when the firmware ships none of the modules; the manifest's
# section list must then be empty rather than the unmatched glob.
rm -f "$R/usr/lib/oui-httpd/rpc/vlan_subnet" "$R/usr/lib/oui-httpd/rpc/wifi" "$R/usr/lib/oui-httpd/rpc/dns" \
      "$R/usr/lib/oui-httpd/rpc/timer" "$R/usr/lib/oui-httpd/rpc/firewall" \
      "$R/usr/lib/oui-httpd/rpc/vpn-client" "$R/usr/lib/oui-httpd/rpc/repeater" "$R/usr/lib/oui-httpd/rpc/cloud" "$R/usr/lib/oui-httpd/rpc/cable" "$R/usr/lib/oui-httpd/rpc/system"
cat > "$R/etc/board.json" <<'JSON'
{"model":{"id":"glinet,mt3000-snand","name":"Test Router"},"network":{"lan":{"macaddr":"02:00:00:00:00:01"}},
 "system":{"label_macaddr":"02:00:00:00:00:01"}}
JSON
echo "4.11.0" > "$R/etc/glversion"
printf "DISTRIB_RELEASE='21.02.0'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$R/etc/openwrt_release"
echo 'system.@system[0].hostname=TESTHOST' >> "$MOCK_UCI_FILE"
mkdir -p "$T/out" "$T/x"
archive=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode profile --output "$T/out" 2>"$T/profile.err")
assert_file "$archive"
tar -xzf "$archive" -C "$T/x"
assert_no_file "$T/x/gl-portable-backup/hardware.json"
not_contains "$(tar -tzf "$archive")" "hardware.json" "profile archive lists no hardware.json"
not_contains "$(cat "$T/profile.err")" "Captured hardware identity" "profile does not claim to capture identity"
assert_contains "$(cat "$T/profile.err")" "  Profile mode: device identity (hardware IDs, serial) is not captured" "profile says so"
assert_eq "$(jsonfilter -i "$T/x/gl-portable-backup/manifest.json" -e '@.sections')" "[]" "sections for an empty api dir"
echo "ok 19-profile-capture"
