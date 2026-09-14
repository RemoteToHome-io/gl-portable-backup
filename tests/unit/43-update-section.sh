#!/bin/sh
# Loads backup.js under node with stubbed LuCI globals and checks the Plugin section's pure rendering
# (tests/js/update-section.js). Skipped — loudly — where node is absent.
cd "$(dirname "$0")/../.." || exit 1
command -v node >/dev/null 2>&1 || { echo "SKIP 43-update-section (node not found)"; exit 0; }
node tests/js/update-section.js || exit 1
echo "ok 43-update-section"
