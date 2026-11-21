Run `tests/run.sh` to execute every `tests/unit/*.sh` (needs `dash` and `python3`; `node` for one optional JS check).

`tests/mocks/` holds laptop-only stand-ins for the BusyBox applets the backend calls
(`curl`, `jsonfilter`, `uci`, `opkg`, `dropbearkey`); `run.sh` puts them first on `PATH`.

`tests/on-router-smoke.sh <router-ip> [user]` reruns the target-sensitive checks on a real GL
router from `/tmp` without installing anything: BusyBox applet known-answer lints, all four
create modes against the live configuration, a forced auth failure, and a restore driven from a
synthetic `GPB_ROOT` tree. It logs to `tests/smoke-logs/smoke-<date>.log`
(git-ignored — a log carries the target's hostname, archive names and fingerprints, so never commit
one), prints `passed=N failed=M`, and exits non-zero on any FAIL.

`load_backend` clears `set -e`, so a plain function call after it does NOT see the `set -e`
the backend always runs under on the router — assert `set -e`-dependent behaviour by re-running
the backend in a sub-shell instead: `sh -c '. "$0"; some_function args' "$BACKEND"`.

`tests/js/restore-contents.js` loads the LuCI view under node with stubbed globals and
checks the restore dialog's Contents block (counts, headings, and that archive strings
are rendered as text nodes). `tests/unit/40-restore-dialog-contents.sh` runs it and prints
SKIP where node is absent.

`tests/js/update-section.js` (wrapper `tests/unit/43-update-section.sh`) checks the Plugin section's
rendering the same way.

The smoke test's section i serves a fake 99.0.0 release with python3's `http.server` on the laptop's
loopback, reached by the router through an SSH reverse tunnel on the test's own connection, so the router's
fetch-and-verify path runs with no firewall opening, without GitHub and without installing anything.
