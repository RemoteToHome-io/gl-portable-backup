#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
R="$T/root"; mkdir -p "$R/etc/netifyd" "$R/rom/etc/gl_crontabs/crontabs.d" "$R/etc/gl_crontabs/crontabs.d" "$R/usr/bin"
is_firmware_owned /etc/netifyd/agent.uuid && a=yes || a=no; assert_eq "$a" yes netifyd
is_firmware_owned /usr/bin/ts-fix-ks && b=yes || b=no; assert_eq "$b" yes plugin-binary
GPB_INCLUDE_PLUGINS=1 is_firmware_owned /usr/bin/ts-fix-ks && c=yes || c=no; assert_eq "$c" no plugin-optin
is_firmware_owned /etc/dropbear/authorized_keys && d=yes || d=no; assert_eq "$d" no user-file
echo same > "$R/etc/gl_crontabs/crontabs.d/auto_timezone"; echo same > "$R/rom/etc/gl_crontabs/crontabs.d/auto_timezone"
is_rom_identical /etc/gl_crontabs/crontabs.d/auto_timezone && e=yes || e=no; assert_eq "$e" yes rom-identical
echo "ok 16-firmware-owned"
