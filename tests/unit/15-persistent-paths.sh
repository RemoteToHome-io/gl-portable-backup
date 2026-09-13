#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
R="$T/root"; mkdir -p "$R/etc/openvpn/cert" "$R/var/lib/tor/keys" "$R/etc/config" "$R/etc/extra"
echo k > "$R/etc/openvpn/cert/ca.key"; echo t > "$R/var/lib/tor/keys/ed"; echo d > "$R/etc/dnsmasq.conf"; echo s > "$R/etc/shadow"; echo h > "$R/etc/hosts"
echo e > "$R/etc/extra/keep.conf"
printf '/etc/openvpn/\n' > "$R/lib/upgrade/keep.d/openvpn"; printf '/var/lib/tor/keys/*\n' > "$R/lib/upgrade/keep.d/tor"
printf '# comment\n/etc/config/gl_nas/\n/etc/extra/\n' > "$R/etc/sysupgrade.conf"
printf '/etc/dnsmasq.conf\n/etc/shadow\n' > "$MOCK_OPKG_CONFFILES"
paths=$(enumerate_persistent_paths | tr '\n' ' ')
assert_contains "$paths" "/etc/openvpn/cert/ca.key" keepd-dir
assert_contains "$paths" "/var/lib/tor/keys/ed" keepd-glob
assert_contains "$paths" "/etc/extra/keep.conf" sysupgrade-conf
assert_contains "$paths" "/etc/dnsmasq.conf" conffile
mkdir -p "$T/full" "$T/clone"
capture_extra_files "$T/full" full >/dev/null; capture_extra_files "$T/clone" clone >/dev/null
assert_file "$T/full/extra/etc/shadow"; assert_no_file "$T/clone/extra/etc/shadow"; assert_file "$T/clone/extra/etc/dnsmasq.conf"
# An unreadable directory makes find exit 1; that must not truncate the rest of the list. Run the
# backend in a sub-shell so its own set -e is live (load_backend turns it off — see tests/lib.sh).
# Skipped as root, for whom mode 000 is no obstacle and the check would be vacuous.
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$R/etc/locked/inner"; echo l > "$R/etc/locked/inner/f"
    printf '/etc/locked/\n' > "$R/lib/upgrade/keep.d/aaa-locked"   # sorts before openvpn
    chmod 000 "$R/etc/locked/inner"
    out=$(sh -c '. "$0"; enumerate_persistent_paths' "$BACKEND" 2>/dev/null)
    chmod 755 "$R/etc/locked/inner"
    assert_contains "$out" "/etc/openvpn/cert/ca.key" errexit-guard
fi
echo "ok 15-persistent-paths"
