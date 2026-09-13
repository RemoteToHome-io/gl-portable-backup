Run `tests/run.sh` to execute every `tests/unit/*.sh` (needs `dash` and `python3`).

`tests/mocks/` holds laptop-only stand-ins for the BusyBox applets the backend calls
(`curl`, `jsonfilter`, `uci`, `opkg`, `dropbearkey`); `run.sh` puts them first on `PATH`.

`tests/on-router-smoke.sh <router-ip> [user]` reruns the target-sensitive checks on a real GL
router from `/tmp` without installing anything: BusyBox applet known-answer lints, all four
create modes against the live configuration, a forced auth failure, and a restore driven from a
synthetic `GPB_ROOT` tree. It logs to `build/smoke-<date>.log`, prints `passed=N failed=M`, and
exits non-zero on any FAIL.

`load_backend` clears `set -e`, so a plain function call after it does NOT see the `set -e`
the backend always runs under on the router — assert `set -e`-dependent behaviour by re-running
the backend in a sub-shell instead: `sh -c '. "$0"; some_function args' "$BACKEND"`.
