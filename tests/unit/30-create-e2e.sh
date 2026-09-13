#!/bin/sh
# End-to-end cmd_create: what lands in the archive, what the operator is told, what backup-info says.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

R="$T/root"
mkdir -p "$R/etc/config" "$R/etc/userconf" "$R/etc/netifyd" "$R/etc/gl_crontabs/crontabs.d" \
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
printf '/etc/netifyd/\n/etc/gl_crontabs/crontabs.d/\n' >> "$R/lib/upgrade/keep.d/fixture"
echo conf > "$R/etc/userconf/a.conf"                              # user config      -> captured
echo bin  > "$R/usr/bin/plugin-bin"                               # plugin binary    -> skipped
echo uuid > "$R/etc/netifyd/agent.uuid"                           # firmware-owned   -> skipped
echo same > "$R/etc/gl_crontabs/crontabs.d/auto_timezone"         # identical to /rom -> skipped
echo same > "$R/rom/etc/gl_crontabs/crontabs.d/auto_timezone"
echo mine > "$R/etc/gl_crontabs/crontabs.d/user_job"              # edited by the user -> captured
echo stock > "$R/rom/etc/gl_crontabs/crontabs.d/user_job"

# Sub-shell form so the backend's own set -e is live (load_backend turns it off — see tests/lib.sh).
mkdir -p "$T/out"
archive=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --output "$T/out" 2>"$T/err"); rc=$?
assert_eq "$rc" 0 "cmd_create exit code"
case "$archive" in
    "$T/out"/gl-backup-full-TESTHOST-MT3000-fw4-11-0-*.tar.gz) ;;
    *) echo "  archive name FAILED: $archive"; exit 1 ;;
esac
assert_file "$archive"

listing=$(tar -tzf "$archive")
assert_contains "$listing" "gl-portable-backup/extra/etc/userconf/a.conf" "user file captured"
assert_contains "$listing" "gl-portable-backup/extra/etc/gl_crontabs/crontabs.d/user_job" "edited file captured"
assert_contains "$listing" "gl-portable-backup/config/network" "config copied"
not_contains "$listing" "plugin-bin" "plugin binary excluded"
not_contains "$listing" "agent.uuid" "firmware-owned excluded"
not_contains "$listing" "auto_timezone" "rom-identical excluded"
not_contains "$listing" "network-opkg" "opkg conffile backup excluded"

err=$(cat "$T/err")
assert_contains "$err" "Captured 2 extra persistent files" "captured count"
assert_contains "$err" "Skipped 2 firmware-owned, 1 identical to /rom" "skipped counts"
mkdir -p "$T/x"; tar -xzf "$archive" -C "$T/x" gl-portable-backup/backup-info.txt
assert_contains "$(cat "$T/x/gl-portable-backup/backup-info.txt")" \
    "Skipped:    2 firmware-owned, 1 identical to /rom" "backup-info skipped line"

# --include-plugins opts the out-of-/etc files back in.
mkdir -p "$T/out2"
archive2=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --output "$T/out2" --include-plugins 2>"$T/err2"); rc=$?
assert_eq "$rc" 0 "cmd_create exit code (--include-plugins)"
assert_contains "$(tar -tzf "$archive2")" "gl-portable-backup/extra/usr/bin/plugin-bin" "plugin binary included"
assert_contains "$(cat "$T/err2")" "Skipped 1 firmware-owned" "skipped count (--include-plugins)"
echo "ok 30-create-e2e"
