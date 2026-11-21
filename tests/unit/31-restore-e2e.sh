#!/bin/sh
# End-to-end cmd_restore of a Full archive: what it overwrites beyond configuration — the source
# unit's SSH host keys and its root password — is announced before anything is written, and
# --keep-host-keys opts out of the host keys without holding back authorized_keys.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

# ─── Source unit A ────────────────────────────────────────────────────────────
A="$T/root"
mkdir -p "$A/etc/config" "$A/etc/dropbear" "$A/usr/lib/opkg" "$A/lib/upgrade/keep.d"
cat > "$A/etc/board.json" <<'JSON'
{"model":{"id":"glinet,mt3000-snand","name":"Test Router"},
 "network":{"lan":{"macaddr":"02:00:00:00:00:01"},"wan":{"macaddr":"02:00:00:00:00:02"}},
 "system":{"label_macaddr":"02:00:00:00:00:01"}}
JSON
echo "4.11.0" > "$A/etc/glversion"
printf "DISTRIB_RELEASE='21.02.0'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$A/etc/openwrt_release"
printf 'Package: pkg-user\nVersion: 1.0-1\nStatus: install user installed\n\n' > "$A/usr/lib/opkg/status"
echo 'system.@system[0].hostname=SOURCEHOST' >> "$MOCK_UCI_FILE"
echo "config interface 'lan'" > "$A/etc/config/network"
printf '/etc/dropbear/\n' > "$A/lib/upgrade/keep.d/dropbear"
printf '/etc/shadow\n' > "$A/lib/upgrade/keep.d/base-files-essential"
echo SOURCE-HOST-KEY > "$A/etc/dropbear/dropbear_ed25519_host_key"
echo SOURCE-AUTH-KEY > "$A/etc/dropbear/authorized_keys"
echo 'root:SOURCEHASH:1::::::' > "$A/etc/shadow"

# Sub-shell form so the backend's own set -e is live, and so each cmd_*'s EXIT trap stays out of
# this shell (load_backend turns set -e off and lib.sh owns the EXIT trap — see tests/lib.sh).
mkdir -p "$T/out"
archive=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --output "$T/out" 2>"$T/create.err"); rc=$?
assert_eq "$rc" 0 "cmd_create exit code"
listing=$(tar -tzf "$archive")
assert_contains "$listing" "extra/etc/dropbear/dropbear_ed25519_host_key" "host key captured"
assert_contains "$listing" "extra/etc/dropbear/authorized_keys" "authorized_keys captured"
assert_contains "$listing" "extra/etc/shadow" "shadow captured"

# ─── Target unit B: plain restore replaces identity, and says so ──────────────
B="$T/b"
mkdir -p "$B/etc/config" "$B/etc/dropbear"
cp "$A/etc/board.json" "$B/etc/board.json"; echo "4.11.0" > "$B/etc/glversion"
echo TARGET-HOST-KEY > "$B/etc/dropbear/dropbear_ed25519_host_key"
echo 'root:TARGETHASH:1::::::' > "$B/etc/shadow"

out=$(GPB_ROOT="$B" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$archive" 2>"$T/err"); rc=$?
assert_eq "$rc" 0 "cmd_restore exit code"
assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "RESTORE_OK" "RESTORE_OK is the last stdout line"
err=$(cat "$T/err")
assert_contains "$err" "WARNING: this archive restores the source's SSH host keys" "host-key warning"
assert_contains "$err" "SHA256:MOCKFINGERPRINT" "expected fingerprint shown"
assert_contains "$err" "WARNING: this archive restores /etc/shadow" "root-password warning"
assert_eq "$(cat "$B/etc/dropbear/dropbear_ed25519_host_key")" "SOURCE-HOST-KEY" "host key replaced"
assert_eq "$(cat "$B/etc/shadow")" "root:SOURCEHASH:1::::::" "shadow replaced"

# ─── Target unit B2: --keep-host-keys keeps identity, restores authorized_keys ─
B2="$T/b2"
mkdir -p "$B2/etc/config" "$B2/etc/dropbear"
cp "$A/etc/board.json" "$B2/etc/board.json"; echo "4.11.0" > "$B2/etc/glversion"
echo TARGET2-HOST-KEY > "$B2/etc/dropbear/dropbear_ed25519_host_key"

out2=$(GPB_ROOT="$B2" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" --keep-host-keys "$archive" 2>"$T/err2"); rc=$?
assert_eq "$rc" 0 "cmd_restore exit code (--keep-host-keys)"
assert_eq "$(printf '%s\n' "$out2" | tail -n 1)" "RESTORE_OK" "RESTORE_OK (--keep-host-keys)"
err2=$(cat "$T/err2")
assert_contains "$err2" "Keeping this device's SSH host keys" "keep notice"
not_contains "$err2" "WARNING: this archive restores the source's SSH host keys" "no host-key warning when kept"
assert_eq "$(cat "$B2/etc/dropbear/dropbear_ed25519_host_key")" "TARGET2-HOST-KEY" "host key kept"
assert_eq "$(cat "$B2/etc/dropbear/authorized_keys")" "SOURCE-AUTH-KEY" "authorized_keys still restored"

# ─── inspect and fingerprint report the same two facts ────────────────────────
insp=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$archive"); rc=$?
assert_eq "$rc" 0 "cmd_inspect exit code"
assert_contains "$insp" '"restores_ssh_host_keys": true' "inspect reports host keys"
assert_contains "$insp" '"restores_root_password": true' "inspect reports root password"
fp=$(sh -c '. "$0"; cmd_fingerprint "$@"' "$BACKEND" "$archive"); rc=$?
assert_eq "$rc" 0 "cmd_fingerprint exit code"
assert_contains "$fp" "SHA256:MOCKFINGERPRINT" "fingerprint subcommand"

# The flag-appending rewrite needs an opening line, a line to carry the comma, and the closing
# brace. A manifest in any other layout could hide the appended keys, so inspect refuses it, and
# restore refuses it before anything is written.
mkdir -p "$T/tiny/gl-portable-backup"
printf '{\n}\n' > "$T/tiny/gl-portable-backup/manifest.json"
tar -czf "$T/tiny.tar.gz" -C "$T/tiny" gl-portable-backup
rc=0; tinyinsp=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$T/tiny.tar.gz" 2>"$T/tiny.err") || rc=$?
assert_eq "$rc" 1 "cmd_inspect exit code (two-line manifest)"
assert_eq "$tinyinsp" "" "nothing printed for a two-line manifest"
assert_contains "$(cat "$T/tiny.err")" "Invalid archive: manifest.json is not in the layout this tool writes" "two-line manifest refused"
BT="$T/btiny"; mkdir -p "$BT/etc/config"; cp "$A/etc/board.json" "$BT/etc/board.json"
rc=0; GPB_ROOT="$BT" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$T/tiny.tar.gz" >/dev/null 2>"$T/tiny.err" || rc=$?
assert_eq "$rc" 1 "cmd_restore exit code (two-line manifest)"
assert_contains "$(cat "$T/tiny.err")" "Invalid archive: manifest.json is not in the layout this tool writes" "restore refuses it too"

# A Clone archive carries neither: host keys and /etc/shadow are stripped at capture time.
mkdir -p "$T/outc"
clone=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode clone --output "$T/outc" 2>/dev/null); rc=$?
assert_eq "$rc" 0 "cmd_create exit code (clone)"
cinsp=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$clone")
assert_contains "$cinsp" '"restores_ssh_host_keys": false' "clone: no host keys"
assert_contains "$cinsp" '"restores_root_password": false' "clone: no root password"
cfp=$(sh -c '. "$0"; cmd_fingerprint "$@"' "$BACKEND" "$clone"); rc=$?
assert_eq "$rc" 0 "cmd_fingerprint exit code (no host keys)"
assert_eq "$cfp" "" "fingerprint prints nothing when the archive has no host keys"

# Remote-Safe end to end. This release does not re-add the target's ZeroTier/Tailscale sections
# inside network and firewall, and the operator has to hear that before anything is written —
# it is the mode whose promise is "don't cut off the tunnel you are connected through".
mkdir -p "$T/outrs"
rsarch=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode remote-safe --output "$T/outrs" 2>/dev/null); rc=$?
assert_eq "$rc" 0 "cmd_create exit code (remote-safe)"
B3="$T/b3"; mkdir -p "$B3/etc/config"
cp "$A/etc/board.json" "$B3/etc/board.json"; echo "4.11.0" > "$B3/etc/glversion"
out3=$(GPB_ROOT="$B3" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$rsarch" 2>"$T/err3"); rc=$?
assert_eq "$rc" 0 "cmd_restore exit code (remote-safe)"
assert_eq "$(printf '%s\n' "$out3" | tail -n 1)" "RESTORE_OK" "RESTORE_OK (remote-safe)"
assert_contains "$(cat "$T/err3")" \
    "ZeroTier/Tailscale interface, zone and forwarding sections are NOT re-added" \
    "remote-safe limitation announced"
# The notice belongs to Remote-Safe alone — a Full restore must not print it.
not_contains "$err" "sections are NOT re-added" "no remote-safe notice on a full restore"
echo "ok 31-restore-e2e"
