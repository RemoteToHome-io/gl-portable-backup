#!/bin/sh
. "$(dirname "$0")/../lib.sh"
load_backend
mkdir -p "$T/out"
assert_eq "$(resolve_output_path '' x.tar.gz)" "/tmp/x.tar.gz" "empty"
assert_eq "$(resolve_output_path "$T/out" x.tar.gz)" "$T/out/x.tar.gz" "directory"
assert_eq "$(resolve_output_path "$T/out/y.tgz" x.tar.gz)" "$T/out/y.tgz" "file path"
echo "ok 12-output-dir"
