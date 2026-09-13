#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
D="$T/api"; mkdir -p "$D"
# Format 3 archive: one file per setting.
printf '{"result":{"led_enable":true}}' > "$D/led.json"
assert_eq "$(api_file "$D" led.get_config.json led.json)" "$D/led.json" "format 3 name"
# Format 4 archive: one file per API call. The new name wins when an archive carries both.
printf '{"result":{"led_enable":false}}' > "$D/led.get_config.json"
assert_eq "$(api_file "$D" led.get_config.json led.json)" "$D/led.get_config.json" "new name preferred"
rm -f "$D/led.json"
assert_eq "$(api_file "$D" led.get_config.json led.json)" "$D/led.get_config.json" "format 4 name"
# Neither name present: no output, no failure.
out=$(api_file "$D" timer.get_led.json timer_led.json); rc=$?
assert_eq "$rc" 0 "exit code when neither name is present"
assert_eq "$out" "" "output when neither name is present"
# Module markers: a bare module file, a .so module, and one that is absent.
: > "$T/root/usr/lib/oui-httpd/rpc/vlan_subnet"
: > "$T/root/usr/lib/oui-httpd/rpc/ddns.so"
api_module_present vlan_subnet || { echo "  assert FAILED: bare module marker not detected"; exit 1; }
api_module_present ddns || { echo "  assert FAILED: .so module marker not detected"; exit 1; }
api_module_present lan && { echo "  assert FAILED: absent module reported present"; exit 1; }
echo "ok 20-profile-format-compat"
