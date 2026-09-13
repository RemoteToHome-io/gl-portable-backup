# GL Portable Backup

**v1.1:** Full, Clone, and Remote-Safe modes are production-ready. Profile capture follows the firmware's RPC module map (`lan` on 4.8/4.9, `vlan_subnet` on 4.11+). Profile *restore* is currently limited to timezone, DNS mode, DNS hosts, LED on/off, and DHCP static bindings (the last only on firmware that still has the `lan` API) — Wi-Fi and LAN restore are not yet implemented. If you need full cross-model transfer today, see [zippyy/GL.iNet-CrossModel-BackupRestoreUtility](https://github.com/zippyy/GL.iNet-CrossModel-BackupRestoreUtility) until Profile restore v2 lands.

Portable configuration backup and restore for GL.iNet routers. Creates backups with four modes tailored to different deployment scenarios — from fleet cloning to cross-model profile transfer.

Built as a LuCI plugin that installs on any GL.iNet router running firmware 4.x.

## Why Not Stock Backup?

The built-in OpenWrt backup (`sysupgrade -b`) does a raw overlay dump. Restoring it to a different device of the same model carries the source's device-specific material across — MAC addresses, DDNS device identity, WireGuard keys, the ZeroTier node secret, Tailscale node state — leaving the target unreachable, misconfigured, or fighting the source over one identity.

GL Portable Backup's portable modes (Clone and Remote-Safe) strip that material and re-inject the target device's own identity on restore. The exact list is in "Hardware Fields Stripped" below. **Full** mode deliberately keeps all of it — it is same-device disaster recovery, not a portable archive.

## Four Backup Modes

| Mode | Portability | Use Case |
|------|-------------|----------|
| **Full** | Same device only | Disaster recovery — complete raw backup of one specific device |
| **Clone** | Same model | Fleet deployment — golden-image one router, deploy to N others |
| **Remote-Safe** | Same model | Remote restore without losing ZeroTier/GoodCloud/Tailscale/SSH tunnel |
| **Profile** | Any model | Transfer Wi-Fi/LAN/DNS/firewall basics across different models |

### Full

Raw backup of everything, including hardware identifiers and all key material. Captures UCI configs, non-UCI persistent files (OpenVPN certs, SSH keys, WireGuard profiles), and the complete user-installed package list. Only safe to restore to the exact same physical device.

### Clone

Captures all UCI config files plus non-UCI persistent files. Strips MAC addresses, DDNS device identity, WireGuard/AmneziaWG keys, OpenVPN credentials, and the ZeroTier node secret; and leaves out the device-generated key material entirely — SSH host keys, the uhttpd and nginx TLS keys, the WebDAV TLS key, and the Tailscale node state under `/etc/tailscale/` (the target re-authenticates to Tailscale rather than inheriting the source's node). On restore, the target device's own hardware IDs are re-injected from `board.json`. Includes user-installed package list for post-restore review.

### Remote-Safe

Same as Clone, but additionally excludes remote access configurations so you don't cut off the tunnel you're connected through:

- **Entire files excluded**: `zerotier`, `tailscale`, `gl-cloud`, `rtty`, `dropbear`, `wan-access`
- **Selective exclusion**: ZeroTier/Tailscale interface sections filtered from `network`; matching zones/rules/forwards filtered from `firewall`

### Profile

Uses the GL.iNet JSON-RPC API instead of raw UCI files. One JSON file is written per API call (`api/<module>.<method>.json`); a module the firmware doesn't ship is skipped, and a JSON-RPC error reply is logged as a warning rather than stored. On firmware 4.11+, where the `lan` RPC module was replaced by `vlan_subnet`, LAN subnets and DHCP static bindings are captured via `vlan_subnet.get_subnets` / `vlan_subnet.get_static_bind_list`; on earlier firmware, via `lan.get_config_list` / `lan.get_static_bind_list`. Also captured when the firmware ships the module: Wi-Fi, DNS (config + hosts), firewall (rules, port forwards, WAN access), timezone, system info, LED, IPv6, per-port MAC mode, GoodCloud, Tailscale, ZeroTier, the active VPN client tunnel name, timers, switch-button config, and network mode. Capture makes no model-specific assumptions — the same RPC calls run regardless of router model, gated only by whether the firmware ships each module.

**What a Profile archive contains, and what it does not.** It contains the Wi-Fi password of every SSID in cleartext (they are the settings being transferred) and the GoodCloud account identity the router is bound to — treat the file as a secret and don't hand it to anyone you wouldn't hand those to. It does **not** contain VPN client private keys, pre-shared keys or OpenVPN credentials, the saved passwords of third-party access points this router has joined, SSH host keys, `authorized_keys`, or the root password.

**Restore is currently limited** to timezone, DNS mode/force_dns, DNS hosts, LED on/off, and DHCP static bindings — and the static-binding restore only runs on firmware that still exposes the `lan` API (on 4.11+ it prints a skip notice, since the equivalent `vlan_subnet` write hasn't been implemented yet). Wi-Fi and LAN restore are placeholders that print a message and make no changes. Full cross-model restore (Profile restore v2) is planned, not yet shipped.

## Install

Download the latest `.ipk` from [Releases](https://github.com/RemoteToHome-io/gl-portable-backup/releases).

**Via SSH:**

```bash
scp luci-app-gl-portable-backup_*.ipk root@<router>:/tmp/
ssh root@<router> opkg install /tmp/luci-app-gl-portable-backup_*.ipk
```

**Via LuCI web interface:** System → Software → Upload Package — upload the `.ipk` file and install.

**Access:** GL Admin Panel → Advanced → LuCI → System → GL Portable Backup

**Note:** The plugin must be installed on the target router *before* restoring a backup. For fleet deployment: install the plugin first, then restore.

## Backup Archive Format

Archives are `.tar.gz` files with hostname, model, and firmware in the filename:

```
gl-backup-{MODE}-{HOSTNAME}-{MODEL}-fw{VERSION}-{DATE}.tar.gz
```

Example: `gl-backup-clone-RTH-HOME-MT3000-fw4-8-2-20260322-1748.tar.gz`

All contents are nested under a `gl-portable-backup/` prefix directory:

```
gl-portable-backup/
├── manifest.json       Metadata: format_version (currently 4), mode, model, firmware, hostname, sections
├── backup-info.txt     Human-readable summary, compatibility warning, and the Skipped line
├── hardware.json       Source device hardware IDs (reference only)
├── config/             UCI config files (clone, remote-safe, full modes)
├── extra/              Non-UCI persistent files (see below)
│   └── etc/
│       ├── openvpn/    OpenVPN PKI certs, client profiles, scripts
│       ├── dropbear/   SSH host keys (full mode only) and authorized_keys
│       ├── wireguard/  WireGuard client/server profile files
│       └── ...         Other discovered paths
├── api/                One JSON file per API call: <module>.<method>.json (profile mode only)
├── packages.json       Enriched package list with versions, sections, kmod flags
└── packages.txt        Legacy name-only package list (backward compat)
```

### Non-UCI Persistent Files

Beyond UCI configs in `/etc/config/`, routers have persistent files that survive firmware upgrades — OpenVPN certificates, SSH keys, WireGuard profiles, Tailscale state, etc. GL Portable Backup discovers these the same way OpenWrt's own `sysupgrade` does, from three sources: `/lib/upgrade/keep.d/*` (files, directories, and glob lines), `/etc/sysupgrade.conf`, and `opkg list-changed-conffiles`. Discovered files are captured into the `extra/` directory, then filtered — see "What Is Excluded, and Why" below for what's left out and why, and "SSH Host Keys and the Root Password on Restore" for what a Full archive carries beyond configuration.

### Intentionally Incompatible with Stock LuCI Restore

**These backup archives are NOT compatible with the standard OpenWrt/LuCI backup restore** (System → Backup/Flash Firmware). This is by design.

The stock LuCI restore extracts directly to the root filesystem with `tar -C / -xzf`. GL Portable Backup archives use a `gl-portable-backup/` prefix, so stock LuCI would extract to `/gl-portable-backup/` — harmless but non-functional. This prevents accidental router corruption from restoring through the wrong interface.

**Always restore through:** GL Admin Panel → Advanced → LuCI → System → GL Portable Backup

## What Is Excluded, and Why

GL Portable Backup backs up **user configuration**, not router functionality. Two automatic skips apply before any mode-specific filtering, and both are counted in the create output (`Skipped N firmware-owned, M identical to /rom`) and in `backup-info.txt`:

- **Firmware-owned paths** — engine state, vendor scripts, package-manager bookkeeping, and generated caches that the target's own firmware recreates on its own, so carrying the source's copy across only pushes it over the target's. Excluded: `/etc/netifyd/`, `/etc/udhcpc.user.d/`, `/etc/openvpn/scripts/`, `/etc/gl_crontabs/crontabs.d/modem_*`, `/etc/backup/installed_packages.txt`, `/etc/xattr.conf`, `/etc/fw_env.config`, `/etc/luci-uploads/`, `/etc/domain_mac_list/`, `/etc/opkg/keys/`, `/etc/ssmtp/`, `/etc/oui/oui.db`. opkg's own `*-opkg` conffile backups are dropped from `config/` the same way.
- **Everything outside `/etc`** — installed packages' binaries, libraries, and plugin files are functionality, not settings, so they're skipped by default. This also excludes Tor's identity under `/var/lib/tor/`. Pass `--include-plugins` to capture them anyway.
- **Files identical to the firmware's own copy under `/rom`** — a file nobody ever edited. This keeps the archive to what was actually changed, and leaves the target free to keep whatever its own firmware shipped, which matters most when restoring onto newer firmware.

Separately, the system identity files `/etc/shadow`, `/etc/passwd`, `/etc/group`, `/etc/hosts`, `/etc/shells`, `/etc/profile`, `/etc/inittab`, `/etc/shinit`, `/etc/sysctl.conf`, and `/etc/rc.local` are kept only in **Full** mode (still subject to the `/rom`-identical skip) — Clone and Remote-Safe omit them, same as before.

## Package Review

After restoring a backup (or standalone from any archive), the Package Review feature compares the source device's user-installed packages against the target:

- **Kernel Modules** — Display-only. Firmware-tied, require matched `.ipk` files for manual install.
- **Missing — Not in Repositories** — Display-only. Custom packages not in opkg feeds.
- **Missing — Available in Repositories** — Checkboxes. Select and install directly from the UI.
- **Already Installed** — Version comparison table (match vs differs).

Gracefully degrades when opkg feeds are unreachable (common on routers behind DPI firewalls).

## Hardware Fields Stripped

In Clone and Remote-Safe modes, these device-specific fields are removed:

| Config File | Fields Stripped |
|-------------|---------------|
| `network` | `option macaddr` (device MACs, incl. br-guest/br-iot), `private_key`, `public_key`, `preshared_key` (AWG/WG) |
| `wireless` | `option macaddr` (Wi-Fi interface MACs), `option factory_macaddr` (hardware radio MAC, firmware 4.9+) |
| `repeater` | `option macaddr` (firmware 4.9+) |
| `eth_ports_config_map` | `option default_mac` (per-port hardware MAC, firmware 4.11) |
| `gl_ddns` | `enabled`, `username`, `domain`, `param_enc`, `lookup_host`, `password` |
| `wireguard_server` | `private_key`, `public_key`, `preshared_key` (server + all peers) |
| `wireguard` | `private_key`, `public_key`, `preshared_key` (WG client peers) |
| `ovpnclient` | `username`, `password` (OVPN client credentials) |
| `zerotier` | `option secret` (the ZT node private identity, mirrored into UCI on firmware 4.9+; the `join` network ID is kept) |

Files left out of Clone and Remote-Safe archives entirely, rather than stripped field by field:

| Path | Why |
|------|-----|
| `/etc/dropbear/dropbear_*_host_key` | SSH host identity — the target keeps its own |
| `/etc/uhttpd.crt`, `/etc/uhttpd.key`, `/etc/nginx/nginx.cer`, `/etc/nginx/nginx.key` | device-generated TLS keys |
| `/etc/config/gl_nas/ssl_webdav.pem` | device-generated WebDAV TLS key |
| `/etc/tailscale/` | Tailscale node private key and state — the target re-authenticates |

On restore, the target device's MACs are read from `board.json` (factory-set, read-only) and re-injected via UCI.

## VPN Config After Restore

Clone and Remote-Safe modes preserve VPN structural configuration while stripping key material. Post-restore steps:

- **WireGuard server** — GL GUI shows "Generate Configuration" (pre-populated with restored port/subnet). Click to generate a new keypair.
- **WireGuard client** — Endpoint, DNS, MTU, keepalive, allowed IPs preserved. Re-import `.conf` files to reactivate.
- **AmneziaWG client** — STUN/QUIC obfuscation parameters fully preserved (the hardest config to set up). Only keys stripped. Re-import `.conf` to reactivate.
- **OpenVPN server** — Structural config preserved. Certificates in `/etc/openvpn/` captured in `extra/` — available for same-device restore but not portable across devices.
- **OpenVPN client** — Credentials stripped. Profile paths preserved.

## DDNS Restore

All restore modes automatically re-initialize the DDNS service after applying configs. The GL.iNet DDNS API requires explicit activation to register the device identity with the DDNS service — without this, DDNS won't function even if the config file is correct.

Custom DDNS operational preferences (check interval, force interval) are preserved through the re-initialization process.

## SSH Host Keys and the Root Password on Restore

A **Full** archive carries the source router's dropbear SSH host keys and its `/etc/shadow` (root/admin password hash) — Clone and Remote-Safe never capture either. Restoring a Full archive therefore replaces the target's SSH host keys and its root password with the source's:

- SSH clients will see a changed host key on the next connection. `gl-portable-backup restore` and `gl-portable-backup fingerprint ARCHIVE` both print the fingerprint the archive would install, so you can recognize it when your SSH client warns you. The LuCI restore dialog shows the same fingerprint.
- `gl-portable-backup inspect ARCHIVE` reports two booleans, `restores_ssh_host_keys` and `restores_root_password`, alongside the manifest.
- Pass `--keep-host-keys` on the CLI, or check "Keep this device's SSH host keys" in the LuCI restore dialog, to keep the target's own SSH identity instead. `authorized_keys` is always restored regardless of this flag. There is no equivalent opt-out for `/etc/shadow` in this release — a Full restore always brings back the source's root password.

## Restoring Across Firmware Versions

One tested data point so far: a Full archive created on a GL-MT3000 running firmware 4.9.0 (beta4) was restored onto the same unit after a clean flash to 4.11.0 (beta1), with GL's "Keep Settings" off. Every item checked came back: LAN/guest/IoT subnets, Wi-Fi SSIDs and passwords, WireGuard and OpenVPN client profiles, ZeroTier and Tailscale node identities, GoodCloud binding, hostname, DNS settings, WAN MAC mode, IPv6 mode, deleted default DHCP domains, and DDNS re-registration.

At first boot, 4.11 rewrote some of the restored config on its own: `network.iot` gained `vlan_id`, `display_name`, and `delegate` and lost `ip6assign`; the old-style `guest` section was left unconverted (but still worked); `dhcp.iot.ndp` was added; `gl-dns-v2` gained `manual_enable`/`manual_type`/`manual_local_dns`; and the wireless BSSIDs were regenerated. On 4.11 the `lan` RPC module no longer exists — Profile mode uses `vlan_subnet` instead (see Profile above).

The firmware-mismatch warning on restore is unchanged by any of this — it warns, but does not block. This is one tested result on one model; treat it as a data point, not a guarantee for other models or other firmware jumps.

## Shell Backend

The on-router backend (`/usr/sbin/gl-portable-backup`) supports:

```
gl-portable-backup create [--mode clone|remote-safe|profile|full] [--output PATH]
                          [--notes TEXT] [--include-plugins]
gl-portable-backup restore [--keep-host-keys] ARCHIVE
gl-portable-backup inspect ARCHIVE
gl-portable-backup fingerprint ARCHIVE
gl-portable-backup packages ARCHIVE
gl-portable-backup install-package PKG
gl-portable-backup version
```

`-v`/`--verbose`, placed before the subcommand, prints each local API call including its request payload — a verbose log may contain keys and secrets, so don't share one. `--output` accepts a directory (the default filename is written inside it) or a full file path. `--include-plugins` also backs up files outside `/etc` — installed packages' binaries, libraries, and plugin files, including Tor's identity under `/var/lib/tor/` — which are excluded by default (see "What Is Excluded, and Why"). `--keep-host-keys` keeps this device's own SSH host keys during a restore instead of installing the archive's; it only matters for Full archives, since Clone, Remote-Safe, and Profile archives never carry host keys.

## Build

Requires the [GL.iNet glbuilder](https://github.com/gl-inet/glbuilder) SDK. The package is architecture-independent — build once, install on any model.

```bash
# Symlink into the glbuilder feed
ln -s /path/to/gl-portable-backup/luci-app-gl-portable-backup \
      glbuilder/customer/source/luci-app-gl-portable-backup

# Inside the SDK (e.g., build_dir/sdk-mt3000-4.8.1/)
./scripts/feeds update glbuilder
./scripts/feeds install luci-app-gl-portable-backup
TERM=xterm make package/luci-app-gl-portable-backup/compile V=s
```

Output: `bin/packages/*/glbuilder/luci-app-gl-portable-backup_*.ipk`

### No-SDK Build (CI / Quick Build)

The package is architecture-independent (pure shell + LuCI JS/JSON), so a valid `.ipk` can also be assembled directly with standard tools — no SDK toolchain required:

```bash
./pkg/build.sh [version]
```

Output: `build/out/luci-app-gl-portable-backup_<version>_all.ipk`. This is also what `.github/workflows/build-ipk.yml` runs on every push and pull request (uploading the ipk as a build artifact), and, on `v*` tags, to publish a prerelease GitHub Release with the ipk attached.

## Tests

`tests/run.sh` runs the unit test suite under `dash` with mock BusyBox applets on `PATH` (requires `dash` and `python3`):

```bash
./tests/run.sh
```

`tests/on-router-smoke.sh <router-ip>` (shipped with 1.1.0) re-runs the target-sensitive checks against a real GL router from `/tmp`, without installing anything.

## Compatibility

- **Firmware**: GL.iNet 4.x. Full backup and restore after a factory reset were tested on a GL-MT3000 at firmware 4.8.2; a Full archive from 4.9.0-beta4 was restored onto the same unit after a clean flash of 4.11.0-beta1 (see Restoring Across Firmware Versions). API module inventories were checked on GL-MT5000 4.8.4 and GL-AXT1800 4.8.2. Profile capture and the full create/inspect/fingerprint/restore path were exercised on a GL-MT3000 at 4.11.0-beta1 by the on-router smoke test (1.1.0). Not tested on other models or firmware versions.
- **Models**: Architecture-independent package — installs on any GL.iNet router. Actual behavior is verified only on the models above; Clone, Remote-Safe, and Full restores are hard-blocked to the same model regardless.
- **Dependencies**: None beyond stock GL.iNet firmware (`jsonfilter`, `uci`, `curl`, `awk`, `tar`, `dropbearkey` for host-key fingerprints)
- **Package install**: Uses `/usr/libexec/opkg-call` from `luci-app-opkg` (present on all GL.iNet firmware)

## Project Structure

```
gl-portable-backup/
├── README.md
├── dist/                                 # Built .ipk packages
├── backups/                              # Test backup archives (not committed)
├── docs/
│   └── device-specific-identifiers.md    # Reference: HW ID sources
├── pkg/                                  # No-SDK ipk build: build.sh, control, postinst, prerm
├── tests/                                # dash-based unit tests + on-router smoke test
├── .github/workflows/
│   └── build-ipk.yml                     # CI build; prerelease GitHub Release on v* tags
└── luci-app-gl-portable-backup/          # OpenWrt/LuCI package source
    ├── Makefile
    ├── htdocs/luci-static/resources/
    │   └── view/gl-portable-backup/
    │       └── backup.js                 # LuCI JavaScript UI
    └── root/
        ├── usr/sbin/
        │   └── gl-portable-backup        # Shell backend
        └── usr/share/
            ├── luci/menu.d/
            │   └── luci-app-gl-portable-backup.json
            └── rpcd/acl.d/
                └── luci-app-gl-portable-backup.json
```

## License

Licensed under the [GNU General Public License v3.0 or later](LICENSE).

## Author

[RemoteToHome Consulting](https://remotetohome.io) — [Support our work](https://remotetohome.io/support-our-work/)
