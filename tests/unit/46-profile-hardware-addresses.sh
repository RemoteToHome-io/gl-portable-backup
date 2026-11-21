#!/bin/sh
# Profile archives carry no hardware address of the source router: every factory port address
# (cable.get_ports_config "defmacaddr"), every radio address (wifi.get_config "bssid") and every
# MAC-shaped value of /etc/board.json is removed from every stored API reply by value, in either
# letter case — including "macaddr" when the port is in the default MAC mode, where it equals the
# factory address. An address the user set that differs from the factory one stays, and so do DHCP
# reservations naming client devices. What cannot be removed is reported, never hidden.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

R="$T/root"
for m in vlan_subnet wifi cable netmode dns; do : > "$R/usr/lib/oui-httpd/rpc/$m"; done
printf 'root:$5$x:0:0:99999:7:::\n' > "$R/etc/shadow"
echo "4.11.0" > "$R/etc/glversion"
printf "DISTRIB_RELEASE='21.02.0'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$R/etc/openwrt_release"
echo 'system.@system[0].hostname=TESTHOST' >> "$MOCK_UCI_FILE"
printf '{"id":1,"jsonrpc":"2.0","result":{"nonce":"n","hash-method":"sha256"}}' > "$MOCK_CURL_DIR/challenge.json"
printf '{"id":2,"jsonrpc":"2.0","result":{"sid":"S"}}' > "$MOCK_CURL_DIR/login.json"
board() {
    cat > "$R/etc/board.json" <<'JSON'
{"model":{"id":"glinet,mt3000-snand","name":"Test Router"},
 "network":{"lan":{"macaddr":"94:83:c4:00:00:01"},"wan":{"macaddr":"94:83:c4:00:00:02"}},
 "system":{"label_macaddr":"94:83:c4:00:00:01"}}
JSON
}
board
# WAN in the default MAC mode: macaddr equals the factory address (upper case here, lower case in
# board.json). LAN with a cloned address the user chose: that one stays.
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"ports":[{"name":"wan","macaddr":{"mode":"f","macaddr":"94:83:C4:00:00:02","defmacaddr":"94:83:C4:00:00:02"}},{"name":"lan","macaddr":{"mode":"c","macaddr":"02:AA:BB:CC:DD:EE","defmacaddr":"94:83:C4:00:00:01"}}]}}' > "$MOCK_CURL_DIR/cable.get_ports_config.json"
# A radio address that is not in board.json, beside an SSID holding an escaped quote.
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"res":[{"ssid":"say \"hi\"","bssid":"94:83:C4:00:00:10","key":"k"}]}}' > "$MOCK_CURL_DIR/wifi.get_config.json"
# A board.json address under a field name of its own, in lower case.
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"mode":"router","wan_mac":"94:83:c4:00:00:02"}}' > "$MOCK_CURL_DIR/netmode.get_mode.json"
# A DHCP reservation names a client device: it stays.
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"static_bind_list":[{"mac":"AA:BB:CC:11:22:33","ip":"192.0.2.10","name":"laptop"}]}}' > "$MOCK_CURL_DIR/vlan_subnet.get_static_bind_list.json"
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"subnets":[{"network":"lan","vlan_id":1}]}}' > "$MOCK_CURL_DIR/vlan_subnet.get_subnets.json"

profile_archive() {   # outdir errfile -> extracts the archive into outdir/x, prints the manifest path
    mkdir -p "$1"
    a=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode profile --output "$1" 2>"$2") || { echo "  create failed: $(cat "$2")"; exit 1; }
    mkdir -p "$1/x"; tar -xzf "$a" -C "$1/x"
    echo "$1/x/gl-portable-backup/manifest.json"
}

# ─── 1. every hardware address goes, settings stay, the archive says it was checked ─
man=$(profile_archive "$T/o1" "$T/e1")
api="$T/o1/x/gl-portable-backup/api"
all=$(cat "$api"/*.json)
for mac in 94:83:C4:00:00:01 94:83:C4:00:00:02 94:83:C4:00:00:10; do
    if printf '%s' "$all" | command grep -q -i -F "$mac"; then echo "  hardware address $mac left in the API captures"; exit 1; fi
done
assert_contains "$(cat "$api/cable.get_ports_config.json")" '"macaddr":"02:AA:BB:CC:DD:EE"' "the user's cloned address stays"
assert_contains "$(cat "$api/cable.get_ports_config.json")" '"mode":"f"' "MAC mode stays"
assert_contains "$(cat "$api/vlan_subnet.get_static_bind_list.json")" 'AA:BB:CC:11:22:33' "client reservation stays"
assert_contains "$(cat "$api/wifi.get_config.json")" 'say \"hi\"' "SSID with an escaped quote stays"
assert_contains "$(cat "$api/netmode.get_mode.json")" '"mode":"router"' "other fields stay"
for f in "$api"/*.json; do jsonfilter -i "$f" -e '@' >/dev/null || { echo "  $(basename "$f") is no longer JSON"; exit 1; }; done
assert_eq "$(jsonfilter -i "$man" -e '@.identity_checked')" "true" "identity_checked"
assert_eq "$(jsonfilter -i "$man" -e '@.identity_residue')" "[]" "identity_residue empty"
e1=$(cat "$T/e1")
assert_contains "$e1" "factory and radio addresses" "create says what is removed"
not_contains "$e1" "WARNING: a hardware address" "no residue warning"
not_contains "$e1" "94:83" "no address printed"

# ─── 2. an address that cannot be removed is reported by file name, never by value ─
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"mode":"router","note":"gw-94:83:C4:00:00:01"}}' > "$MOCK_CURL_DIR/netmode.get_mode.json"
# A key holding an escaped quote: stripping by value would leave broken JSON, so the reply is kept.
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"a\"b":"94:83:C4:00:00:02"}}' > "$MOCK_CURL_DIR/dns.get_config.json"
man=$(profile_archive "$T/o2" "$T/e2")
api="$T/o2/x/gl-portable-backup/api"
e2=$(cat "$T/e2")
assert_contains "$e2" "  WARNING: a hardware address could not be removed from dns.get_config.json, netmode.get_mode.json" "residue named"
assert_contains "$e2" "dns.get_config.json would have left it unreadable" "parse failure named"
not_contains "$e2" "94:83" "no address printed"
jsonfilter -i "$api/dns.get_config.json" -e '@' >/dev/null || { echo "  dns.get_config.json was left broken"; exit 1; }
assert_eq "$(jsonfilter -i "$man" -e '@.identity_residue')" '["dns.get_config.json","netmode.get_mode.json"]' "identity_residue lists them"
assert_eq "$(jsonfilter -i "$man" -e '@.identity_checked')" "true" "still checked"

# ─── 3. ABSENT: no readable board.json means the archive was not checked, and says so ─
rm -f "$R/etc/board.json"
printf '%s' '{"id":1,"jsonrpc":"2.0","result":{"mode":"router"}}' > "$MOCK_CURL_DIR/netmode.get_mode.json"
rm -f "$MOCK_CURL_DIR/dns.get_config.json"
man=$(profile_archive "$T/o3" "$T/e3")
assert_contains "$(cat "$T/e3")" "  WARNING: hardware addresses could not be determined; this Profile archive was not checked for them" "absent warning"
assert_eq "$(jsonfilter -i "$man" -e '@.identity_checked')" "false" "identity_checked false"
# The addresses the replies themselves name as factory and radio addresses still go.
api="$T/o3/x/gl-portable-backup/api"
printf '%s' "$(cat "$api"/*.json)" | command grep -q -i -F '94:83:C4:00:00:10' && { echo "  bssid value left"; exit 1; }
board

# ─── 4. the two JSON helpers ─────────────────────────────────────────────────
sv() { printf '%s' "$1" > "$T/sv.json"; strip_json_string_value "$T/sv.json" "$2"; echo "rc=$?"; cat "$T/sv.json"; }
assert_eq "$(sv '{"a":"aa:bb:cc:dd:ee:ff","b":1}' AA:BB:CC:DD:EE:FF)" "$(printf 'rc=0\n{"b":1}')" "value, other case, first"
assert_eq "$(sv '{"b":1, "x" : "AA:BB:CC:DD:EE:FF"}' aa:bb:cc:dd:ee:ff)" "$(printf 'rc=0\n{"b":1}')" "value last, spaced"
assert_eq "$(sv '{"b":"AA:BB:CC:DD:EE:F0"}' AA:BB:CC:DD:EE:FF)" "$(printf 'rc=0\n{"b":"AA:BB:CC:DD:EE:F0"}')" "a different value stays"
assert_eq "$(sv '{"s":"x\",\"m\":\"AA:BB:CC:DD:EE:FF","k":1}' AA:BB:CC:DD:EE:FF)" "$(printf 'rc=0\n{"s":"x\\",\\"m\\":\\"AA:BB:CC:DD:EE:FF","k":1}')" "a value inside an escaped string is not a pair"
sf() { printf '%s' "$1" > "$T/sf.json"; strip_json_string_field "$T/sf.json" bssid; echo "rc=$?"; cat "$T/sf.json"; }
assert_eq "$(sf '{"bssid":"a\"b","x":1}')" "$(printf 'rc=0\n{"bssid":"a\\"b","x":1}')" "escaped quote in a value: pair left untouched"
assert_eq "$(sf '{"x":1,"bssid":"AA"}')" "$(printf 'rc=0\n{"x":1}')" "plain pair still removed"
echo "ok 46-profile-hardware-addresses"
