#!/bin/sh
# Runs every tests/unit/*.sh under dash with PATH mocks first. See tests/README.md.
set -u
cd "$(dirname "$0")/.." || exit 1
SH=${TEST_SHELL:-dash}
command -v "$SH" >/dev/null 2>&1 || { echo "need $SH (POSIX shell without builtin applets)"; exit 2; }
pass=0; fail=0
for t in tests/unit/*.sh; do
  if PATH="$PWD/tests/mocks:$PATH" "$SH" "$t"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $t"; fi
done
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
