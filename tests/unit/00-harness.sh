#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
assert_eq "$(get_model_short_from_id 'glinet,mt3000-snand')" "MT3000" "model short"
assert_eq "$ROOT" "$T/root" "ROOT prefix honoured"

# capture_packages_txt must read the opkg status DB under $ROOT, not the real /usr/lib/opkg —
# a two-package fixture with one user-installed and one merely-ok-installed package proves both
# the $ROOT prefix and the user-installed filter in one assertion.
mkdir -p "$ROOT/usr/lib/opkg"
cat > "$ROOT/usr/lib/opkg/status" <<'EOF'
Package: pkg-user
Version: 1.0-1
Status: install user installed

Package: pkg-ok
Version: 2.0-1
Status: install ok installed

EOF
capture_packages_txt "$T/pkgs.txt"
assert_eq "$(cat "$T/pkgs.txt")" "pkg-user" "capture_packages_txt honours GPB_ROOT"

# The opkg mock must fail loudly on a subcommand it does not implement, not silently succeed —
# a silent success would let a test exercise the wrong code path and still report green.
opkg frobnicate >/dev/null 2>&1
assert_eq "$?" "1" "opkg mock rejects an unmocked subcommand"

echo "ok 00-harness"
