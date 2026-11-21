#!/bin/sh
# gl-portable-backup — on-router smoke test.
#
# Runs the release candidate's backend on a real GL.iNet router, where BusyBox applets, the live
# firmware's API surface and the real /rom tree replace the laptop harness's mocks. This is the
# lint-the-instrument gate for a release: every applet the backend depends on is checked against a
# known answer here, in both directions where a direction exists.
#
# Usage: [GPB_SMOKE_SSH_PORT=<port>] tests/on-router-smoke.sh <router-ip> [user]
#        (key-based SSH; scp -O, no sftp on GL; GPB_SMOKE_SSH_PORT defaults to 22)
#
# Writes a full log to tests/smoke-logs/smoke-<YYYYmmdd-HHMMSS>.log. That directory is git-ignored
# and a log is never committed: it carries the target's hostname, archive names and fingerprints.
#
# What it touches on the router: nothing outside /tmp/gpb-smoke*, removed by the remote driver's
# EXIT trap. Nothing is installed. `create` reads the live configuration — that is the point — but
# every archive it writes lands in /tmp/gpb-smoke/. `restore` runs only against a synthetic source
# tree under /tmp/gpb-smoke/src with GPB_ROOT pointed at a scratch target, never against the live
# root and never in a mode that calls uci. The md5 of the live SSH/network/DDNS files is recorded
# before and after and compared as the last check.
set -u

usage() { echo "usage: [GPB_SMOKE_SSH_PORT=<port>] tests/on-router-smoke.sh <router-ip> [user]" >&2; exit 2; }
[ $# -ge 1 ] || usage
IP="$1"
USER_="${2:-root}"
case "$IP" in -*|"") usage ;; esac

HERE=$(cd "$(dirname "$0")/.." && pwd)
BACKEND="$HERE/luci-app-gl-portable-backup/root/usr/sbin/gl-portable-backup"
[ -f "$BACKEND" ] || { echo "missing backend: $BACKEND" >&2; exit 2; }

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
# Every ssh call takes -p and every scp call -P from this one value.
SSH_PORT="${GPB_SMOKE_SSH_PORT:-22}"
case "$SSH_PORT" in ''|*[!0-9]*) echo "GPB_SMOKE_SSH_PORT must be a port number" >&2; exit 2 ;; esac
REMOTE="$USER_@$IP"
D=/tmp/gpb-smoke

LOGDIR="$HERE/tests/smoke-logs"
mkdir -p "$LOGDIR" || exit 2
LOG="$LOGDIR/smoke-$(date +%Y%m%d-%H%M%S).log"

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

# The driver is copied to the router and run from a file rather than fed to `sh -s`: a script read
# from stdin is corrupted by anything inside it that also reads stdin.
cat > "$TMP/driver.sh" <<'REMOTE_DRIVER'
#!/bin/sh
# Runs ON the router. Writes only under /tmp/gpb-smoke*; no opkg install, no uci write, no
# /etc/init.d, nothing under /etc, /overlay, /www or /usr.
set -u
D=/tmp/gpb-smoke
GPB="$D/gl-portable-backup"
TMPDIR="$D/tmp"; export TMPDIR
trap 'rm -rf /tmp/gpb-smoke*' EXIT INT TERM HUP

pass=0; fail=0
# judge <name> <rc> [observation]: the raw observation is printed next to every verdict so a
# surprising result is triageable without another run.
judge() {
    if [ "$2" = 0 ]; then pass=$((pass + 1)); echo "OK: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi
    if [ -n "${3:-}" ]; then printf '%s\n' "$3" | sed 's/^/    | /'; fi
    return 0
}

# tar -tzf into a file, keeping BOTH its exit status and its size. Every "must not contain" check
# below is vacuously true against an empty or unreadable listing, so both are judged before use.
listing() {   # archive listfile ; sets LIST_RC and LIST_N
    tar -tzf "$1" > "$2" 2>"$2.err"; LIST_RC=$?
    LIST_N=$(wc -l < "$2" 2>/dev/null); [ -n "$LIST_N" ] || LIST_N=0
}

mkdir -p "$D/tmp" "$D/out" "$D/x" "$D/fakebin" || exit 2
[ -f "$GPB" ] || { echo "FAIL: backend not copied to $GPB"; echo "passed=0 failed=1"; exit 1; }

# Live files that must be byte-identical before and after the whole run.
snapshot() { md5sum /etc/dropbear/* /etc/config/network /etc/config/gl_ddns 2>&1 | sort; }
snapshot > "$D/md5.before"

echo "== environment =="
echo "    | $(sh "$GPB" version 2>&1) | firmware $(cat /etc/glversion 2>/dev/null) | $(jsonfilter -i /etc/board.json -e '@.model.id' 2>/dev/null)"

echo "== a. parameter-expansion lint =="
cat > "$D/exp.sh" <<'EOS'
f(){ p="${1-}"; [ -n "$p" ] || p='{}'; echo "[$p]"; }
f
f '{}'
EOS
got=$(sh "$D/exp.sh" 2>&1 | tr '\n' ' ')
[ "$got" = "[{}] [{}] " ]; r=$?
judge 'expansion: ${1-} plus default yields {} for both argument shapes' "$r" "got: $got(expected '[{}] [{}] ')"
# The instrument has to discriminate, so the two pre-1.1 idioms are checked here too: each is
# still wrong in exactly the argument shape it was wrong in (verified on this router's ash).
cat > "$D/exp_old.sh" <<'EOS'
g(){ p="${1:-{}}"; echo "[$p]"; }
g
g '{"a":1}'
EOS
cat > "$D/exp_olde.sh" <<'EOS'
g(){ p="${1:-\{\}}"; echo "[$p]"; }
g
g '{"a":1}'
EOS
o1=$(sh "$D/exp_old.sh" 2>&1 | tr '\n' ' ')
o2=$(sh "$D/exp_olde.sh" 2>&1 | tr '\n' ' ')
[ "$o1" = '[{}] [{"a":1}}] ' ] && [ "$o2" = '[\{}] [{"a":1}] ' ]; r=$?
judge 'expansion: both pre-1.1 idioms still fail where they failed (issue #1 B1 fence)' "$r" \
    "\${4:-{}} -> $o1   \${4:-\\{\\}} -> $o2"

echo "== b. applet known-answer lints =="
n=$(printf 'abc \t\n' | sed 's/[ \t]*$//' | wc -c)
[ "$n" = "4" ]; r=$?
judge 'applet: sed [ \t] strips a trailing space and tab (keep.d line parser)' "$r" "wc -c = $n (expected 4)"

# The same instrument in the other direction. The check above proves [ \t] matches a TAB; it
# cannot tell whether it ALSO matches a literal t, which it would if this sed read the two
# characters as a backslash and a t rather than as an escape. Were that so, every keep.d path
# ending in t -- installed_packages.txt, url.txt -- would be silently truncated by the parser.
lt=$(printf 'abct \t\n' | sed 's/[ \t]*$//')
[ "$lt" = "abct" ]; r=$?
judge 'applet: sed [ \t] leaves a trailing literal t alone (keep.d paths ending in t)' "$r" \
    "got [$lt] (expected [abct])"

n=$(printf 'a\nb\n' | wc -l)
[ "$n" = "2" ]; r=$?
judge 'applet: wc -l prints an unpadded count (capture/restore counters)' "$r" "wc -l = [$n] (expected [2])"

printf '1\n2\n3\n' > "$D/3lines"
d1=$(sed '$d' "$D/3lines" | tr '\n' '|')
d2=$(sed '$ s/$/,/' "$D/3lines" | tr '\n' '|')
[ "$d1" = "1|2|" ] && [ "$d2" = "1|2|3,|" ]; r=$?
judge 'applet: sed $d and $ s/$/,/ (inspect rewrites the manifest tail)' "$r" "\$d -> $d1   \$ s/\$/,/ -> $d2"

h=$(printf 'abcdefgh' | head -c 5)
[ "$h" = "abcde" ]; r=$?
judge 'applet: head -c truncates (API error messages)' "$r" "head -c 5 -> $h (expected abcde)"

echo x > "$D/cmp_a"; echo x > "$D/cmp_b"; echo y > "$D/cmp_c"
cmp -s "$D/cmp_a" "$D/cmp_b"; r1=$?
cmp -s "$D/cmp_a" "$D/cmp_c"; r2=$?
[ "$r1" = 0 ] && [ "$r2" != 0 ]; r=$?
judge 'applet: cmp -s answers both directions (is_rom_identical)' "$r" "identical rc=$r1 (expected 0), differing rc=$r2 (expected non-zero)"

mkdir -p "$D/cpsrc/sub" "$D/cpdst"; echo hi > "$D/cpsrc/.dot"; echo deep > "$D/cpsrc/sub/f"
cp -a "$D/cpsrc/." "$D/cpdst/" 2>"$D/cp.err"
[ -f "$D/cpdst/.dot" ] && [ -f "$D/cpdst/sub/f" ]; r=$?
judge 'applet: cp -a SRC/. DST/ carries dotfiles and subdirectories (config tree copy)' "$r" \
    "$(find "$D/cpdst" | sed "s|$D/cpdst|DST|" | sort | tr '\n' ' ')$(cat "$D/cp.err")"

( cd "$D" && tar -czf "$D/t.tgz" cpsrc ) 2>/dev/null
lst=$(tar -tzf "$D/t.tgz" 2>/dev/null | tr '\n' ' ')
printf '%s' "$lst" | grep -q 'cpsrc/sub/f'; r=$?
judge 'applet: tar -tzf lists nested members' "$r" "$lst"

dropbearkey -t ed25519 -f "$D/k" >"$D/k.gen" 2>&1
fp=$(dropbearkey -y -f "$D/k" 2>/dev/null | grep -i '^Fingerprint:')
case "$fp" in "Fingerprint: SHA256:"*) r=0 ;; *) r=1 ;; esac
judge 'applet: dropbearkey -y -f prints a SHA256 fingerprint (host-key warning)' "$r" "$fp"

# Archive members under extra/ that are NOT under extra/etc/. The rule being checked is "user
# configuration lives in /etc", so the predicate has to cover the whole subtree rather than the
# three directory names usr/lib/var. The `.` after extra/ drops tar's own member for the extra/
# directory itself, which ends in a slash.
outside_etc() { grep -E '^gl-portable-backup/extra/.' "$1" | grep -v -E '^gl-portable-backup/extra/etc/'; }

# The guard that makes the "must not contain" checks non-vacuous is itself checked in all three
# directions: an empty listing must fail the predicate, a populated clean one must pass it, and one
# carrying a member outside /etc must fail it.
: > "$D/empty.list"
printf 'gl-portable-backup/manifest.json\ngl-portable-backup/extra/\ngl-portable-backup/extra/etc/\ngl-portable-backup/extra/etc/userconf\n' > "$D/clean.list"
printf 'gl-portable-backup/manifest.json\ngl-portable-backup/extra/usr/bin/plugin-bin\n' > "$D/dirty.list"
vacuity_guard() {   # 0 only when the listing is usable AND carries no offending member
    vn=$(wc -l < "$1" 2>/dev/null); [ -n "$vn" ] || vn=0
    vm=$(outside_etc "$1")
    [ "$vn" -gt 0 ] && [ -z "$vm" ]
}
vacuity_guard "$D/empty.list"; ve=$?
vacuity_guard "$D/clean.list"; vc=$?
vacuity_guard "$D/dirty.list"; vd=$?
[ "$ve" != 0 ] && [ "$vc" = 0 ] && [ "$vd" != 0 ]; r=$?
judge 'vacuity guard: empty listing fails, populated clean one passes, one with a member outside /etc fails' "$r" \
    "empty rc=$ve (expected non-zero)   clean rc=$vc (expected 0)   outside-/etc rc=$vd (expected non-zero)"

echo "== c. create --mode full on the live configuration =="
arch=$(sh "$GPB" create --mode full --output "$D/out" 2>"$D/full.err"); r=$?
arch=${arch:-$D/no-archive}
[ "$r" = 0 ] && [ -f "$arch" ]; r2=$?
judge 'create --mode full --output <directory> (B9: directory output)' "$r2" "rc=$r archive=$arch"

cap=$(sed -n 's/.*Captured \([0-9][0-9]*\) extra persistent files.*/\1/p' "$D/full.err")
skp=$(sed -n 's/.*Skipped \([0-9][0-9]*\) firmware-owned, \([0-9][0-9]*\) identical to \/rom.*/\1 \2/p' "$D/full.err")
[ -n "$cap" ] && [ -n "$skp" ]; r=$?
judge 'create full: reports the captured and skipped counts' "$r" \
    "$(grep -F -e 'Captured' -e 'Skipped' "$D/full.err" | tr '\n' ';')"

listing "$arch" "$D/full.list"; full_n=$LIST_N
[ "$LIST_RC" = 0 ] && [ "$full_n" -gt 0 ]; r=$?
judge 'create full: the archive listing is readable and non-empty' "$r" \
    "tar rc=$LIST_RC members=$full_n $(cat "$D/full.list.err")"
grep -q -F -x 'gl-portable-backup/manifest.json' "$D/full.list" && grep -q -F -x 'gl-portable-backup/config/network' "$D/full.list"; r=$?
judge 'create full: archive holds manifest.json and config/network' "$r" \
    "$(grep -F -x -e 'gl-portable-backup/manifest.json' -e 'gl-portable-backup/config/network' "$D/full.list" | tr '\n' ' ')$(cat "$D/full.list.err")"

outside=$(outside_etc "$D/full.list" | head -n 5 | tr '\n' ' ')
[ "$full_n" -gt 0 ] && [ -z "$outside" ]; r=$?
judge 'create full: nothing outside /etc (no member under extra/ other than extra/etc/)' "$r" \
    "listing lines=$full_n   members: ${outside:-<none>}"

sh "$GPB" inspect "$arch" > "$D/insp.json" 2>"$D/insp.err"; r=$?
fv=$(jsonfilter -e '@.format_version' < "$D/insp.json" 2>/dev/null)
[ "$r" = 0 ] && [ "$fv" = 4 ]; r2=$?
judge 'inspect full: output parses as JSON, format_version=4' "$r2" "rc=$r format_version=[$fv] $(cat "$D/insp.err")"

grep -q -F '"restores_ssh_host_keys": true' "$D/insp.json" && grep -q -F '"restores_root_password": true' "$D/insp.json"; r=$?
judge 'inspect full: reports the SSH host-key and root-password overwrite' "$r" \
    "$(grep -F -e 'restores_ssh_host_keys' -e 'restores_root_password' "$D/insp.json" | tr '\n' ' ')"

rm -rf "$D/x"; mkdir -p "$D/x"
tar -xzf "$arch" -C "$D/x" gl-portable-backup/backup-info.txt 2>"$D/x.err"
sk=$(sed -n 's/^Skipped: *//p' "$D/x/gl-portable-backup/backup-info.txt" 2>/dev/null)
[ -n "$sk" ]; r=$?
judge 'backup-info.txt carries the Skipped line' "$r" "Skipped: ${sk:-<absent>} $(cat "$D/x.err")"

fpa=$(sh "$GPB" fingerprint "$arch" 2>"$D/fp.err")
case "$fpa" in *"Fingerprint: SHA256:"*) r=0 ;; *) r=1 ;; esac
judge 'fingerprint full: prints the host-key fingerprint the archive would install' "$r" "$fpa $(cat "$D/fp.err")"

echo "== d. create --mode full --include-plugins =="
arch2="$D/out/full-include-plugins.tar.gz"
sh "$GPB" create --mode full --include-plugins --output "$arch2" >"$D/plug.out" 2>"$D/plug.err"; r=$?
[ "$r" = 0 ] && [ -f "$arch2" ]; r2=$?
judge 'create --mode full --include-plugins' "$r2" "rc=$r $(grep -F -e 'Captured' -e 'Skipped' "$D/plug.err" | tr '\n' ';')"
listing "$arch2" "$D/plug.list"; plug_n=$LIST_N
inc=$(outside_etc "$D/plug.list" | wc -l)
noinc=$(outside_etc "$D/full.list" | wc -l)
judge 'observation: members outside /etc, with and without --include-plugins' 0 \
    "--include-plugins: $inc of $plug_n members (tar rc=$LIST_RC)    default: $noinc of $full_n    sample: $(outside_etc "$D/plug.list" | head -n 3 | tr '\n' ' ')"

echo "== e. create --mode clone and --mode remote-safe =="
cl=$(sh "$GPB" create --mode clone --output "$D/out" 2>"$D/clone.err"); r=$?
cl=${cl:-$D/no-clone}
[ "$r" = 0 ] && [ -f "$cl" ]; r2=$?
judge 'create --mode clone' "$r2" "rc=$r archive=$cl"
listing "$cl" "$D/clone.list"; clone_n=$LIST_N
[ "$LIST_RC" = 0 ] && [ "$clone_n" -gt 0 ]; r=$?
judge 'create clone: the archive listing is readable and non-empty' "$r" \
    "tar rc=$LIST_RC members=$clone_n $(cat "$D/clone.list.err")"
sh "$GPB" inspect "$cl" > "$D/clone.insp" 2>/dev/null
grep -q -F '"restores_ssh_host_keys": false' "$D/clone.insp" && grep -q -F '"restores_root_password": false' "$D/clone.insp"; r=$?
judge 'inspect clone: both overwrite flags false' "$r" \
    "$(grep -F -e 'restores_ssh_host_keys' -e 'restores_root_password' "$D/clone.insp" | tr '\n' ' ')"
leak=$(grep -E 'extra/etc/dropbear/dropbear_|extra/etc/shadow$' "$D/clone.list" | tr '\n' ' ')
[ "$clone_n" -gt 0 ] && [ -z "$leak" ]; r=$?
judge 'create clone: no SSH host keys and no /etc/shadow in the archive' "$r" \
    "listing lines=$clone_n   members: ${leak:-<none>}"

rs=$(sh "$GPB" create --mode remote-safe --output "$D/out" 2>"$D/rs.err"); r=$?
rs=${rs:-$D/no-rs}
[ "$r" = 0 ] && [ -f "$rs" ]; r2=$?
judge 'create --mode remote-safe' "$r2" "rc=$r archive=$rs"
listing "$rs" "$D/rs.list"; rs_n=$LIST_N
[ "$LIST_RC" = 0 ] && [ "$rs_n" -gt 0 ]; r=$?
judge 'create remote-safe: the archive listing is readable and non-empty' "$r" \
    "tar rc=$LIST_RC members=$rs_n $(cat "$D/rs.list.err")"
sh "$GPB" inspect "$rs" > "$D/rs.insp" 2>/dev/null
grep -q -F '"restores_ssh_host_keys": false' "$D/rs.insp" && grep -q -F '"restores_root_password": false' "$D/rs.insp"; r=$?
judge 'inspect remote-safe: both overwrite flags false' "$r" \
    "$(grep -F -e 'restores_ssh_host_keys' -e 'restores_root_password' "$D/rs.insp" | tr '\n' ' ')"
leak=$(grep -E 'extra/etc/dropbear/dropbear_|extra/etc/shadow$' "$D/rs.list" | tr '\n' ' ')
[ "$rs_n" -gt 0 ] && [ -z "$leak" ]; r=$?
judge 'create remote-safe: no SSH host keys and no /etc/shadow in the archive' "$r" \
    "listing lines=$rs_n   members: ${leak:-<none>}"
leak=$(grep -E 'config/(zerotier|tailscale|gl-cloud)$' "$D/rs.list" | tr '\n' ' ')
[ "$rs_n" -gt 0 ] && [ -z "$leak" ]; r=$?
judge 'create remote-safe: zerotier, tailscale and gl-cloud configs excluded' "$r" \
    "listing lines=$rs_n   members: ${leak:-<none>}   (clone for contrast: $(grep -E 'config/(zerotier|tailscale|gl-cloud)$' "$D/clone.list" | tr '\n' ' '))"

echo "== f. create --mode profile (real local-API authentication) =="
pr=$(sh "$GPB" create --mode profile --output "$D/out" 2>"$D/profile.err"); r=$?
pr=${pr:-$D/no-profile}
[ "$r" = 0 ] && [ -f "$pr" ]; r2=$?
judge 'create --mode profile' "$r2" "rc=$r archive=$pr"
listing "$pr" "$D/profile.list"; profile_n=$LIST_N
[ "$LIST_RC" = 0 ] && [ "$profile_n" -gt 0 ]; r=$?
judge 'create profile: the archive listing is readable and non-empty' "$r" \
    "tar rc=$LIST_RC members=$profile_n $(cat "$D/profile.list.err")"
sh "$GPB" inspect "$pr" > "$D/profile.insp" 2>/dev/null
fv=$(jsonfilter -e '@.format_version' < "$D/profile.insp" 2>/dev/null)
[ "$fv" = 4 ]; r=$?
judge 'inspect profile: format_version=4' "$r" "format_version=[$fv]"
apis=$(sed -n 's|^gl-portable-backup/api/||p' "$D/profile.list" | sort | tr '\n' ' ')
# Which LAN module this firmware ships decides which capture to expect: vlan_subnet from 4.11 on, lan
# before it (4.9.0 ships lan). A bare file is a Lua module, NAME.so a compiled one.
RPCD=/usr/lib/oui-httpd/rpc
if [ -e "$RPCD/vlan_subnet" ] || [ -e "$RPCD/vlan_subnet.so" ]; then
    lan_case=vlan_subnet; lan_want=vlan_subnet.get_subnets.json; lan_not='lan\.'
elif [ -e "$RPCD/lan" ] || [ -e "$RPCD/lan.so" ]; then
    lan_case=lan; lan_want=lan.get_config_list.json; lan_not='vlan_subnet\.'
else
    lan_case=neither; lan_want=""; lan_not=""
fi
missing=""
[ -n "$lan_want" ] || missing=" (this firmware ships neither vlan_subnet nor lan under $RPCD)"
for want in $lan_want wifi.get_config.json dns.get_config.json; do
    case " $apis " in *" $want "*) ;; *) missing="$missing $want" ;; esac
done
[ -z "$missing" ]; r=$?
judge "create profile: the three required API captures are present (LAN module: $lan_case)" "$r" \
    "missing:${missing:- <none>}   captured: $apis"
# Profile carries no device identity: no system.get_info reply, no hardware.json, and no radio
# BSSID in the stored Wi-Fi reply (the member is read straight from the archive, never printed).
idmem=$(grep -E '^gl-portable-backup/(hardware\.json$|api/system\.get_info\.json$)' "$D/profile.list" | tr '\n' ' ')
[ "$profile_n" -gt 0 ] && [ -z "$idmem" ]; r=$?
judge 'create profile: neither system.get_info nor hardware.json is in the archive' "$r" \
    "listing lines=$profile_n   members: ${idmem:-<none>}"
tar -xzOf "$pr" gl-portable-backup/api/wifi.get_config.json > "$D/profile.wifi" 2>/dev/null; wr=$?
[ "$wr" = 0 ] && [ -s "$D/profile.wifi" ] && ! grep -q -F '"bssid"' "$D/profile.wifi"; r=$?
judge 'create profile: the stored wifi.get_config reply contains no "bssid"' "$r" \
    "tar rc=$wr bytes=$(wc -c < "$D/profile.wifi" 2>/dev/null)"
# No hardware address of this router may remain in any stored reply: every MAC-shaped value of
# /etc/board.json is looked for, in either letter case, in every api/ member. Counts only — no address
# and no reply body is printed.
tr '\n' ' ' < /etc/board.json | grep -o '[0-9A-Fa-f][0-9A-Fa-f]\(:[0-9A-Fa-f][0-9A-Fa-f]\)\{5\}' | tr 'a-f' 'A-F' | sort -u > "$D/board.macs"
nb=$(grep -c . "$D/board.macs"); mkdir -p "$D/prx"; tar -xzf "$pr" -C "$D/prx" 2>/dev/null
na=0; hits=0
for f in "$D"/prx/gl-portable-backup/api/*.json; do
    [ -f "$f" ] || continue; na=$((na + 1))
    while IFS= read -r mac; do grep -q -i -F "$mac" "$f" && hits=$((hits + 1)); done < "$D/board.macs"
done
[ "$nb" -gt 0 ] && [ "$na" -gt 0 ] && [ "$hits" = 0 ]; r=$?
judge 'create profile: no MAC-shaped value of /etc/board.json appears in any api/ member' "$r" \
    "board.json addresses=$nb  api members=$na  address hits=$hits"
idc=$(jsonfilter -e '@.identity_checked' < "$D/profile.insp" 2>/dev/null)
idr=$(jsonfilter -e '@.identity_residue' < "$D/profile.insp" 2>/dev/null)
[ "$idc" = true ] && [ "$(printf '%s' "$idr" | tr -d ' []')" = "" ]; r=$?
judge 'inspect profile: identity_checked=true and identity_residue empty' "$r" "identity_checked=[$idc] residue entries=$(printf '%s' "$idr" | tr -cd ',' | wc -c)+"
rm -rf "$D/prx"
if [ -n "$lan_not" ]; then
    lanmem=$(grep -E "^gl-portable-backup/api/$lan_not" "$D/profile.list" | tr '\n' ' ')
    [ "$profile_n" -gt 0 ] && [ -z "$lanmem" ]; r=$?
else
    lanmem="(no LAN module found: vlan_subnet or lan)"; r=1
fi
case "$lan_case" in vlan_subnet) other=lan ;; lan) other=vlan_subnet ;; *) other="lan or vlan_subnet" ;; esac
judge "create profile: no $other.* capture (this firmware ships $lan_case)" "$r" \
    "listing lines=$profile_n   members: ${lanmem:-<none>}"
# The argument shape issue #1's B1 broke: gl_api WITH a params object. No capture call passes one,
# so nothing above exercises it. system.get_info is a getter (not captured into the archive, see above), so this stays read-only. The reply
# body is never printed — it carries the hostname and MAC addresses.
cat > "$D/api4.sh" <<'EOS'
GPB_LIB_ONLY=1 . "$1" || exit 9
sid=$(gl_auth) || exit 9
reply=$(gl_api "$sid" system get_info '{}') || exit 8
has_result=no; has_parse_error=no
case "$reply" in *'"result"'*) has_result=yes ;; esac
case "$reply" in *-32700*) has_parse_error=yes ;; esac
echo "result=$has_result parse_error=$has_parse_error"
[ "$has_result" = yes ] && [ "$has_parse_error" = no ]
EOS
a4=$(sh "$D/api4.sh" "$GPB" 2>"$D/api4.err"); r=$?
a4err=""; [ "$r" = 0 ] || a4err="   stderr: $(head -c 160 "$D/api4.err")"
judge 'gl_api with a params argument returns a result, not -32700 (issue #1 B1, the shape that broke)' "$r" \
    "rc=$r  $a4$a4err"

warns=$(grep -F 'WARNING:' "$D/profile.err" | sed 's/^ *//' | tr '\n' ';')
judge 'observation: API calls this firmware refused' 0 "${warns:-<none>}"

echo "== g. forced authentication failure =="
printf '#!/bin/sh\nexit 7\n' > "$D/fakebin/curl"; chmod 0755 "$D/fakebin/curl"
PATH="$D/fakebin:$PATH" sh "$GPB" create --mode profile --output "$D/out2" >"$D/g.out" 2>"$D/g.err"; r=$?
[ "$r" = 1 ]; r2=$?
judge 'auth failure: exit status 1' "$r2" "rc=$r"
grep -q -F 'auth: challenge failed (curl exit 7)' "$D/g.err" && grep -q -F 'ERROR: Failed to authenticate' "$D/g.err"; r=$?
judge 'auth failure: both diagnostic lines reach stderr (issue #1 B8)' "$r" "$(tr '\n' ';' < "$D/g.err")"
[ ! -e "$D/out2" ]; r=$?
judge 'auth failure: no archive created' "$r" "$(ls -d "$D/out2" 2>&1)"

echo "== h. synthetic-root create and restore =="
S="$D/src"
mkdir -p "$S/etc/config/cellular" "$S/etc/config/gl_nas" "$S/etc/dropbear" "$S/usr/lib/opkg" "$S/lib/upgrade/keep.d"
cp /etc/board.json "$S/etc/board.json"
cp /etc/glversion "$S/etc/glversion"
cp /etc/openwrt_release "$S/etc/openwrt_release"
printf 'Package: gpb-smoke-pkg\nStatus: install user installed\n' > "$S/usr/lib/opkg/status"
# The incident check reads the synthetic root's /proc: one harmless process and an empty TCP table,
# so the archive below is not made a record by a check that found nothing to read.
mkdir -p "$S/proc/4243" "$S/proc/net"
printf '%s\000' /usr/sbin/crond -f -c /etc/crontabs -l 5 > "$S/proc/4243/cmdline"
head -n 1 /proc/net/tcp > "$S/proc/net/tcp"
echo "config interface 'smoke'" > "$S/etc/config/network"
echo '{"smoke":true}' > "$S/etc/config/cellular/x.json"
echo 'smoke-not-a-certificate' > "$S/etc/config/gl_nas/y.pem"
printf '/etc/dropbear/\n' > "$S/lib/upgrade/keep.d/dropbear"
printf '/etc/shadow\n' > "$S/lib/upgrade/keep.d/base-files-essential"
dropbearkey -t ed25519 -f "$S/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1
echo 'ssh-ed25519 AAAAsmokeauthorizedkey smoke' > "$S/etc/dropbear/authorized_keys"
echo 'root:x:1::::::' > "$S/etc/shadow"
[ ! -e "$S/etc/config/gl_ddns" ]; r=$?
judge 'synthetic source has no gl_ddns (restore must not touch the live DDNS service)' "$r" \
    "$(find "$S/etc/config" | sed "s|$S|SRC|" | sort | tr '\n' ' ')"

sarch="$D/out3"
GPB_ROOT="$S" sh "$GPB" create --mode full --output "$sarch" >"$D/syn.out" 2>"$D/syn.err"; r=$?
[ "$r" = 0 ] && [ -f "$sarch" ]; r2=$?
judge 'synthetic: create --mode full with GPB_ROOT' "$r2" "rc=$r $(grep -F -e 'Captured' -e 'Skipped' "$D/syn.err" | tr '\n' ';')"
listing "$sarch" "$D/syn.list"; syn_n=$LIST_N
[ "$LIST_RC" = 0 ] && [ "$syn_n" -gt 0 ]; r=$?
judge 'synthetic: the archive listing is readable and non-empty' "$r" \
    "tar rc=$LIST_RC members=$syn_n $(cat "$D/syn.list.err")"
grep -q -F 'gl-portable-backup/config/cellular/x.json' "$D/syn.list" \
    && grep -q -F 'gl-portable-backup/config/gl_nas/y.pem' "$D/syn.list" \
    && grep -q -F 'gl-portable-backup/extra/etc/dropbear/authorized_keys' "$D/syn.list"; r=$?
judge 'synthetic: both config directories and the keep.d files are in the archive' "$r" \
    "$(grep -E 'cellular|gl_nas|dropbear|shadow' "$D/syn.list" | tr '\n' ' ')"

srcfp=$(dropbearkey -y -f "$S/etc/dropbear/dropbear_ed25519_host_key" 2>/dev/null | grep -i '^Fingerprint:')
arcfp=$(sh "$GPB" fingerprint "$sarch" 2>"$D/sfp.err")
[ -n "$srcfp" ] && [ "$srcfp" = "$arcfp" ]; r=$?
judge 'synthetic: fingerprint matches the source key dropbearkey reports' "$r" "source: $srcfp   archive: $arcfp $(cat "$D/sfp.err")"
srcfp_val=$(printf '%s' "$srcfp" | sed 's/^.*\(SHA256:[A-Za-z0-9+/=]*\).*$/\1/')
srckey_md5=$(md5sum "$S/etc/dropbear/dropbear_ed25519_host_key" | awk '{print $1}')

G="$D/tgt"
mkdir -p "$G/etc/config" "$G/etc/dropbear"
cp /etc/board.json "$G/etc/board.json"; cp /etc/glversion "$G/etc/glversion"
dropbearkey -t ed25519 -f "$G/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1
tgt_md5_before=$(md5sum "$G/etc/dropbear/dropbear_ed25519_host_key" | awk '{print $1}')
out=$(GPB_ROOT="$G" sh "$GPB" restore --keep-host-keys "$sarch" 2>"$D/r1.err"); r=$?
last=$(printf '%s\n' "$out" | tail -n 1)
[ "$r" = 0 ] && [ "$last" = "RESTORE_OK" ]; r2=$?
judge 'synthetic: restore --keep-host-keys exits 0 with RESTORE_OK' "$r2" "rc=$r last stdout line: $last"
grep -q -F "Keeping this device's SSH host keys" "$D/r1.err"; r=$?
judge 'synthetic: restore --keep-host-keys says so' "$r" "$(grep -F -e 'Keeping' -e 'WARNING' "$D/r1.err" | tr '\n' ';')"
tgt_md5_after=$(md5sum "$G/etc/dropbear/dropbear_ed25519_host_key" | awk '{print $1}')
[ "$tgt_md5_before" = "$tgt_md5_after" ] && [ "$tgt_md5_after" != "$srckey_md5" ]; r=$?
judge 'synthetic: --keep-host-keys left the target host key alone' "$r" \
    "target md5 before=$tgt_md5_before after=$tgt_md5_after source=$srckey_md5"
[ "$(cat "$G/etc/dropbear/authorized_keys" 2>/dev/null)" = 'ssh-ed25519 AAAAsmokeauthorizedkey smoke' ]; r=$?
judge 'synthetic: authorized_keys restored even with --keep-host-keys' "$r" "$(cat "$G/etc/dropbear/authorized_keys" 2>&1)"
[ -f "$G/etc/config/cellular/x.json" ] && [ -f "$G/etc/config/gl_nas/y.pem" ]; r=$?
judge 'synthetic: /etc/config directories restored (B3: cellular/, gl_nas/)' "$r" \
    "$(find "$G/etc/config" | sed "s|$G|TGT|" | sort | tr '\n' ' ')"

G2="$D/tgt2"
mkdir -p "$G2/etc/config" "$G2/etc/dropbear"
cp /etc/board.json "$G2/etc/board.json"; cp /etc/glversion "$G2/etc/glversion"
dropbearkey -t ed25519 -f "$G2/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1
out2=$(GPB_ROOT="$G2" sh "$GPB" restore "$sarch" 2>"$D/r2.err"); r=$?
last2=$(printf '%s\n' "$out2" | tail -n 1)
[ "$r" = 0 ] && [ "$last2" = "RESTORE_OK" ]; r2=$?
judge 'synthetic: plain restore exits 0 with RESTORE_OK' "$r2" "rc=$r last stdout line: $last2"
grep -q -F "WARNING: this archive restores the source's SSH host keys" "$D/r2.err" \
    && [ -n "$srcfp_val" ] && grep -q -F "$srcfp_val" "$D/r2.err" \
    && grep -q -F 'WARNING: this archive restores /etc/shadow' "$D/r2.err"; r=$?
judge 'synthetic: plain restore warns about the host keys (with the fingerprint) and /etc/shadow' "$r" \
    "$(grep -F 'WARNING' "$D/r2.err" | tr '\n' ';')"
tgt2_md5=$(md5sum "$G2/etc/dropbear/dropbear_ed25519_host_key" | awk '{print $1}')
[ "$tgt2_md5" = "$srckey_md5" ]; r=$?
judge 'synthetic: plain restore installed the archive host key' "$r" "target2 md5=$tgt2_md5 source md5=$srckey_md5"

echo "== j. incident check =="
# ids_of FILE: the indicator ids of a check reply, space-separated (index by index, so no jsonfilter
# wildcard support is assumed). The details are never printed: only the result and the ids.
ids_of() {   # FILE [ARRAY] — ARRAY defaults to indicators; cannot_clear for the other tier
    local i=0 id acc="" arr="${2:-indicators}"
    while id=$(jsonfilter -i "$1" -e "@.$arr[$i].id" 2>/dev/null); do acc="${acc:+$acc }$id"; i=$((i + 1)); done
    printf '%s' "$acc"
}
sh "$GPB" check > "$D/chk.json" 2>"$D/chk.err"; r=$?
res=$(jsonfilter -i "$D/chk.json" -e '@.result' 2>/dev/null)
reb=$(jsonfilter -i "$D/chk.json" -e '@.rebooted_since_incident' 2>/dev/null)
{ [ "$r" = 0 ] && { [ "$res" = none ] || [ "$res" = inconclusive ]; }; } || { [ "$r" = 3 ] && [ "$res" = indicators ]; }; r2=$?
judge 'check on the live router: parseable JSON, none or inconclusive (exit 0) or indicators (exit 3)' "$r2" \
    "rc=$r result=[${res:-<unreadable>}] ids=[$(ids_of "$D/chk.json")] rebooted_since_incident=[${reb:-<unreadable>}] cannot_clear=[$(ids_of "$D/chk.json" cannot_clear)]"

P="$D/planted"
mkdir -p "$P/etc/config" "$P/tmp" "$P/usr/lib/opkg"
cp /etc/board.json "$P/etc/board.json"; cp /etc/glversion "$P/etc/glversion"; cp /etc/openwrt_release "$P/etc/openwrt_release"
printf 'Package: gpb-smoke-pkg\nStatus: install user installed\n' > "$P/usr/lib/opkg/status"
echo "config interface 'smoke'" > "$P/etc/config/network"
# The synthetic root's own /proc: one harmless process and the live table's header line, no rows.
mkdir -p "$P/proc/4243" "$P/proc/net"
printf '%s\000' /usr/sbin/crond -f -c /etc/crontabs -l 5 > "$P/proc/4243/cmdline"
head -n 1 /proc/net/tcp > "$P/proc/net/tcp"
printf '#!/bin/sh\necho "  PID USER       VSZ STAT COMMAND"\necho " 4242 root      1072 S    crond -i /tmp/.log"\n' > "$D/fakebin/ps"
mkdir -p "$D/fakebin-quiet"
printf '#!/bin/sh\necho "  PID USER       VSZ STAT COMMAND"\necho " 4243 root      1072 S    /usr/sbin/crond -f -c /etc/crontabs -l 5"\n' > "$D/fakebin-quiet/ps"
chmod +x "$D/fakebin/ps" "$D/fakebin-quiet/ps"
# The fake ps is first on PATH and also named by GPB_TEST_PS, so the check reads it whether or not
# this BusyBox sh runs its own applet ahead of PATH.
PATH="$D/fakebin-quiet:$PATH" GPB_TEST_PS="$D/fakebin-quiet/ps" GPB_ROOT="$P" sh "$GPB" check > "$D/chk0.json" 2>&1; r=$?
[ "$r" = 0 ] && [ "$(jsonfilter -i "$D/chk0.json" -e '@.result' 2>/dev/null)" = none ]; r2=$?
judge 'check on a synthetic root without plants: exit 0, result none' "$r2" "rc=$r ids=[$(ids_of "$D/chk0.json")]"
mkfifo "$P/tmp/f"; mkdir -p "$P/etc/config/.gl" "$P/proc/4242"
printf 'crond\000-i\000/tmp/.log\000' > "$P/proc/4242/cmdline"
: > "$P/etc/mp_ip_mapping_info"
# The mapping file is a cannot-clear finding, never a strong one, so it is not among these ids.
want="proc-crond-log tmp-fifo marker-dir"
PATH="$D/fakebin:$PATH" GPB_TEST_PS="$D/fakebin/ps" GPB_ROOT="$P" sh "$GPB" check > "$D/chk3.json" 2>&1; r=$?
pids=$(ids_of "$D/chk3.json")
[ "$r" = 3 ] && [ "$pids" = "$want" ]; r2=$?
judge 'check on the planted synthetic root (/proc cmdline, fifo, marker, mapping file): exit 3 with the expected ids' "$r2" \
    "rc=$r ids=[$pids] expected=[$want] cannot_clear=[$(ids_of "$D/chk3.json" cannot_clear)]"

mkdir -p "$D/out-planted"
parch=$(PATH="$D/fakebin:$PATH" GPB_TEST_PS="$D/fakebin/ps" GPB_ROOT="$P" sh "$GPB" create --mode full --output "$D/out-planted" 2>"$D/pl.err"); r=$?
case "$parch" in *-COMPROMISED-*) pc=0 ;; *) pc=1 ;; esac
[ "$r" = 0 ] && [ -f "$parch" ] && [ "$pc" = 0 ] && grep -q -F 'This backup is a RECORD ONLY.' "$D/pl.err"; r2=$?
judge 'create in the planted state: a -COMPROMISED- archive and the record-only warning' "$r2" \
    "rc=$r archive=$(basename "${parch:-<none>}")"
PG="$D/tgt-planted"
mkdir -p "$PG/etc/config"; cp /etc/board.json "$PG/etc/board.json"; cp /etc/glversion "$PG/etc/glversion"
pbefore=$(find "$PG" | sort | md5sum)
pout=$(GPB_ROOT="$PG" sh "$GPB" restore "$parch" 2>"$D/pr.err"); r=$?
[ "$r" != 0 ] && grep -q -F 'It is a record only and is not restored' "$D/pr.err" \
    && [ "$(find "$PG" | sort | md5sum)" = "$pbefore" ] && ! printf '%s' "$pout" | grep -q RESTORE_OK; r2=$?
judge 'restore of the -COMPROMISED- archive into a scratch root is refused and writes nothing' "$r2" \
    "rc=$r $(grep -F 'ERROR' "$D/pr.err" | head -c 120)"
rr1=$(sh "$GPB" inspect "$parch" 2>/dev/null | jsonfilter -e '@.restore_refused' 2>/dev/null)
rr0=$(sh "$GPB" inspect "$sarch" 2>/dev/null | jsonfilter -e '@.restore_refused' 2>/dev/null)
[ "$rr1" = true ] && [ "$rr0" = false ]; r=$?
judge 'inspect restore_refused: true for the record, false for the synthetic archive of section h' "$r" \
    "record=[${rr1:-<absent>}] synthetic=[${rr0:-<absent>}]"

# Only the mapping file, written now, with multi-path tunnelling off (read from the live uci): the
# result is inconclusive, never indicators, and a backup is not a record.
M="$D/maponly"
mkdir -p "$M/etc/config" "$M/usr/lib/opkg" "$M/proc/4243" "$M/proc/net"
cp /etc/board.json "$M/etc/board.json"; cp /etc/glversion "$M/etc/glversion"; cp /etc/openwrt_release "$M/etc/openwrt_release"
printf 'Package: gpb-smoke-pkg\nStatus: install user installed\n' > "$M/usr/lib/opkg/status"
echo "config interface 'smoke'" > "$M/etc/config/network"
printf '%s\000' /usr/sbin/crond -f -c /etc/crontabs -l 5 > "$M/proc/4243/cmdline"
head -n 1 /proc/net/tcp > "$M/proc/net/tcp"
: > "$M/etc/mp_ip_mapping_info"
mpt=$(uci -q get mptun.global.enable 2>/dev/null)
GPB_ROOT="$M" sh "$GPB" check > "$D/chkm.json" 2>&1; r=$?
mres=$(jsonfilter -i "$D/chkm.json" -e '@.result' 2>/dev/null); mcc=$(ids_of "$D/chkm.json" cannot_clear)
case " $mcc " in *" mp-ip-mapping-file "*) mc=0 ;; *) mc=1 ;; esac
[ "$mpt" != 1 ] && [ "$r" = 0 ] && [ "$mres" = inconclusive ] && [ "$mc" = 0 ] && [ -z "$(ids_of "$D/chkm.json")" ]; r2=$?
judge 'check with only the mapping file planted: exit 0, inconclusive, cannot_clear holds mp-ip-mapping-file' "$r2" \
    "rc=$r result=[$mres] cannot_clear=[$mcc] indicators=[$(ids_of "$D/chkm.json")] mptun.global.enable=[${mpt:-<unset>}]"
mkdir -p "$D/out-maponly"
march=$(GPB_ROOT="$M" sh "$GPB" create --mode full --output "$D/out-maponly" 2>"$D/ml.err"); r=$?
case "$march" in *COMPROMISED*) mc=1 ;; *) mc=0 ;; esac
[ "$r" = 0 ] && [ -f "$march" ] && [ "$mc" = 0 ] && grep -q -F 'cannot be cleared' "$D/ml.err"; r2=$?
judge 'create with only the mapping file planted: not a -COMPROMISED- record, with the cannot-be-cleared warning' "$r2" \
    "rc=$r archive=$(basename "${march:-<none>}")"

echo "== i. self-update mechanisms (nothing installed) =="
# Every primitive the updater relies on, against a known answer in both directions where one exists.
printf 'abc' > "$D/sum.bin"; sha256sum "$D/sum.bin" > "$D/sum.txt"
( cd "$D" && sha256sum -c sum.txt >/dev/null 2>&1 ); r1=$?
printf 'abd' > "$D/sum.bin"; ( cd "$D" && sha256sum -c sum.txt >/dev/null 2>&1 ); r2=$?
[ "$r1" = 0 ] && [ "$r2" != 0 ]; r=$?
judge 'update: sha256sum -c passes a good file and fails a tampered one' "$r" "good rc=$r1 tampered rc=$r2"
( exec 9>>"$D/lock"; flock -n 9 && ( exec 8>>"$D/lock"; flock -n 8 ) ); r=$?
[ "$r" != 0 ]; r=$?
judge 'update: flock -n refuses a lock that is already held' "$r" "inner rc=$r"
rm -f "$D/detached"; S=$(date +%s); sh -c "( sleep 2; date +%s > $D/detached ) </dev/null >/dev/null 2>&1 &"; E=$(( $(date +%s) - S )); sleep 3
[ "$E" -le 1 ] && [ -s "$D/detached" ]; r=$?
judge 'update: the orphaned-subshell detach returns at once and the child finishes' "$r" "parent took ${E}s; child wrote: $(cat "$D/detached" 2>/dev/null || echo nothing)"
for a in nohup setsid; do command -v $a >/dev/null 2>&1 && echo "    | note: $a present on this firmware (the detach pattern does not need it)"; done
code=$(curl -fsS --connect-timeout 15 --max-time 40 -o /dev/null -w '%{http_code}' https://api.github.com/repos/RemoteToHome-io/gl-portable-backup/releases/latest 2>/dev/null); rc=$?
case "$code" in 200|404) r=0 ;; *) r=1 ;; esac
judge 'update: curl reaches the GitHub API over TLS (200 or 404 both prove the path)' "$r" "http=$code curl rc=$rc"
printf 'Package: x\nVersion: 9.8.7\n' > "$D/ctl"; mkdir -p "$D/ipk/c"; cp "$D/ctl" "$D/ipk/c/control"; echo 2.0 > "$D/ipk/debian-binary"
(cd "$D/ipk/c" && tar czf ../control.tar.gz .) && (cd "$D/ipk" && tar czf data.tar.gz -T /dev/null 2>/dev/null || (cd "$D/ipk" && tar czf data.tar.gz debian-binary)) && (cd "$D/ipk" && tar czf ../probe.ipk ./debian-binary ./control.tar.gz ./data.tar.gz)
pv=$(tar -xzOf "$D/probe.ipk" ./control.tar.gz 2>/dev/null | tar -xzOf - 2>/dev/null | sed -n 's/^Version: //p' | head -n 1)
[ "$pv" = 9.8.7 ]; r=$?
judge 'update: tar -O extracts the control Version from a BusyBox-built ipk' "$r" "got=[$pv]"
cl=$(printf 'a\tb\033[0mc' | tr -cd ' -~')
[ "$cl" = "ab[0mc" ]; r=$?
judge 'update: tr -cd keeps printable ASCII only' "$r" "got=[$cl]"
md=$(mktemp -d "$D/tmp/gl-portable-backup-update.XXXXXX" 2>/dev/null); [ -d "$md" ]; r=$?
judge 'update: mktemp -d with a template' "$r" "dir=$md"; rm -rf "$md"
uc=$(sh "$GPB" update-check 2>"$D/uc.err"); r=$?
printf '%s' "$uc" | grep -q '"installed_via_opkg":false' && printf '%s' "$uc" | grep -q '"update_available":false'; r2=$?
judge 'update-check from /tmp: valid reply, not installed via opkg, nothing offered' "$r2" "rc=$r $uc $(cat "$D/uc.err")"
if [ -n "${GPB_FAKE:-}" ]; then
    fetch_case() {   # name expected-substring
        rm -rf "$D/upd/status" "$D"/tmp/gl-portable-backup-update.*
        GPB_UPDATE_STATE="$D/upd" GPB_UPDATE_API_URL="$GPB_FAKE/$1/api/latest" GPB_UPDATE_BASE_URL="$GPB_FAKE/$1/download" \
            sh "$GPB" update-install --fetch-only >"$D/fetch.$1.out" 2>&1; frc=$?
        st=$(cat "$D/upd/status" 2>/dev/null)
        printf '%s' "$st" | grep -q -F "$2"; r=$?
        judge "update fetch-only ($1): $2" "$r" "rc=$frc status: $st"
        left=$(ls -d "$D"/tmp/gl-portable-backup-update.* 2>/dev/null | tr '\n' ' ')
        [ -z "$left" ]; r=$?
        judge "update fetch-only ($1): working directory removed" "$r" "leftovers: ${left:-<none>}"
    }
    fetch_case good "Verified luci-app-gl-portable-backup_99.0.0_all.ipk (version 99.0.0); install skipped"
    fetch_case badsum "Checksum mismatch"
    fetch_case badver "says version '99.0.1' but the release is 99.0.0"
    # update-start must refuse while a worker holds the lock, and prime the status before detaching
    # The state location is a mode-700 directory owned by root; the workers above created it.
    sd=$(ls -ldn "$D/upd" 2>/dev/null | awk '{print $1, $3}')
    [ "$sd" = "drwx------ $(id -u)" ]; r=$?
    judge 'update: the state directory is mode 700 and owned by this user' "$r" "ls -ldn: $sd"
    ( exec 9>>"$D/upd/lock"; flock -n 9; GPB_UPDATE_STATE="$D/upd" sh "$GPB" update-start > "$D/start.locked" 2>&1 )
    grep -q 'already running' "$D/start.locked"; r=$?
    judge 'update-start: refuses while the lock is held' "$r" "$(cat "$D/start.locked")"
    rm -f "$D/upd/status"
    GPB_UPDATE_STATE="$D/upd" GPB_UPDATE_API_URL="$GPB_FAKE/good/api/latest" GPB_UPDATE_BASE_URL="$GPB_FAKE/good/download" \
        sh "$GPB" update-start --fetch-only > "$D/start.out" 2>&1; src=$?
    grep -q '"status":"started"' "$D/start.out"; r=$?
    judge 'update-start: detached fetch-only worker started' "$r" "rc=$src $(cat "$D/start.out")"
    i=0; while [ $i -lt 30 ] && grep -q '"status":"running"' "$D/upd/status" 2>/dev/null; do sleep 1; i=$((i+1)); done
    grep -q 'install skipped' "$D/upd/status" 2>/dev/null; r=$?
    judge 'update-start: the detached worker reached a terminal success on its own' "$r" "$(cat "$D/upd/status" 2>/dev/null)"
else
    judge 'update fetch-only: fake release server available from the laptop' 1 "GPB_FAKE is empty — the laptop could not serve the fake release"
fi

echo "== j. the live configuration is untouched =="
snapshot > "$D/md5.after"
cmp -s "$D/md5.before" "$D/md5.after"; r=$?
if [ "$r" = 0 ]; then
    judge 'live files untouched' 0 "$(wc -l < "$D/md5.before") files compared: /etc/dropbear/*, /etc/config/network, /etc/config/gl_ddns — md5 records identical"
else
    judge 'live files untouched' 1 "$(awk 'NR==FNR{h[$2]=$1;next} h[$2]!=$1{print "CHANGED: " $2}' "$D/md5.before" "$D/md5.after" | tr '\n' ' ')"
fi

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
REMOTE_DRIVER

reach() { ssh $SSH_OPTS -p "$SSH_PORT" "$REMOTE" "mkdir -p $D/tmp" >/dev/null 2>&1; }
attempt=1
while ! reach; do
    if [ "$attempt" -ge 3 ]; then
        echo "BLOCKED: $REMOTE unreachable after $attempt attempts" | tee -a "$LOG" >&2
        exit 3
    fi
    echo "router unreachable, retrying in 60s (attempt $attempt)" >&2
    attempt=$((attempt + 1))
    sleep 60
done

# ── Fake release server (laptop) ───────────────────────────────────────────────────────────────────
# The driver's fetch-and-verify checks pull a fake 99.0.0 release from this laptop, so no GitHub release
# and no install are needed. Three variants: a good one, one with a wrong checksum, one whose package
# claims a different version. Served with python3's http.server on the laptop's loopback and reached by the
# router through an SSH reverse tunnel on the test's own connection, so no firewall opening is needed; if
# the server does not start the checks are judged FAIL, not skipped.
FAKE_URL=""
mk_fake_ipk() {   # version outfile
    local d; d=$(mktemp -d) || return 1
    mkdir -p "$d/c" "$d/dd"
    printf 'Package: luci-app-gl-portable-backup\nVersion: %s\nArchitecture: all\n' "$1" > "$d/c/control"
    echo "2.0" > "$d/debian-binary"
    (cd "$d/c" && tar czf ../control.tar.gz .) && (cd "$d/dd" && tar czf ../data.tar.gz .) \
        && (cd "$d" && tar czf "$2" ./debian-binary ./control.tar.gz ./data.tar.gz)
    rm -rf "$d"
}
if command -v python3 >/dev/null 2>&1; then
    FAKE="$TMP/fake"; IPK99=luci-app-gl-portable-backup_99.0.0_all.ipk
    for v in good badsum badver; do
        mkdir -p "$FAKE/$v/api" "$FAKE/$v/download/v99.0.0"
        printf '{"tag_name":"v99.0.0","html_url":"https://github.com/RemoteToHome-io/gl-portable-backup/releases/tag/v99.0.0"}' > "$FAKE/$v/api/latest"
    done
    mk_fake_ipk 99.0.0 "$FAKE/good/download/v99.0.0/$IPK99"
    cp "$FAKE/good/download/v99.0.0/$IPK99" "$FAKE/badsum/download/v99.0.0/$IPK99"
    mk_fake_ipk 99.0.1 "$FAKE/badver/download/v99.0.0/$IPK99"
    for v in good badsum badver; do (cd "$FAKE/$v/download/v99.0.0" && sha256sum "$IPK99" > SHA256SUMS); done
    sed -i 's/^..../0000/' "$FAKE/badsum/download/v99.0.0/SHA256SUMS"
    FAKE_PORT=18923
    while [ "$FAKE_PORT" -lt 18933 ]; do
        python3 -m http.server "$FAKE_PORT" --bind 127.0.0.1 --directory "$FAKE" >/dev/null 2>&1 &
        FAKE_PID=$!
        sleep 1
        if kill -0 "$FAKE_PID" 2>/dev/null && curl -fsS -o /dev/null "http://127.0.0.1:$FAKE_PORT/good/api/latest" 2>/dev/null; then
            FAKE_URL="http://127.0.0.1:$FAKE_PORT"; break
        fi
        kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
        FAKE_PORT=$((FAKE_PORT + 1))
    done
    [ -n "$FAKE_URL" ] || echo "warning: could not start the fake release server on 127.0.0.1; fetch checks will FAIL" >&2
fi
trap 'rm -rf "$TMP"; [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null' EXIT INT TERM

scp -O $SSH_OPTS -P "$SSH_PORT" "$BACKEND" "$REMOTE:$D/gl-portable-backup" >/dev/null || { echo "scp of the backend failed" >&2; exit 3; }
scp -O $SSH_OPTS -P "$SSH_PORT" "$TMP/driver.sh" "$REMOTE:$D/driver.sh" >/dev/null || { echo "scp of the driver failed" >&2; exit 3; }

{
    echo "gl-portable-backup on-router smoke test"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)  target: $REMOTE"
    echo "backend: $BACKEND"
    echo
} > "$LOG"

ssh $SSH_OPTS -p "$SSH_PORT" -o ControlMaster=no -o ControlPath=none ${FAKE_URL:+-o ExitOnForwardFailure=yes -R 127.0.0.1:$FAKE_PORT:127.0.0.1:$FAKE_PORT} "$REMOTE" "GPB_FAKE='$FAKE_URL' sh $D/driver.sh" 2>&1 | tee -a "$LOG"

summary=$(tail -n 1 "$LOG")
echo "log: $LOG"
case "$summary" in
    "passed="*" failed=0") exit 0 ;;
    "passed="*" failed="*) exit 1 ;;
    *) echo "FAIL: the driver did not report a summary (last line: $summary)"; exit 1 ;;
esac
