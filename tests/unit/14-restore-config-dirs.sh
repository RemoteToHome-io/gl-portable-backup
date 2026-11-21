#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
mkdir -p "$T/a/config/cellular" && echo x > "$T/a/config/network" && echo y > "$T/a/config/cellular/slot_map.json" && echo z > "$T/a/config/.plugins.uci-tmp"
n=$(restore_config_tree "$T/a/config")
assert_eq "$n" 2 "files copied (the hidden entry is not restored)"
assert_file "$T/root/etc/config/cellular/slot_map.json"; assert_no_file "$T/root/etc/config/.plugins.uci-tmp"; assert_file "$T/root/etc/config/network"
echo "ok 14-restore-config-dirs"
