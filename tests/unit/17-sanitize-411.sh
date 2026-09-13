#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
C="$T/c"; mkdir -p "$C"
printf "config wifi-iface 'wifi2g'\n\toption factory_macaddr '94:83:c4:00:00:82'\n\toption macaddr '0A:1C:6E:78:4E:02'\n\toption key 'psk'\n" > "$C/wireless"
printf "config main\n\toption macaddr '92:83:c4:00:00:82'\nconfig network\n\toption macaddr 'r,1A:C1:FA:80:7A:95'\n\toption key 'k'\n" > "$C/repeater"
printf "config port 'wan'\n\toption default_mac '94:83:c4:00:00:80'\n\toption mode 'wan'\n" > "$C/eth_ports_config_map"
# zerotier.gl.secret is the node's private identity, mirrored into UCI on firmware 4.9+. The join
# ID says which network to join — deployment config, and the point of cloning.
printf "config zerotier 'gl'\n\toption secret 'PRIVATE-NODE-IDENTITY'\n\toption join 'abcdef0123456789'\n" > "$C/zerotier"
sanitize_configs "$C"
assert_eq "$(grep -c 'option secret' "$C/zerotier")" 0 "ZT node secret stripped"
assert_eq "$(grep -c 'option join' "$C/zerotier")" 1 "ZT join ID kept (deployment config)"
assert_eq "$(grep -c -E 'option (factory_macaddr|macaddr|default_mac)' "$C/wireless" "$C/repeater" "$C/eth_ports_config_map" | awk -F: '{s+=$2} END{print s}')" 0 "all identity MACs stripped"
assert_eq "$(grep -c "option key" "$C/wireless")" 1 "wifi key kept (deployment config)"
echo "ok 17-sanitize-411"
