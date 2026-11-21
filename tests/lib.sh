# shared test helpers — run under dash (POSIX sh without BusyBox applets)
set -u
# $0 is the unit test under tests/unit/ (a dot-sourced file does not change $0), so the repo
# root is two levels up from it.
HERE=$(cd "$(dirname "$0")/../.." && pwd)
BACKEND="$HERE/luci-app-gl-portable-backup/root/usr/sbin/gl-portable-backup"
# A failed mktemp would leave T empty and every path below would land at the filesystem root.
T=$(mktemp -d) || exit 2
[ -n "$T" ] || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/etc/config" "$T/root/rom/etc" "$T/root/lib/upgrade/keep.d" "$T/root/usr/lib/oui-httpd/rpc"
# A router's /proc as the incident check reads it: one harmless process and an empty TCP table.
mkdir -p "$T/root/proc/1" "$T/root/proc/net"
printf '/sbin/procd\000' > "$T/root/proc/1/cmdline"
echo '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode' > "$T/root/proc/net/tcp"
# The ps fallback reads the ps mock under every shell: BusyBox sh runs its own ps applet ahead of
# PATH, so the mock is named explicitly (the backend honours GPB_TEST_PS).
export GPB_TEST_PS="$HERE/tests/mocks/ps"
export MOCK_CURL_LOG="$T/curl.log" MOCK_CURL_DIR="$T/curl" MOCK_UCI_FILE="$T/uci.txt" MOCK_UCI_LOG="$T/uci.log" MOCK_OPKG_CONFFILES="$T/conffiles.txt" MOCK_OPKG_AVAILABLE="$T/available.txt" MOCK_OPKG_STATUS="$T/opkg-status.txt" MOCK_OPKG_LOG="$T/opkg.log"
mkdir -p "$MOCK_CURL_DIR/get"; : > "$MOCK_UCI_FILE"; : > "$MOCK_OPKG_CONFFILES"; : > "$MOCK_OPKG_AVAILABLE"; : > "$MOCK_OPKG_STATUS"; : > "$MOCK_OPKG_LOG"
assert_eq() { [ "$1" = "$2" ] && return 0; echo "  assert_eq FAILED (${3:-}): expected [$2] got [$1]"; exit 1; }
assert_contains() { case "$1" in *"$2"*) return 0;; esac; echo "  assert_contains FAILED (${3:-}): [$2] not in [$1]"; exit 1; }
assert_file() { [ -e "$1" ] && return 0; echo "  assert_file FAILED: missing $1"; exit 1; }
assert_no_file() { [ ! -e "$1" ] && return 0; echo "  assert_no_file FAILED: present $1"; exit 1; }
# load_backend dot-sources the backend (which runs under `set -e` on line 11) and then turns
# set -e back OFF in this shell, so functions called directly after load_backend do NOT get
# set -e semantics even though the backend always runs with it on the router. Any assertion
# about set -e-dependent behaviour (e.g. a function whose correctness depends on set -e
# aborting before a later line runs) must instead re-run the backend in a fresh sub-shell,
# which re-triggers its own set -e: sh -c '. "$0"; some_function args' "$BACKEND"
load_backend() { export GPB_LIB_ONLY=1 GPB_ROOT="$T/root"; . "$BACKEND"; set +e; }
