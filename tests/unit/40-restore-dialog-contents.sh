#!/bin/sh
# Loads backup.js under node with stubbed LuCI globals and checks the restore dialog's Contents
# block (tests/js/restore-contents.js). node is neither on the router nor required by the shell
# harness, so where it is absent the check is skipped — loudly, never silently passed.
cd "$(dirname "$0")/../.." || exit 1
command -v node >/dev/null 2>&1 || { echo "SKIP 40-restore-dialog-contents (node not found)"; exit 0; }
node tests/js/restore-contents.js || exit 1
echo "ok 40-restore-dialog-contents"
