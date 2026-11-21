#!/bin/sh
# Loads backup.js under node with stubbed LuCI globals and checks the incident banner, the "Security
# incident backup" tag and the restore dialog's actions for a refused archive
# (tests/js/incident-banner.js). Where node is absent the check is skipped — loudly, never passed.
cd "$(dirname "$0")/../.." || exit 1
command -v node >/dev/null 2>&1 || { echo "SKIP 49-incident-banner (node not found)"; exit 0; }
node tests/js/incident-banner.js || exit 1
echo "ok 49-incident-banner"
