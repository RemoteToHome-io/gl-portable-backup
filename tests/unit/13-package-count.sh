#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
printf '{"format":1,"packages":[\n{"name":"a","version":"1"},\n{"name":"b","version":"2"},\n{"name":"c","version":"3"}\n]}\n' > "$T/p.json"
assert_eq "$(count_packages_json "$T/p.json")" 3 "count"
printf '{"format":1,"packages":[\n]}\n' > "$T/e.json"
assert_eq "$(count_packages_json "$T/e.json")" 0 "zero packages (single line)"
assert_eq "$(count_packages_json "$T/missing.json")" 0 "missing file"
echo "ok 13-package-count"
