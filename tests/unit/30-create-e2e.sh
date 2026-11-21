#!/bin/sh
# End-to-end cmd_create: what lands in the archive, what the operator is told, what backup-info says.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

R="$T/root"
mkdir -p "$R/etc/config" "$R/etc/config/gl_nas" "$R/etc/userconf" "$R/etc/netifyd" \
         "$R/etc/gl_crontabs/crontabs.d" "$R/etc/tailscale" \
         "$R/rom/etc/gl_crontabs/crontabs.d" "$R/usr/bin" "$R/usr/lib/opkg" "$R/lib/upgrade/keep.d"
cat > "$R/etc/board.json" <<'JSON'
{"model":{"id":"glinet,mt3000-snand","name":"Test Router"},
 "network":{"lan":{"macaddr":"02:00:00:00:00:01"},"wan":{"macaddr":"02:00:00:00:00:02"}},
 "system":{"label_macaddr":"02:00:00:00:00:01"}}
JSON
echo "4.11.0" > "$R/etc/glversion"
printf "DISTRIB_RELEASE='21.02.0'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$R/etc/openwrt_release"
printf 'Package: pkg-user\nVersion: 1.0-1\nStatus: install user installed\n\n' > "$R/usr/lib/opkg/status"
echo "config interface 'lan'" > "$R/etc/config/network"
echo "config interface 'lan'" > "$R/etc/config/network-opkg"   # opkg conffile backup, not user config
echo 'system.@system[0].hostname=TESTHOST' >> "$MOCK_UCI_FILE"
printf '/etc/userconf/\n/usr/bin/plugin-bin\n' > "$R/lib/upgrade/keep.d/fixture"
printf '/etc/netifyd/\n/etc/gl_crontabs/crontabs.d/\n/etc/tailscale/\n' >> "$R/lib/upgrade/keep.d/fixture"
echo tsnodekey > "$R/etc/tailscale/tailscaled.state"              # node identity  -> full only
echo webdavkey > "$R/etc/config/gl_nas/ssl_webdav.pem"            # TLS key        -> full only
echo conf > "$R/etc/userconf/a.conf"                              # user config      -> captured
echo bin  > "$R/usr/bin/plugin-bin"                               # plugin binary    -> skipped
echo uuid > "$R/etc/netifyd/agent.uuid"                           # firmware-owned   -> skipped
echo same > "$R/etc/gl_crontabs/crontabs.d/auto_timezone"         # identical to /rom -> skipped
echo same > "$R/rom/etc/gl_crontabs/crontabs.d/auto_timezone"
echo mine > "$R/etc/gl_crontabs/crontabs.d/user_job"              # edited by the user -> captured
echo stock > "$R/rom/etc/gl_crontabs/crontabs.d/user_job"

# A quote or a backslash in free text ends the JSON string it sits in, leaving a manifest no
# restore can parse — the failure surfaces later as a bogus "Model mismatch. Backup: ,".
assert_eq "$(json_escape 'a"b\c')" 'a\"b\\c' "json_escape quotes and backslashes"

# Sub-shell form so the backend's own set -e is live (load_backend turns it off — see tests/lib.sh).
mkdir -p "$T/out"
NOTES='say "hi" \ there'
archive=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --notes "$NOTES" --output "$T/out" 2>"$T/err"); rc=$?
assert_eq "$rc" 0 "cmd_create exit code"
case "$archive" in
    "$T/out"/gl-backup-full-TESTHOST-MT3000-fw4-11-0-*.tar.gz) ;;
    *) echo "  archive name FAILED: $archive"; exit 1 ;;
esac
assert_file "$archive"

listing=$(tar -tzf "$archive")
assert_contains "$listing" "gl-portable-backup/hardware.json" "full still carries hardware.json"
assert_contains "$(cat "$T/err")" "Captured hardware identity" "full still reports it"
assert_contains "$listing" "gl-portable-backup/extra/etc/userconf/a.conf" "user file captured"
assert_contains "$listing" "gl-portable-backup/extra/etc/gl_crontabs/crontabs.d/user_job" "edited file captured"
assert_contains "$listing" "gl-portable-backup/config/network" "config copied"
not_contains "$listing" "plugin-bin" "plugin binary excluded"
not_contains "$listing" "agent.uuid" "firmware-owned excluded"
not_contains "$listing" "auto_timezone" "rom-identical excluded"
not_contains "$listing" "network-opkg" "opkg conffile backup excluded"
assert_contains "$listing" "gl-portable-backup/extra/etc/tailscale/tailscaled.state" "full keeps Tailscale state"
assert_contains "$listing" "gl-portable-backup/config/gl_nas/ssl_webdav.pem" "full keeps the WebDAV TLS key"

err=$(cat "$T/err")
assert_contains "$err" "Captured 3 extra persistent files" "captured count"
assert_contains "$err" "Skipped 2 firmware-owned, 1 identical to /rom" "skipped counts"
mkdir -p "$T/x"; tar -xzf "$archive" -C "$T/x" gl-portable-backup/backup-info.txt
assert_contains "$(cat "$T/x/gl-portable-backup/backup-info.txt")" \
    "Skipped:    2 firmware-owned, 1 identical to /rom" "backup-info skipped line"

# The manifest still parses, and the note round-trips through it unchanged.
insp=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$archive"); rc=$?
assert_eq "$rc" 0 "cmd_inspect exit code (escaped notes)"
printf '%s' "$insp" | python3 -m json.tool >/dev/null 2>&1 \
    || { echo "  manifest is not valid JSON: $insp"; exit 1; }
assert_eq "$(printf '%s' "$insp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["notes"])')" \
    "$NOTES" "notes round-trip through the manifest"

# A newline cannot be expressed in this manifest's string form at all, so it is refused up front.
out=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --notes 'line one
line two' --output "$T/out" 2>&1); rc=$?
assert_eq "$rc" 1 "cmd_create rejects a multi-line --notes"
assert_contains "$out" "single line" "reason given for the rejected --notes"

# --include-plugins opts the out-of-/etc files back in.
mkdir -p "$T/out2"
archive2=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --output "$T/out2" --include-plugins 2>"$T/err2"); rc=$?
assert_eq "$rc" 0 "cmd_create exit code (--include-plugins)"
assert_contains "$(tar -tzf "$archive2")" "gl-portable-backup/extra/usr/bin/plugin-bin" "plugin binary included"
assert_contains "$(cat "$T/err2")" "Skipped 1 firmware-owned" "skipped count (--include-plugins)"

# Clone is the fleet mode: the archive goes onto N other units, so per-device secret identity must
# not ride along. Same fixture tree as the Full archive above, which keeps both.
mkdir -p "$T/out3"
archive3=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode clone --output "$T/out3" 2>"$T/err3"); rc=$?
assert_eq "$rc" 0 "cmd_create exit code (clone)"
listing3=$(tar -tzf "$archive3")
not_contains "$listing3" "extra/etc/tailscale/" "clone excludes Tailscale node state"
not_contains "$listing3" "config/gl_nas/ssl_webdav.pem" "clone excludes the WebDAV TLS key"
assert_contains "$listing3" "gl-portable-backup/extra/etc/userconf/a.conf" "clone still captures user config"
assert_contains "$(cat "$T/err3")" "Captured 2 extra persistent files" "captured count (clone)"
echo "ok 30-create-e2e"
