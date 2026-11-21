#!/bin/sh
# Restoring an attacker-built archive as root: members that could escape or impersonate are refused
# before extraction (hard links, special files, "..", control characters, backslashes); top-level
# symlinks are refused after it; a manifest in any layout but the tool's own is refused; extra/ never
# writes into /etc/config, never restores a hidden or non-regular entry, and every file it restores
# outside /etc is flagged; and a failed copy stops the restore instead of reporting success.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

# mk OUT SPEC... — builds a gzip tar with python's tarfile so that names and member types no tar
# front end would produce can be crafted. SPEC: f:NAME (regular file), s:NAME:TARGET (symlink),
# h:NAME:TARGET (hard link), p:NAME (fifo), M:NAME (the tool's manifest, multi-line), C:NAME (the
# same manifest on one line). \t, \n and \\ in NAME are decoded.
cat > "$T/mk.py" <<'PY'
import tarfile, io, sys, json
man = {"format_version": 4, "tool": "gl-portable-backup", "mode": "full",
       "source": {"model": "Test Router", "model_id": "glinet,mt3000-snand", "firmware_version": "4.11.0", "hostname": "h"},
       "sections": [], "excluded_sections": [], "extra_files": [], "suspect_markers": [], "notes": ""}
def dec(s): return s.encode().decode('unicode_escape')
with tarfile.open(sys.argv[1], "w:gz") as t:
    for spec in sys.argv[2:]:
        kind, rest = spec[0], spec[2:]
        name, _, target = rest.partition(':')
        ti = tarfile.TarInfo(dec(name)); ti.mode = 0o644; data = b""
        if kind == 'f': data = b"x\n"
        elif kind == 'M': data = (json.dumps(man, indent=2) + "\n").encode()
        elif kind == 'C': data = json.dumps(man).encode()
        elif kind == 's': ti.type = tarfile.SYMTYPE; ti.linkname = target
        elif kind == 'h': ti.type = tarfile.LNKTYPE; ti.linkname = target
        elif kind == 'p': ti.type = tarfile.FIFOTYPE
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data) if data else None)
PY
mk() { python3 -I "$T/mk.py" "$@"; }
P=gl-portable-backup
fresh_root() {   # DIR — an empty target unit of the archive's model
    rm -rf "$1"; mkdir -p "$1/etc/config"
    printf '{"model":{"id":"glinet,mt3000-snand","name":"Test Router"}}' > "$1/etc/board.json"
    echo "4.11.0" > "$1/etc/glversion"
}
written() { (cd "$1" && find . ! -type d | sort | command grep -v -x -F -e ./etc/board.json -e ./etc/glversion); }
restore_into() { GPB_ROOT="$1" sh -c '. "$0"; cmd_restore "$@"' "$BACKEND" "$2"; }
run_cmd() { sh -c '. "$0"; cmd_'"$1"' "$1"' "$BACKEND" "$2"; }
V="$T/victim"; mkdir -p "$V"; echo secret > "$V/secret"

# ─── H. hard links and special members are refused before anything is extracted ─
mk "$T/hard.tgz" "M:$P/manifest.json" "h:$P/extra/etc/hl:$V/secret"
mk "$T/fifo.tgz" "M:$P/manifest.json" "p:$P/extra/etc/fifo"
for a in hard fifo; do
    for c in restore inspect fingerprint packages; do
        R="$T/r-$a-$c"; fresh_root "$R"
        if [ "$c" = restore ]; then rc=0; out=$(restore_into "$R" "$T/$a.tgz" 2>"$T/err") || rc=$?
        else rc=0; out=$(GPB_ROOT="$R" run_cmd "$c" "$T/$a.tgz" 2>"$T/err") || rc=$?; fi
        [ "$rc" -ne 0 ] || { echo "  $a/$c: expected a refusal, got rc 0"; exit 1; }
        assert_contains "$(cat "$T/err")" "Invalid archive: it contains 1 hard links, device nodes or other special members" "$a/$c refusal"
        not_contains "$(cat "$T/err")" "secret" "$a/$c names no member"
        assert_eq "$(written "$R")" "" "$a/$c writes nothing"
    done
done
# A listing that fails or is empty is not a clean listing.
printf 'not a tar' > "$T/garbage.tgz"; R="$T/r-garbage"; fresh_root "$R"
rc=0; restore_into "$R" "$T/garbage.tgz" >/dev/null 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] || { echo "  garbage archive accepted"; exit 1; }
assert_contains "$(cat "$T/err")" "Invalid archive: it cannot be listed" "garbage refused"

# ─── C2.2 refused member names: "..", control characters, backslash ──────────
mk "$T/names.tgz" "M:$P/manifest.json" "f:$P/extra/etc/../x" "f:$P/extra/etc/a\tb" "f:$P/extra/etc/c\\\\d" "f:$P/extra/etc/n\nrc.local" "f:$P/extra/etc/ok"
for c in restore inspect; do
    R="$T/r-names-$c"; fresh_root "$R"
    if [ "$c" = restore ]; then rc=0; restore_into "$R" "$T/names.tgz" >/dev/null 2>"$T/err" || rc=$?
    else rc=0; run_cmd inspect "$T/names.tgz" >/dev/null 2>"$T/err" || rc=$?; fi
    [ "$rc" -ne 0 ] || { echo "  names/$c accepted"; exit 1; }
    e=$(cat "$T/err")
    case "$e" in
        *"Invalid archive: "*" members have a '..' component, a control character or a backslash in their name"*) ;;
        *"Invalid archive: it contains "*" hard links, device nodes or other special members"*) ;;  # BusyBox: the newline splits a line
        *) echo "  names/$c: no refusal message: [$e]"; exit 1 ;;
    esac
    not_contains "$e" "rc.local" "names/$c names no member"
    assert_eq "$(written "$R")" "" "names/$c writes nothing"
done
mk "$T/dd.tgz" "M:$P/manifest.json" "f:$P/../../victim/pwn"
R="$T/r-dd"; fresh_root "$R"; rc=0; restore_into "$R" "$T/dd.tgz" >/dev/null 2>"$T/err" || rc=$?
assert_contains "$(cat "$T/err")" "Invalid archive: 1 members have a '..' component" "dot-dot counted"
assert_no_file "$V/pwn"

# ─── C2.2 path forms are normalised for every listing-derived decision ───────
mk "$T/forms.tgz" "M:$P/manifest.json" "f:$P/extra/etc//rc.local" "f:$P/extra/./etc/crontabs/root" \
    "f:$P//extra/etc/shadow" "f:$P/extra/etc/dropbear/./authorized_keys" "f:./$P/extra/etc/dropbear/dropbear_ed25519_host_key"
i=$(run_cmd inspect "$T/forms.tgz"); rc=$?
assert_eq "$rc" 0 "inspect (path forms)"
s=$(printf '%s' "$i" | jsonfilter -e '@.startup_and_login_files') || { echo "  inspect output is not JSON: $i"; exit 1; }
for f in /etc/rc.local /etc/crontabs/root /etc/shadow /etc/dropbear/authorized_keys /etc/dropbear/dropbear_ed25519_host_key; do
    assert_contains "$s" "\"$f\"" "flagged despite its path form: $f"
done
assert_eq "$(printf '%s' "$i" | jsonfilter -e '@.restores_root_password')" "true" "root password despite //"
assert_eq "$(printf '%s' "$i" | jsonfilter -e '@.restores_ssh_host_keys')" "true" "host keys despite ./"

# ─── C2.1 a manifest in any other layout is refused ──────────────────────────
mk "$T/compact.tgz" "C:$P/manifest.json" "f:$P/extra/etc/rc.local"
rc=0; run_cmd inspect "$T/compact.tgz" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] || { echo "  compact manifest passed inspect: $(cat "$T/out")"; exit 1; }
assert_contains "$(cat "$T/err")" "Invalid archive: manifest.json is not in the layout this tool writes" "inspect refusal"
R="$T/r-compact"; fresh_root "$R"; rc=0; restore_into "$R" "$T/compact.tgz" >/dev/null 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] || { echo "  compact manifest restored"; exit 1; }
assert_contains "$(cat "$T/err")" "Invalid archive: manifest.json is not in the layout this tool writes" "restore refusal"
assert_eq "$(written "$R")" "" "compact manifest: nothing written"
# The appended keys must land at the top level of the output, or inspect refuses rather than mislead.
mkdir -p "$T/nest/$P"; printf '{\n  "a": {"b": 1,\n  "c": 2}, "x": {\n}\n' > "$T/nest/$P/manifest.json"
tar -czf "$T/nest.tgz" -C "$T/nest" "$P"
rc=0; run_cmd inspect "$T/nest.tgz" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] || { echo "  nested-object manifest passed inspect: $(cat "$T/out")"; exit 1; }

# ─── I2 top-level symlinks are refused (restore, inspect, fingerprint, packages) ─
mk "$T/s_config.tgz" "M:$P/manifest.json" "s:$P/config:$V"
mk "$T/s_extra.tgz" "M:$P/manifest.json" "s:$P/extra:$V"
mk "$T/s_manifest.tgz" "s:$P/manifest.json:$V/secret"
mk "$T/s_pkg.tgz" "M:$P/manifest.json" "s:$P/packages.json:$V/secret"
# The prefix directory itself as a symlink to a benign sibling: extraction succeeds, and the tool
# would then read and write through the link.
( cd "$T" && python3 -I -c 'import tarfile,io,json,sys
man=(json.dumps({"mode":"full","source":{"model_id":"glinet,mt3000-snand"}},indent=2)+"\n").encode()
t=tarfile.open("s_prefix.tgz","w:gz")
ti=tarfile.TarInfo("real/manifest.json"); ti.size=len(man); t.addfile(ti,io.BytesIO(man))
ti=tarfile.TarInfo("real/packages.json"); ti.size=len(man); t.addfile(ti,io.BytesIO(man))
ti=tarfile.TarInfo("gl-portable-backup"); ti.type=tarfile.SYMTYPE; ti.linkname="real"; t.addfile(ti)
t.close()' )
for a in s_config s_extra s_manifest s_prefix; do
    R="$T/r-$a"; fresh_root "$R"; rc=0; restore_into "$R" "$T/$a.tgz" >/dev/null 2>"$T/err" || rc=$?
    [ "$rc" -ne 0 ] || { echo "  $a restored"; exit 1; }
    assert_contains "$(cat "$T/err")" "is a symbolic link" "$a restore refusal"
    assert_eq "$(written "$R")" "" "$a writes nothing"
done
for a in s_manifest s_prefix; do
    rc=0; run_cmd inspect "$T/$a.tgz" >/dev/null 2>"$T/err" || rc=$?
    [ "$rc" -ne 0 ] || { echo "  $a passed inspect"; exit 1; }
    assert_contains "$(cat "$T/err")" "is a symbolic link" "$a inspect refusal"
done
for a in s_pkg s_prefix; do
    rc=0; run_cmd packages "$T/$a.tgz" >/dev/null 2>"$T/err" || rc=$?
    [ "$rc" -ne 0 ] || { echo "  $a passed packages"; exit 1; }
    assert_contains "$(cat "$T/err")" "is a symbolic link" "$a packages refusal"
done
rc=0; run_cmd fingerprint "$T/s_prefix.tgz" >/dev/null 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] || { echo "  s_prefix passed fingerprint"; exit 1; }
assert_contains "$(cat "$T/err")" "is a symbolic link" "s_prefix fingerprint refusal"

# ─── C1 extra/: /etc/config, hidden and non-regular entries are skipped; outside /etc is flagged ─
mk "$T/e1.tgz" "M:$P/manifest.json" "f:$P/config/network" "f:$P/extra/usr/sbin/evil" \
    "f:$P/extra/etc/config/.gl/gl-helper" "f:$P/extra/etc/config/firewall" "f:$P/extra/etc/.hidden" "f:$P/extra/etc/x/.y/z" \
    "f:$P/extra/etc/rc.button/reset" "f:$P/extra/etc/firewall.user" "f:$P/extra/lib/functions.sh" "s:$P/extra/etc/lnk:../config" \
    "f:$P/extra/etc/plain"
R="$T/r-e1"; fresh_root "$R"
out=$(restore_into "$R" "$T/e1.tgz" 2>"$T/err"); rc=$?
assert_eq "$rc" 0 "e1 restore exit"
assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "RESTORE_OK" "e1 RESTORE_OK"
assert_eq "$(written "$R")" "$(printf '%s\n' ./etc/config/network ./etc/firewall.user ./etc/plain ./etc/rc.button/reset ./lib/functions.sh ./usr/sbin/evil)" "e1 writes exactly these"
e=$(cat "$T/err")
assert_contains "$e" "  WARNING: 2 entries under extra/etc/config/ in this archive were NOT restored" "etc/config skipped"
assert_contains "$e" "  WARNING: 2 hidden entries under extra/ in this archive were NOT restored" "hidden skipped"
assert_contains "$e" "  WARNING: 1 symbolic links or other non-regular entries under extra/ in this archive were NOT restored" "symlink skipped"
assert_contains "$e" "  Restored 5 extra persistent files" "extra count"
for f in /usr/sbin/evil /lib/functions.sh /etc/rc.button/reset /etc/firewall.user; do assert_contains "$e" "  $f" "restore flags $f"; done
not_contains "$e" "  /etc/plain" "an ordinary /etc file is not flagged"
not_contains "$e" "gl-helper" "a skipped file is not listed as restored"
i=$(run_cmd inspect "$T/e1.tgz"); s=$(printf '%s' "$i" | jsonfilter -e '@.startup_and_login_files')
for f in /usr/sbin/evil /lib/functions.sh /etc/rc.button/reset /etc/firewall.user; do assert_contains "$s" "\"$f\"" "inspect flags $f"; done
not_contains "$s" "plain" "inspect: ordinary file not flagged"; not_contains "$s" "hidden" "inspect: skipped file not flagged"

# Every entry of the flagged list, one by one (a mutation dropping any of them must fail here).
for f in etc/rc.local etc/crontabs/root etc/dropbear/authorized_keys etc/shadow etc/passwd etc/group \
         etc/init.d/x etc/rc.d/S99x etc/hotplug.d/iface/99-x etc/uci-defaults/99-x etc/sysupgrade.conf \
         etc/profile etc/profile.d/x.sh etc/dropbear/dropbear_rsa_host_key etc/rc.button/reset etc/firewall.user \
         etc/sysctl.conf etc/sysctl.d/99-x.conf etc/inittab etc/opkg/customfeeds.conf etc/hotplug-preinit.d/x \
         etc/rc.common etc/preinit usr/bin/x; do
    got=$(printf '%s\n' "$P/extra/$f" | startup_login_members)
    assert_eq "$got" "/$f" "flagged: /$f"
done
assert_eq "$(printf '%s\n' "$P/extra/etc/plain" "$P/extra/etc/crontabs/" "$P/config/x" | startup_login_members)" "" "unflagged entries"

# Capture applies the hidden rule to the persistent-file list too.
S="$T/root"; mkdir -p "$S/etc/config" "$S/etc/keep/.h" "$S/usr/lib/opkg"
cat > "$S/etc/board.json" <<'JSON'
{"model":{"id":"glinet,mt3000-snand","name":"Test Router"},"network":{"lan":{"macaddr":"02:00:00:00:00:01"}}}
JSON
echo "4.11.0" > "$S/etc/glversion"; : > "$S/usr/lib/opkg/status"
echo 'system.@system[0].hostname=TESTHOST' >> "$MOCK_UCI_FILE"
echo "config interface 'lan'" > "$S/etc/config/network"
echo v > "$S/etc/keep/visible"; echo h > "$S/etc/keep/.dot"; echo h > "$S/etc/keep/.h/inner"
printf '/etc/keep/\n' > "$S/lib/upgrade/keep.d/keep"
mkdir -p "$T/oc"
a=$(sh -c '. "$0"; cmd_create "$@"' "$BACKEND" --mode full --output "$T/oc" 2>"$T/cerr"); rc=$?
assert_eq "$rc" 0 "create (hidden persistent files)"
l=$(tar -tzf "$a")
assert_contains "$l" "extra/etc/keep/visible" "visible persistent file captured"
not_contains "$l" ".dot" "hidden persistent file not captured"; not_contains "$l" "inner" "file in a hidden dir not captured"
assert_contains "$(cat "$T/cerr")" "  Skipped 2 hidden entries in the persistent-file list" "hidden persistent count"

# ─── I1 a failed copy stops the restore ──────────────────────────────────────
mk "$T/ok.tgz" "M:$P/manifest.json" "f:$P/config/network" "f:$P/extra/etc/crontabs/root"
R="$T/r-i1a"; fresh_root "$R"; mkdir -p "$R/etc/config/network/sub"   # a directory where a file must go
rc=0; out=$(restore_into "$R" "$T/ok.tgz" 2>"$T/err") || rc=$?
[ "$rc" -ne 0 ] || { echo "  config copy failure reported success: $out"; exit 1; }
not_contains "$out" "RESTORE_OK" "no RESTORE_OK after a config copy failure"
assert_contains "$(cat "$T/err")" "ERROR: config restore failed" "config failure named"
not_contains "$(cat "$T/err")" "Restored " "no restored count after a config copy failure"
R="$T/r-i1b"; fresh_root "$R"; echo file > "$R/etc/crontabs"   # a file where a directory must go
rc=0; out=$(restore_into "$R" "$T/ok.tgz" 2>"$T/err") || rc=$?
[ "$rc" -ne 0 ] || { echo "  extra copy failure reported success: $out"; exit 1; }
not_contains "$out" "RESTORE_OK" "no RESTORE_OK after an extra copy failure"
assert_contains "$(cat "$T/err")" "ERROR: extra file restore failed" "extra failure named"

# ─── a normal archive still passes every gate ────────────────────────────────
R="$T/r-ok"; fresh_root "$R"
out=$(restore_into "$R" "$T/ok.tgz" 2>"$T/err"); rc=$?
assert_eq "$rc" 0 "normal archive restores"; assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "RESTORE_OK" "normal RESTORE_OK"
not_contains "$(cat "$T/err")" "were NOT restored" "nothing dropped from a normal archive"
run_cmd inspect "$T/ok.tgz" >/dev/null || { echo "  normal archive refused by inspect"; exit 1; }
run_cmd fingerprint "$T/ok.tgz" >/dev/null || { echo "  normal archive refused by fingerprint"; exit 1; }
echo "ok 45-archive-hardening"
