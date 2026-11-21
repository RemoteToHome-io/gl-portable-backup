#!/bin/sh
# The incident check at backup time and its consequence at restore time: every create records the
# check in the manifest; a backup taken while indicators are present is announced as a record only and
# named -COMPROMISED-; restore refuses such an archive, and a 1.1.0 archive with suspect markers,
# before anything is written; inspect reports restore_refused from the same function.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

R="$T/root"
mkdir -p "$R/usr/lib/opkg" "$R/tmp"
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

create() {   # MODE OUTDIR -> archive path in $a, stderr in $e, status in $rc
    mkdir -p "$2"; rc=0
    a=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode "$1" --output "$2" 2>"$T/create.err") || rc=$?
    e=$(cat "$T/create.err")
}
manifest_of() {   # archive -> manifest.json text
    rm -rf "$T/m"; mkdir -p "$T/m"
    tar -xzf "$1" -C "$T/m" gl-portable-backup/manifest.json && cat "$T/m/gl-portable-backup/manifest.json"
}
fresh_target() {   # DIR — an empty unit of the same model
    rm -rf "$1"; mkdir -p "$1/etc/config"
    cp "$R/etc/board.json" "$1/etc/board.json"; echo "4.11.0" > "$1/etc/glversion"
    echo "config interface 'old'" > "$1/etc/config/network"
}
listing() { (cd "$1" && find . | sort && find . -type f -exec cat {} + ); }
restore_into() {   # TARGET ARCHIVE -> stdout in $ro, stderr in $re, status in $rc
    rc=0; ro=$(GPB_ROOT="$1" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$2" 2>"$T/restore.err") || rc=$?
    re=$(cat "$T/restore.err")
}
inspect_refused() {   # ARCHIVE -> restore_refused value
    local o
    o=$(sh -c '. "$0"; cmd_inspect "$@"' "$BACKEND" "$1") || { echo "  inspect failed on $1"; exit 1; }
    printf '%s' "$o" | jsonfilter -e '@.mode' >/dev/null || { echo "  inspect output is not valid JSON: $o"; exit 1; }
    printf '%s' "$o" | jsonfilter -e '@.restore_refused'
}
REFUSAL="This archive was made on a router that showed indicators of compromise. It is a record only and is not restored: its VPN keys and configurations, passwords and keys must be replaced, not carried back. Nothing was changed."
RECORD_ONLY="  This backup is a RECORD ONLY. gl-portable-backup will refuse to restore it: VPN keys and configurations, Wi-Fi keys, passwords and SSH keys from this router must be replaced, not restored."

# ─── 1. create, nothing found ─────────────────────────────────────────────────
create full "$T/o1"
assert_eq "$rc" 0 "create exit code (none)"
assert_contains "$e" "  Incident check: no known indicator found (this does not show the router was never compromised)" "none line"
not_contains "$e" "WARNING" "no warning when nothing is found"
not_contains "$e" "RECORD ONLY" "no record-only line when nothing is found"
not_contains "$a" "COMPROMISED" "no -COMPROMISED- in the name"
assert_contains "$a" "/gl-backup-full-TESTHOST-" "ordinary name"
m1=$(manifest_of "$a")
assert_eq "$(printf '%s' "$m1" | jsonfilter -e '@.incident_check.result')" "none" "manifest incident_check.result (none)"
assert_eq "$(printf '%s' "$m1" | jsonfilter -e '@.incident_check.indicators')" "[]" "manifest incident_check.indicators (none)"
printf '%s' "$m1" | jsonfilter -e '@.incident_check.checked_at' >/dev/null || { echo "  no checked_at: $m1"; exit 1; }
assert_eq "$(printf '%s' "$m1" | jsonfilter -e '@.suspect_markers')" "[]" "suspect_markers still written"
A_NONE="$a"

# ─── 2. create with indicators: a record, named as one ────────────────────────
mkfifo "$R/tmp/f"
mkdir -p "$R/etc/config/.gl"
create full "$T/o2"
assert_eq "$rc" 0 "create exit code (indicators): the backup still completes"
assert_contains "$e" "WARNING: Indicators of the November 2026 GL.iNet cloud incident were found. Treat every key and password on this router as exposed." "warning note"
assert_contains "$e" "  /tmp/f is a named pipe: the remote shell has run since the last boot" "detail line (fifo)"
assert_contains "$e" "  /etc/config/.gl exists (removed by the cleanup in GL.iNet's KVM firmware)" "detail line (marker)"
assert_contains "$e" "$RECORD_ONLY" "record-only line"
assert_contains "$e" "  VPN client profiles and SSH client keys that this router held must also be revoked on the server they connect to." "revocation line"
assert_eq "$(printf '%s\n' "$e" | command grep -c 'WARNING')" 1 "one warning, not two"
not_contains "$e" "Prefer Profile mode" "the old marker-only advice is gone"
not_contains "$e" "Incident check: no known indicator" "no none line with indicators"
assert_contains "$a" "/gl-backup-full-COMPROMISED-TESTHOST-" "-COMPROMISED- after the mode"
case "${a##*/}" in *[!A-Za-z0-9.\;=/-]*) echo "  file name has a character cgi-download refuses: $a"; exit 1;; esac
m2=$(manifest_of "$a")
assert_eq "$(printf '%s' "$m2" | jsonfilter -e '@.incident_check.result')" "indicators" "manifest result (indicators)"
assert_eq "$(printf '%s' "$m2" | jsonfilter -e '@.incident_check.indicators')" '["tmp-fifo","marker-dir"]' "manifest ids only"
not_contains "$m2" "named pipe" "manifest carries ids, not details"
assert_eq "$(printf '%s' "$m2" | jsonfilter -e '@.suspect_markers')" '["/etc/config/.gl"]' "suspect_markers kept for compatibility"
A_IND="$a"

printf 'root:$5$x:0:0:99999:7:::\n' > "$R/etc/shadow"
printf '{"id":1,"jsonrpc":"2.0","result":{"nonce":"n","hash-method":"sha256"}}' > "$MOCK_CURL_DIR/challenge.json"
printf '{"id":2,"jsonrpc":"2.0","result":{"sid":"S"}}' > "$MOCK_CURL_DIR/login.json"
create profile "$T/o2p"
assert_eq "$rc" 0 "create exit code (profile, indicators)"
assert_contains "$a" "/gl-backup-profile-COMPROMISED-TESTHOST-" "-COMPROMISED- in a Profile name"
assert_contains "$e" "$RECORD_ONLY" "record-only line (profile)"
A_IND_PROFILE="$a"
rm -f "$R/tmp/f"; rm -rf "$R/etc/config/.gl"

# A check that could not read what it needs makes a record too.
mv "$R/proc/net/tcp" "$T/tcp.off"
create clone "$T/o2c"
mv "$T/tcp.off" "$R/proc/net/tcp"
assert_contains "$a" "/gl-backup-clone-COMPROMISED-" "an incomplete check is not none"
assert_contains "$e" "  the TCP connection table /proc/net/tcp could not be read" "incomplete detail"

# Restarted since the attack window, nothing found: inconclusive. Announced, recorded, not a record.
echo "600.00 1.00" > "$R/proc/uptime"
create full "$T/o2i"
rm -f "$R/proc/uptime"
assert_eq "$rc" 0 "create exit code (inconclusive)"
assert_contains "$e" "WARNING: No known indicator was found, but this router has restarted since the attack window (from about 20:48 UTC on 2026-11-20). The remote shell and its traces do not survive a restart, so this check cannot clear it." "inconclusive sentence"
not_contains "$e" "RECORD ONLY" "inconclusive is not a record"
not_contains "$a" "COMPROMISED" "no -COMPROMISED- for inconclusive"
assert_eq "$(manifest_of "$a" | jsonfilter -e '@.incident_check.result')" "inconclusive" "manifest result (inconclusive)"
A_INC="$a"

# ─── 3. restore refuses a record, before anything is written ──────────────────
for arc in "$A_IND" "$A_IND_PROFILE"; do
    B="$T/b-refused"; fresh_target "$B"; before=$(listing "$B")
    restore_into "$B" "$arc"
    [ "$rc" -ne 0 ] || { echo "  restore of a record was not refused: $arc"; exit 1; }
    assert_contains "$re" "ERROR: $REFUSAL" "refusal text"
    not_contains "$ro" "RESTORE_OK" "no RESTORE_OK"
    not_contains "$re" "Restored " "nothing restored"
    assert_eq "$(listing "$B")" "$before" "target untouched"
done

# A 1.1.0 archive: suspect_markers set, no incident_check.
H="$T/h/gl-portable-backup"
mkdir -p "$H/config"
echo "config interface 'lan'" > "$H/config/network"
hand() {   # NAME MANIFEST-BODY-LINES — builds $T/NAME.tar.gz with the given top-level keys
    { echo '{'
      echo '  "format_version": 4,'
      echo '  "mode": "full",'
      echo '  "source": { "model_id": "glinet,mt3000-snand", "firmware_version": "4.11.0" },'
      printf '%s\n' "$2"
      echo '  "notes": ""'
      echo '}'
    } > "$H/manifest.json"
    tar -czf "$T/$1.tar.gz" -C "$T/h" gl-portable-backup
}
hand marked '  "suspect_markers": ["/etc/glinet/.cache"],'
B="$T/b-marked"; fresh_target "$B"; before=$(listing "$B")
restore_into "$B" "$T/marked.tar.gz"
[ "$rc" -ne 0 ] || { echo "  restore of a 1.1.0 archive with markers was not refused"; exit 1; }
assert_contains "$re" "ERROR: $REFUSAL" "refusal text (1.1.0 markers)"
assert_eq "$(listing "$B")" "$before" "target untouched (1.1.0 markers)"

# A result this tool never writes is refused too.
hand odd '  "incident_check": {"result":"maybe","indicators":[],"checked_at":"x"},
  "suspect_markers": [],'
B="$T/b-odd"; fresh_target "$B"; before=$(listing "$B")
restore_into "$B" "$T/odd.tar.gz"
[ "$rc" -ne 0 ] || { echo "  restore with an unknown incident_check result was not refused"; exit 1; }
assert_contains "$re" "Invalid archive: its incident check is not in the form this tool writes" "odd result refused"
assert_eq "$(listing "$B")" "$before" "target untouched (odd result)"

# ─── 4. restore of a none archive and of an older archive ─────────────────────
B="$T/b-none"; fresh_target "$B"
restore_into "$B" "$A_NONE"
assert_eq "$rc" 0 "restore exit code (none)"
assert_eq "$(printf '%s\n' "$ro" | tail -n 1)" "RESTORE_OK" "RESTORE_OK (none)"
not_contains "$re" "carries no incident check" "no Note for a checked archive"

B="$T/b-inc"; fresh_target "$B"
restore_into "$B" "$A_INC"
assert_eq "$rc" 0 "restore exit code (inconclusive is not refused)"
assert_eq "$(printf '%s\n' "$ro" | tail -n 1)" "RESTORE_OK" "RESTORE_OK (inconclusive)"

hand older '  "suspect_markers": [],'
B="$T/b-older"; fresh_target "$B"
restore_into "$B" "$T/older.tar.gz"
assert_eq "$rc" 0 "restore exit code (older)"
assert_contains "$re" "  Note: this archive carries no incident check (made by an older version)." "Note line (older)"
assert_eq "$(cat "$B/etc/config/network")" "config interface 'lan'" "older archive restored"

hand oldest ''
B="$T/b-oldest"; fresh_target "$B"
restore_into "$B" "$T/oldest.tar.gz"
assert_eq "$rc" 0 "restore exit code (no suspect_markers key)"
assert_contains "$re" "  Note: this archive carries no incident check (made by an older version)." "Note line (no markers key)"

# ─── 5. inspect: restore_refused from the same function ───────────────────────
assert_eq "$(inspect_refused "$A_IND")" "true" "inspect: record"
assert_eq "$(inspect_refused "$T/marked.tar.gz")" "true" "inspect: 1.1.0 markers"
assert_eq "$(inspect_refused "$T/odd.tar.gz")" "true" "inspect: unknown result"
assert_eq "$(inspect_refused "$A_NONE")" "false" "inspect: none"
assert_eq "$(inspect_refused "$A_INC")" "false" "inspect: inconclusive"
assert_eq "$(inspect_refused "$T/older.tar.gz")" "false" "inspect: older"
echo "ok 48-incident-records"
