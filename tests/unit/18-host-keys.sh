#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
mkdir -p "$T/x/extra/etc/dropbear"; echo key > "$T/x/extra/etc/dropbear/dropbear_ed25519_host_key"; echo ak > "$T/x/extra/etc/dropbear/authorized_keys"
assert_contains "$(archive_hostkey_fingerprint "$T/x")" "SHA256:MOCKFINGERPRINT" fingerprint
GPB_KEEP_HOST_KEYS=1 restore_extra_files "$T/x" >/dev/null
assert_no_file "$T/root/etc/dropbear/dropbear_ed25519_host_key"; assert_file "$T/root/etc/dropbear/authorized_keys"
echo "ok 18-host-keys"
