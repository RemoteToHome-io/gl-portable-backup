# GL Portable Backup

Portable configuration backup and restore for GL.iNet routers. Creates backups with four modes tailored to different deployment scenarios — from fleet cloning to cross-model profile transfer.

Built as a LuCI plugin that installs on any GL.iNet router running firmware 4.x.

## Why Not Stock Backup?

The built-in OpenWrt backup (`sysupgrade -b`) does a raw overlay dump. Restoring it to a different device of the same model overwrites hardware-specific values — MAC addresses, DDNS device identity, WireGuard keys, ZeroTier/Tailscale node IDs — making the target device unreachable or misconfigured.

GL Portable Backup solves this by stripping hardware identifiers from portable backups and re-injecting the target device's own identity on restore.

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

Captures all UCI config files plus non-UCI persistent files. Strips MAC addresses, DDNS device identity, WireGuard/AmneziaWG keys, and OpenVPN credentials. On restore, the target device's own hardware IDs are re-injected from `board.json`. Includes user-installed package list for post-restore review.

### Remote-Safe

Same as Clone, but additionally excludes remote access configurations so you don't cut off the tunnel you're connected through:

- **Entire files excluded**: `zerotier`, `tailscale`, `gl-cloud`, `rtty`, `dropbear`, `wan-access`
- **Selective exclusion**: ZeroTier/Tailscale interface sections filtered from `network`; matching zones/rules/forwards filtered from `firewall`

### Profile

Uses the GL.iNet JSON-RPC API instead of raw UCI files. Captures structured, model-agnostic settings: Wi-Fi (mapped by band, not interface name), LAN, DHCP static bindings (fixed IP assignments), DNS, firewall rules, timezone, LED config. Restores via API calls. No model restriction — works across any GL.iNet 4.x router.

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
├── manifest.json       Metadata: mode, model, firmware, hostname, sections
├── backup-info.txt     Human-readable summary and compatibility warning
├── hardware.json       Source device hardware IDs (reference only)
├── config/             UCI config files (clone, remote-safe, full modes)
├── extra/              Non-UCI persistent files from keep.d discovery
│   └── etc/
│       ├── openvpn/    OpenVPN PKI certs, client profiles, scripts
│       ├── dropbear/   SSH host keys and authorized_keys
│       ├── wireguard/  WireGuard client/server profile files
│       └── ...         Other keep.d-declared paths
├── api/                API-captured JSON data (profile mode only)
├── packages.json       Enriched package list with versions, sections, kmod flags
└── packages.txt        Legacy name-only package list (backward compat)
```

### Non-UCI Persistent Files

Beyond UCI configs in `/etc/config/`, routers have persistent files that survive firmware upgrades — OpenVPN certificates, SSH keys, WireGuard profiles, Tailscale state, etc. GL Portable Backup discovers these via OpenWrt's `keep.d` mechanism (`/lib/upgrade/keep.d/*`) and captures them in the `extra/` directory. Mode-specific filtering applies (Clone strips SSH host keys, Remote-Safe excludes Tailscale state, etc.).

### Intentionally Incompatible with Stock LuCI Restore

**These backup archives are NOT compatible with the standard OpenWrt/LuCI backup restore** (System → Backup/Flash Firmware). This is by design.

The stock LuCI restore extracts directly to the root filesystem with `tar -C / -xzf`. GL Portable Backup archives use a `gl-portable-backup/` prefix, so stock LuCI would extract to `/gl-portable-backup/` — harmless but non-functional. This prevents accidental router corruption from restoring through the wrong interface.

**Always restore through:** GL Admin Panel → Advanced → LuCI → System → GL Portable Backup

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
| `network` | `option macaddr` (device MACs), `private_key`, `public_key`, `preshared_key` (AWG/WG) |
| `wireless` | `option macaddr` (Wi-Fi interface MACs) |
| `gl_ddns` | `enabled`, `username`, `domain`, `param_enc`, `lookup_host`, `password` |
| `wireguard_server` | `private_key`, `public_key`, `preshared_key` (server + all peers) |
| `wireguard` | `private_key`, `public_key`, `preshared_key` (WG client peers) |
| `ovpnclient` | `username`, `password` (OVPN client credentials) |

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

## Shell Backend

The on-router backend (`/usr/sbin/gl-portable-backup`) supports:

```
gl-portable-backup create [--mode clone|remote-safe|profile|full] [--output PATH] [--notes TEXT]
gl-portable-backup restore ARCHIVE
gl-portable-backup inspect ARCHIVE
gl-portable-backup packages ARCHIVE
gl-portable-backup install-package PKG
gl-portable-backup version
```

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

## Compatibility

- **Firmware**: GL.iNet 4.x (tested on 4.8.2)
- **Models**: Any GL.iNet router — architecture-independent package
- **Dependencies**: None beyond stock GL.iNet firmware (`jsonfilter`, `uci`, `curl`, `awk`, `tar`)
- **Package install**: Uses `/usr/libexec/opkg-call` from `luci-app-opkg` (present on all GL.iNet firmware)
- **Tested**: Full backup/restore cycle including factory reset verified on GL-MT3000

## Project Structure

```
gl-portable-backup/
├── README.md
├── dist/                                 # Built .ipk packages
├── backups/                              # Test backup archives (not committed)
├── docs/
│   └── device-specific-identifiers.md    # Reference: HW ID sources
└── luci-app-gl-portable-backup/          # OpenWrt/LuCI package source
    ├── Makefile
    ├── htdocs/luci-static/resources/
    │   └── view/gl-portable-backup/
    │       └── backup.js                 # LuCI JavaScript UI
    └── root/
        ├── usr/sbin/
        │   └── gl-portable-backup        # Shell backend (~1300 lines)
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
