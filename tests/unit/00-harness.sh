#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
assert_eq "$(get_model_short_from_id 'glinet,mt3000-snand')" "MT3000" "model short"
assert_eq "$ROOT" "$T/root" "ROOT prefix honoured"
echo "ok 00-harness"
