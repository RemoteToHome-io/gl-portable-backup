#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
R="$T/root"; mkdir -p "$R/etc/openvpn/cert" "$R/var/lib/tor/keys" "$R/etc/config"
echo k > "$R/etc/openvpn/cert/ca.key"; echo t > "$R/var/lib/tor/keys/ed"; echo d > "$R/etc/dnsmasq.conf"; echo s > "$R/etc/shadow"; echo h > "$R/etc/hosts"
printf '/etc/openvpn/\n' > "$R/lib/upgrade/keep.d/openvpn"; printf '/var/lib/tor/keys/*\n' > "$R/lib/upgrade/keep.d/tor"
printf '# comment\n/etc/config/gl_nas/\n' > "$R/etc/sysupgrade.conf"
printf '/etc/dnsmasq.conf\n/etc/shadow\n' > "$MOCK_OPKG_CONFFILES"
paths=$(enumerate_persistent_paths | tr '\n' ' ')
assert_contains "$paths" "/etc/openvpn/cert/ca.key" keepd-dir
assert_contains "$paths" "/var/lib/tor/keys/ed" keepd-glob
assert_contains "$paths" "/etc/dnsmasq.conf" conffile
mkdir -p "$T/full" "$T/clone"
capture_extra_files "$T/full" full >/dev/null; capture_extra_files "$T/clone" clone >/dev/null
assert_file "$T/full/extra/etc/shadow"; assert_no_file "$T/clone/extra/etc/shadow"; assert_file "$T/clone/extra/etc/dnsmasq.conf"
echo "ok 15-persistent-paths"
