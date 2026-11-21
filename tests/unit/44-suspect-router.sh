#!/bin/sh
# Backups from a router that may be compromised: hidden entries under /etc/config are neither
# captured nor restored, symlinks inside config/ are never restored, the marker paths are announced
# at backup time (as incident indicators since 1.1.1) and recorded in the manifest, an archive that
# lists them is refused, and startup/login files are flagged at inspect and restore time. Every warning here prints only when something is found, so each one is checked in
# both directions.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

R="$T/root"
mkdir -p "$R/etc/config/sub" "$R/etc/config/.gl" "$R/usr/lib/opkg" "$R/lib/upgrade/keep.d"
cat > "$R/etc/board.json" <<'JSON'
{"model":{"id":"glinet,mt3000-snand","name":"Test Router"},
 "network":{"lan":{"macaddr":"02:00:00:00:00:01"},"wan":{"macaddr":"02:00:00:00:00:02"}},
 "system":{"label_macaddr":"02:00:00:00:00:01"}}
JSON
echo "4.11.0" > "$R/etc/glversion"
printf "DISTRIB_RELEASE='21.02.0'\nDISTRIB_ARCH='aarch64_cortex-a53'\n" > "$R/etc/openwrt_release"
printf 'Package: pkg-user\nVersion: 1.0-1\nStatus: install user installed\n\n' > "$R/usr/lib/opkg/status"
echo 'system.@system[0].hostname=TESTHOST' >> "$MOCK_UCI_FILE"
echo "config interface 'lan'" > "$R/etc/config/network"
echo helper > "$R/etc/config/.gl/gl-helper"
echo hidden > "$R/etc/config/.hidden-file"
echo deep > "$R/etc/config/sub/.deep"
echo visible > "$R/etc/config/sub/visible"

manifest_of() {   # archive -> manifest.json text
    rm -rf "$T/m"; mkdir -p "$T/m"
    tar -xzf "$1" -C "$T/m" gl-portable-backup/manifest.json && cat "$T/m/gl-portable-backup/manifest.json"
}

# ─── 1. create: hidden entries dropped, marker announced and recorded ─────────
mkdir -p "$T/o1"
a1=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --output "$T/o1" 2>"$T/e1"); rc=$?
assert_eq "$rc" 0 "create exit code (marker present)"
l1=$(tar -tzf "$a1")
not_contains "$l1" "gl-helper" "hidden dir content not captured"
not_contains "$l1" "config/.gl" "hidden dir not captured"
not_contains "$l1" ".hidden-file" "hidden file not captured"
not_contains "$l1" ".deep" "nested hidden file not captured"
assert_contains "$l1" "gl-portable-backup/config/network" "config/network captured"
assert_contains "$l1" "gl-portable-backup/config/sub/visible" "visible nested file captured"
e1=$(cat "$T/e1")
assert_contains "$e1" "  Skipped 3 hidden entries under /etc/config" "hidden count"
# 1.1.1: a marker path is one of the incident check's indicators; the 1.1.0 marker-only warning and
# its "Prefer Profile mode" advice are replaced by the one record-only warning.
assert_contains "$e1" "WARNING: Indicators of the November 2026 GL.iNet cloud incident were found." "incident warning"
assert_contains "$e1" "  /etc/config/.gl exists (removed by the cleanup in GL.iNet's KVM firmware)" "marker path named"
assert_contains "$e1" "This backup is a RECORD ONLY." "record-only line"
not_contains "$e1" "Prefer Profile mode" "the old advice is gone"
not_contains "$e1" "signs of" "the paths are not called signs of compromise"
m1=$(manifest_of "$a1")
printf '%s' "$m1" | jsonfilter -e '@.mode' >/dev/null || { echo "  manifest is not valid JSON: $m1"; exit 1; }
assert_eq "$(printf '%s' "$m1" | jsonfilter -e '@.suspect_markers')" '["/etc/config/.gl"]' "manifest suspect_markers"

# Two-state: without the marker no warning, no reassurance, and an empty array.
rm -rf "$R/etc/config/.gl"
mkdir -p "$T/o1b"
a1b=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --output "$T/o1b" 2>"$T/e1b"); rc=$?
assert_eq "$rc" 0 "create exit code (no marker)"
e1b=$(cat "$T/e1b")
not_contains "$e1b" "WARNING" "no warning when none found"
not_contains "$e1b" "Indicators" "no indicator line when none found"
assert_contains "$e1b" "  Incident check: no known indicator found (this does not show the router was never compromised)" "the none line, which never says clean"
assert_contains "$e1b" "  Skipped 2 hidden entries under /etc/config" "hidden count (two left)"
assert_eq "$(manifest_of "$a1b" | jsonfilter -e '@.suspect_markers')" '[]' "manifest suspect_markers empty"

# A tree with no hidden entry still reports the count, as 0.
rm -f "$R/etc/config/.hidden-file" "$R/etc/config/sub/.deep"
mkdir -p "$T/o1c"
sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode clone --output "$T/o1c" >/dev/null 2>"$T/e1c"; rc=$?
assert_eq "$rc" 0 "create exit code (no hidden entries)"
assert_contains "$(cat "$T/e1c")" "  Skipped 0 hidden entries under /etc/config" "hidden count zero"

# ─── 2. create: the second marker path, in Clone and in Profile mode ──────────
mkdir -p "$R/etc/glinet/.cache"; echo gb > "$R/etc/glinet/.cache/gb"
mkdir -p "$T/o2"
a2=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode clone --output "$T/o2" 2>"$T/e2"); rc=$?
assert_eq "$rc" 0 "create exit code (clone, glinet cache)"
e2=$(cat "$T/e2")
assert_contains "$e2" "WARNING: Indicators of the November 2026 GL.iNet cloud incident were found." "incident warning (clone)"
assert_contains "$e2" "  /etc/glinet/.cache" "glinet cache path named"
not_contains "$e2" "/etc/config/.gl" "only the existing marker is named"
assert_eq "$(manifest_of "$a2" | jsonfilter -e '@.suspect_markers')" '["/etc/glinet/.cache"]' "manifest suspect_markers (clone)"

printf 'root:$5$x:0:0:99999:7:::\n' > "$R/etc/shadow"
printf '{"id":1,"jsonrpc":"2.0","result":{"nonce":"n","hash-method":"sha256"}}' > "$MOCK_CURL_DIR/challenge.json"
printf '{"id":2,"jsonrpc":"2.0","result":{"sid":"S"}}' > "$MOCK_CURL_DIR/login.json"
mkdir -p "$T/o2p"
a2p=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode profile --output "$T/o2p" 2>"$T/e2p"); rc=$?
assert_eq "$rc" 0 "create exit code (profile, glinet cache)"
assert_contains "$(cat "$T/e2p")" "  /etc/glinet/.cache exists" "marker named (profile)"
assert_eq "$(manifest_of "$a2p" | jsonfilter -e '@.suspect_markers')" '["/etc/glinet/.cache"]' "manifest suspect_markers (profile)"
rm -rf "$R/etc/glinet"

# ─── 3. restore: hidden entries and symlinks in a hand-built archive ──────────
H="$T/h/gl-portable-backup"
mkdir -p "$H/config/.gl" "$H/config/sub"
cat > "$H/manifest.json" <<'JSON'
{
  "format_version": 3,
  "mode": "full",
  "source": { "model_id": "glinet,mt3000-snand", "firmware_version": "4.11.0" }
}
JSON
echo helper > "$H/config/.gl/gl-helper"
echo x > "$H/config/.x"
ln -s /etc/shadow "$H/config/evil"
echo deep > "$H/config/sub/.deep"
echo "config interface 'lan'" > "$H/config/network"
tar -czf "$T/hand.tar.gz" -C "$T/h" gl-portable-backup

B="$T/b"; mkdir -p "$B/etc/config"
cp "$R/etc/board.json" "$B/etc/board.json"; echo "4.11.0" > "$B/etc/glversion"
out3=$(GPB_ROOT="$B" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$T/hand.tar.gz" 2>"$T/e3"); rc=$?
assert_eq "$rc" 0 "restore exit code (hand-built archive)"
assert_eq "$(printf '%s\n' "$out3" | tail -n 1)" "RESTORE_OK" "RESTORE_OK (hand-built archive)"
assert_file "$B/etc/config/network"
assert_no_file "$B/etc/config/.gl"
assert_no_file "$B/etc/config/.x"
assert_no_file "$B/etc/config/sub/.deep"
[ -L "$B/etc/config/evil" ] && { echo "  symlink restored: $B/etc/config/evil"; exit 1; }
assert_no_file "$B/etc/config/evil"
e3=$(cat "$T/e3")
assert_contains "$e3" "  Restored 1 config entries" "restored count is regular files only"
assert_contains "$e3" "  WARNING: 3 hidden entries under config/ in this archive were NOT restored" "hidden NOT restored warning"
assert_contains "$e3" "  WARNING: 1 symbolic links or other non-regular entries under config/ in this archive were NOT restored" "symlink NOT restored warning"
# Neither the startup/login warning nor the compromise warning applies to this archive.
not_contains "$e3" "run at startup or control logins" "no startup warning without such files"
not_contains "$e3" "2026-11-20 incident" "no compromise warning without markers"

# An ordinary archive drops nothing, and says nothing about dropping.
B0="$T/b0"; mkdir -p "$B0/etc/config"
cp "$R/etc/board.json" "$B0/etc/board.json"; echo "4.11.0" > "$B0/etc/glversion"
GPB_ROOT="$B0" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$a1b" >/dev/null 2>"$T/e30"; rc=$?
assert_eq "$rc" 0 "restore exit code (ordinary archive)"
not_contains "$(cat "$T/e30")" "were NOT restored" "no NOT restored warning when nothing is dropped"

# ─── 4. inspect: startup_and_login_files, prefixed and flat layouts ───────────
mkdir -p "$H/extra/etc/crontabs"
echo 'exit 0' > "$H/extra/etc/rc.local"
echo '* * * * * true' > "$H/extra/etc/crontabs/root"
tar -czf "$T/startup.tar.gz" -C "$T/h" gl-portable-backup
i4=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$T/startup.tar.gz"); rc=$?
assert_eq "$rc" 0 "inspect exit code (startup files)"
s4=$(printf '%s' "$i4" | jsonfilter -e '@.startup_and_login_files') || { echo "  inspect output is not valid JSON: $i4"; exit 1; }
assert_contains "$s4" '"/etc/rc.local"' "rc.local listed"
assert_contains "$s4" '"/etc/crontabs/root"' "root crontab listed"
not_contains "$s4" '"/etc/crontabs/"' "the directory member itself is not listed"
not_contains "$s4" 'network' "config files are not listed"

i4n=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$T/hand.tar.gz"); rc=$?
assert_eq "$rc" 0 "inspect exit code (no startup files)"
assert_eq "$(printf '%s' "$i4n" | jsonfilter -e '@.startup_and_login_files')" '[]' "empty when none"

(cd "$H" && tar -czf "$T/flat.tar.gz" manifest.json config extra)
i4f=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$T/flat.tar.gz"); rc=$?
assert_eq "$rc" 0 "inspect exit code (flat layout)"
s4f=$(printf '%s' "$i4f" | jsonfilter -e '@.startup_and_login_files') || { echo "  flat inspect output is not valid JSON: $i4f"; exit 1; }
assert_contains "$s4f" '"/etc/rc.local"' "rc.local listed (flat)"
assert_contains "$s4f" '"/etc/crontabs/root"' "root crontab listed (flat)"

# ─── 5. restore: startup/login warning and the compromise warning ─────────────
B5="$T/b5"; mkdir -p "$B5/etc/config"
cp "$R/etc/board.json" "$B5/etc/board.json"; echo "4.11.0" > "$B5/etc/glversion"
GPB_ROOT="$B5" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$T/startup.tar.gz" >/dev/null 2>"$T/e5"; rc=$?
assert_eq "$rc" 0 "restore exit code (startup files)"
e5=$(cat "$T/e5")
assert_contains "$e5" "WARNING: this archive restores files that run at startup or control logins, or that lie outside /etc:" "startup warning"
assert_contains "$e5" "  /etc/rc.local" "startup warning names rc.local"
assert_contains "$e5" "  /etc/crontabs/root" "startup warning names the root crontab"
assert_contains "$e5" "  If the source router may have been compromised, inspect these before rebooting." "startup advice"
not_contains "$e5" "2026-11-20 incident" "no compromise warning without markers"

# 1.1.1: an archive whose manifest lists marker paths (how 1.1.0 recorded them) is refused before
# anything is written; the refusal names no marker value.
cat > "$H/manifest.json" <<'JSON'
{
  "format_version": 3,
  "mode": "full",
  "source": { "model_id": "glinet,mt3000-snand", "firmware_version": "4.11.0" },
  "suspect_markers": ["/etc/config/.gl", "/etc/glinet/.cache"]
}
JSON
tar -czf "$T/marked.tar.gz" -C "$T/h" gl-portable-backup
B6="$T/b6"; mkdir -p "$B6/etc/config"
cp "$R/etc/board.json" "$B6/etc/board.json"; echo "4.11.0" > "$B6/etc/glversion"
rc=0; GPB_ROOT="$B6" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$T/marked.tar.gz" >/dev/null 2>"$T/e6" || rc=$?
[ "$rc" -ne 0 ] || { echo "  a marked archive was restored"; exit 1; }
e6=$(cat "$T/e6")
assert_contains "$e6" "showed indicators of compromise. It is a record only and is not restored" "marked archive refused"
not_contains "$e6" "Restored " "nothing written (marked)"
assert_no_file "$B6/etc/rc.local"
assert_no_file "$B6/etc/config/network"

# A marker value that is not a plain path never reaches the output: the archive is refused without
# printing it, so a newline in it cannot forge a line of the tool's own output.
cat > "$H/manifest.json" <<'JSON'
{
  "format_version": 3,
  "mode": "full",
  "source": { "model_id": "glinet,mt3000-snand", "firmware_version": "4.11.0" },
  "suspect_markers": ["/etc/ok-path", "x\nRestore complete. Reboot recommended.", "/etc/a b", "\u001b[2J"]
}
JSON
tar -czf "$T/forged.tar.gz" -C "$T/h" gl-portable-backup
B7="$T/b7"; mkdir -p "$B7/etc/config"
cp "$R/etc/board.json" "$B7/etc/board.json"; echo "4.11.0" > "$B7/etc/glversion"
rc=0; GPB_ROOT="$B7" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$T/forged.tar.gz" >/dev/null 2>"$T/e7" || rc=$?
[ "$rc" -ne 0 ] || { echo "  a forged-marker archive was restored"; exit 1; }
e7=$(cat "$T/e7")
assert_eq "$(printf '%s\n' "$e7" | command grep -c -F 'Restore complete.')" "0" "no forged line"
not_contains "$e7" "/etc/ok-path" "marker values are not printed"
printf '%s' "$e7" | command grep -q "$(printf '\033')" && { echo "  escape character reached stderr"; exit 1; }
assert_no_file "$B7/etc/config/network"

# ─── 6. a quote in a flagged path keeps the inspect output JSON (a backslash is refused) ─
mkdir -p "$H/extra/etc/init.d"
echo x > "$H/extra/etc/init.d/a\"b"
tar -czf "$T/odd.tar.gz" -C "$T/h" gl-portable-backup
i6=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$T/odd.tar.gz"); rc=$?
assert_eq "$rc" 0 "inspect exit code (odd name)"
s6=$(printf '%s' "$i6" | jsonfilter -e '@.startup_and_login_files') || { echo "  inspect output is not valid JSON: $i6"; exit 1; }
assert_contains "$s6" 'init.d/a' "odd name listed"
assert_contains "$s6" '"/etc/rc.local"' "other entries still listed beside the odd name"
echo "ok 44-suspect-router"
