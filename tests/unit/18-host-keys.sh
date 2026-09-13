#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
mkdir -p "$T/x/extra/etc/dropbear"; echo key > "$T/x/extra/etc/dropbear/dropbear_ed25519_host_key"; echo ak > "$T/x/extra/etc/dropbear/authorized_keys"
assert_contains "$(archive_hostkey_fingerprint "$T/x")" "SHA256:MOCKFINGERPRINT" fingerprint
GPB_KEEP_HOST_KEYS=1 restore_extra_files "$T/x" >/dev/null
assert_no_file "$T/root/etc/dropbear/dropbear_ed25519_host_key"; assert_file "$T/root/etc/dropbear/authorized_keys"

# A captured name holding a space or a glob character must survive the restore loop intact. The
# pre-1.1 `for f in $(find …)` form word-split the first and pathname-expanded the second, so the
# copy failed part-way through and the count counted the fragments.
mkdir -p "$T/x/extra/etc/awkward"
echo one > "$T/x/extra/etc/awkward/my file.conf"
echo two > "$T/x/extra/etc/awkward/star*.conf"
count=$(GPB_KEEP_HOST_KEYS=1 restore_extra_files "$T/x")
assert_file "$T/root/etc/awkward/my file.conf"
assert_file "$T/root/etc/awkward/star*.conf"
assert_eq "$count" 3 "restored count (authorized_keys + two awkward names; host key skipped)"
echo "ok 18-host-keys"
