# GL Portable Backup

**v1.1 status.** **Full** backup *and* restore are production-ready: the round trip has been run end to end on real hardware, including across a firmware upgrade. **Clone** and **Remote-Safe** *capture* is tested, but neither *restore* has been live-run on a router yet — and Remote-Safe's restore does not yet preserve the target's own ZeroTier/Tailscale `network` and `firewall` sections: the excluded config *files* are kept, but the interface, zone and forwarding sections are overwritten with the archive's filtered copies, so those services need re-enabling after the restore. The CLI and the LuCI dialog both say so before you start. **Profile** capture follows the firmware's RPC module map (`lan` on 4.8/4.9, `vlan_subnet` on 4.11+) and carries the user's complete portable setup, including VPN client keys and Wi-Fi passwords in cleartext, so treat the archive like a Full backup (see Profile below); Profile *restore* is currently limited to timezone, DNS mode, DNS hosts, LED on/off, and DHCP static bindings (the last only on firmware that still has the `lan` API) — Wi-Fi and LAN restore are not yet implemented. If you need full cross-model transfer today, see [zippyy/GL.iNet-CrossModel-BackupRestoreUtility](https://github.com/zippyy/GL.iNet-CrossModel-BackupRestoreUtility) until Profile restore v2 lands. **1.1.1** adds an incident check for the November 2026 GL.iNet cloud incident and says which backup to take: see [The November 2026 GL.iNet Cloud Incident: Which Backup to Take](#the-november-2026-glinet-cloud-incident-which-backup-to-take).

Portable configuration backup and restore for GL.iNet routers. Creates backups with four modes tailored to different deployment scenarios — from fleet cloning to cross-model profile transfer.

Built as a LuCI plugin that installs on any GL.iNet router running firmware 4.x.

## Why Not Stock Backup?

The built-in OpenWrt backup (`sysupgrade -b`) does a raw overlay dump. Restoring it to a different device of the same model carries the source's device-specific material across — MAC addresses, DDNS device identity, WireGuard keys, the ZeroTier node secret, Tailscale node state — leaving the target unreachable, misconfigured, or fighting the source over one identity.

GL Portable Backup's portable modes (Clone and Remote-Safe) strip that material and re-inject the target device's own identity on restore. The exact list is in "Hardware Fields Stripped" below. **Full** mode deliberately keeps all of it — it is same-device disaster recovery, not a portable archive.

## Four Backup Modes

| Mode | Portability | Use Case | Status in 1.1 |
|------|-------------|----------|---------------|
| **Full** | Same device only | Disaster recovery — complete raw backup of one specific device | Capture and restore tested on hardware |
| **Clone** | Same model | Fleet deployment — golden-image one router, deploy to N others | Capture tested; restore not yet live-run |
| **Remote-Safe** | Same model | Remote restore without losing the ZeroTier/GoodCloud/Tailscale/SSH tunnel | Capture tested; restore not yet live-run, and does not yet preserve the target's ZT/TS `network`/`firewall` sections |
| **Profile** | Any model | Move one user's complete portable setup — Wi-Fi, LAN, DNS, firewall, VPN client tunnels with their keys — to a different model | Capture tested; restore limited (see below) |

### Full

Raw backup of everything, including hardware identifiers and all key material. Captures UCI configs, non-UCI persistent files (OpenVPN certs, SSH keys, WireGuard profiles), and the complete user-installed package list. Only safe to restore to the exact same physical device.

### Clone

Captures all UCI config files plus non-UCI persistent files. Strips MAC addresses, DDNS device identity, WireGuard/AmneziaWG keys, OpenVPN credentials, and the ZeroTier node secret; and leaves out the device-generated key material entirely — SSH host keys, the uhttpd and nginx TLS keys, the WebDAV TLS key, and the Tailscale node state under `/etc/tailscale/` (the target re-authenticates to Tailscale rather than inheriting the source's node). On restore, the target device's own hardware IDs are re-injected from `board.json`. Includes user-installed package list for post-restore review.

### Remote-Safe

Same as Clone, but additionally excludes remote access configurations so you don't cut off the tunnel you're connected through:

- **Entire config files excluded**: `zerotier`, `tailscale`, `gl-cloud`, `rtty`, `dropbear`, `wan-access`
- **Also excluded from `extra/`**: `/etc/dropbear/authorized_keys` (on top of everything Clone leaves out, including `/etc/tailscale/`)
- **Selective exclusion**: ZeroTier/Tailscale interface sections filtered from `network`; matching zones/rules/forwards filtered from `firewall`

**Limitation in 1.1 — read before restoring over a tunnel.** Restore preserves the *excluded config files* listed above by copying the target's own copies back afterwards, but it does **not** preserve the target's `zerotier*`/`tailscale*` sections inside `network` and `firewall`: those are overwritten with the archive's filtered copies, which have none. The tunnel daemon keeps running with its own config, but the interface, its firewall zone and its forwardings are gone until you re-enable the service in the GL admin panel. The CLI prints this notice before applying, and the mode has not yet been live-run end to end on a router.

### Profile

Uses the GL.iNet JSON-RPC API instead of raw UCI files. One JSON file is written per API call (`api/<module>.<method>.json`); a module the firmware doesn't ship is skipped, and a JSON-RPC error reply is logged as a warning rather than stored. On firmware 4.11+, where the `lan` RPC module was replaced by `vlan_subnet`, LAN subnets and DHCP static bindings are captured via `vlan_subnet.get_subnets` / `vlan_subnet.get_static_bind_list`; on earlier firmware, via `lan.get_config_list` / `lan.get_static_bind_list`. Also captured when the firmware ships the module: Wi-Fi, DNS (config + hosts), firewall (rules, port forwards, WAN access), timezone, LED, IPv6, per-port MAC mode, Tailscale, ZeroTier, every VPN client tunnel with its keys and credentials plus the active tunnel name, saved repeater access points (with their passwords), timers, switch-button config, and network mode. Capture makes no model-specific assumptions — the same RPC calls run regardless of router model, gated only by whether the firmware ships each module.

**What a Profile archive contains, and what it does not.** A Profile archive is one user's
complete portable setup, and that includes the secrets: the Wi-Fi password of every SSID,
every VPN client tunnel's private key, pre-shared key, and OpenVPN credentials, and the saved
passwords of access points this router has joined — all in cleartext. Handle it exactly like a
Full backup: it is a secret, not a settings file. It leaves out the identity a different device
must not inherit: no GoodCloud binding (`cloud.get_config` is deliberately not captured), no
SSH host keys, no `authorized_keys`, and no root password. It also carries no device identity
of the source: no `hardware.json` and no `system.get_info` reply (serial number and WAN MAC).
The router's factory and radio addresses are removed from every stored reply **by value**: each
port's factory address (`defmacaddr` in `cable.get_ports_config`), each radio's own address
(`bssid` in `wifi.get_config`) and every MAC address in the router's `/etc/board.json` are
collected first, and every field holding one of them, in either letter case and under any field
name, is removed — including a port's `macaddr` in the default MAC mode, where it equals the
factory address. What stays: an address the user set that differs from the factory one (a cloned
or randomised WAN or repeater MAC in `cable.get_ports_config` or `repeater.get_saved_ap_list`),
and the DHCP reservations, which name the MAC addresses of client devices. A final pass looks for
every collected address in every stored reply; a file that still holds one (inside a longer value,
say, or in a reply that would no longer parse once it was removed) is named in a
`WARNING: a hardware address could not be removed from …` line — the file name, never the address
— and listed in the manifest's `identity_residue`. When `/etc/board.json` cannot be read, the create
output says the archive was not checked and the manifest records `"identity_checked": false`.

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

### Updating

The **Plugin** section at the bottom of the page shows the installed version. **Check for updates** asks
GitHub for the newest stable release — only when you click; the router makes no background requests.
**Update to X** downloads that release's package over HTTPS, verifies it against the release's
`SHA256SUMS`, checks that the package itself carries that version, installs it with `opkg` (no force
flags, never a downgrade), and asks you to reload the page. The same steps run from the command line as
`gl-portable-backup update-check` and `update-start`.

What this trusts: the TLS connection to github.com and the release published there. The checksum file
comes from the same release as the package, so it catches a damaged download, not a compromised release;
signed packages are planned together with the apk-based packaging for OpenWrt 25 firmware. Prereleases
(tags with a suffix such as `-beta.1`) are never offered — install those by hand as described above.

## Backup Archive Format

Archives are `.tar.gz` files with hostname, model, and firmware in the filename:

```
gl-backup-{MODE}-{HOSTNAME}-{MODEL}-fw{VERSION}-{DATE}.tar.gz
```

Example: `gl-backup-clone-HOME-MT3000-fw4-8-2-20260322-1748.tar.gz`. A backup taken while the incident
check finds an indicator carries `-COMPROMISED-` after the mode (see "If indicators are found").

All contents are nested under a `gl-portable-backup/` prefix directory:

```
gl-portable-backup/
├── manifest.json       Metadata: format_version (currently 4), mode, model, firmware, hostname, sections,
│                       extra_files, suspect_markers, incident_check; Profile: identity_checked,
│                       identity_residue
├── backup-info.txt     Human-readable summary, compatibility warning, and the Skipped line
├── hardware.json       Source device hardware IDs (reference only; not written in profile mode)
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
- `gl-portable-backup inspect ARCHIVE` prints the archive's manifest with four keys appended: the booleans `restores_ssh_host_keys` and `restores_root_password`, `startup_and_login_files` (see "Hidden entries, refusals and flags"), and `restore_refused` (see "If indicators are found"). The first three are worked out from the archive's own file listing, not taken from the manifest, and `restore_refused` comes from the same function restore uses; inspect refuses an archive whose manifest is not in the layout this tool writes, so the appended keys cannot be hidden.
- Pass `--keep-host-keys` on the CLI, or check "Keep this device's SSH host keys" in the LuCI restore dialog, to keep the target's own SSH identity instead. `authorized_keys` is always restored regardless of this flag. There is no equivalent opt-out for `/etc/shadow` in this release — a Full restore always brings back the source's root password.

## The November 2026 GL.iNet Cloud Incident: Which Backup to Take

On 20 November 2026 a flaw in GL.iNet's cloud remote management was used to install malicious
software on some routers and KVM devices, and owners are being told to factory reset and install
fixed firmware. Sources: GL.iNet's
[security notice](https://forum.gl-inet.com/t/2026-11-20-gl-inet-security-notice-goodcloud-kvm-routers/73056)
and the incident record kept at
[RemoteToHome-io/gl-security-incident-2026](https://github.com/RemoteToHome-io/gl-security-incident-2026),
which says where each finding comes from.

### Check first

The plugin page opens with the result of an incident check, and the same check runs from the command
line as `gl-portable-backup check`. It prints one line of JSON (`result`, the `indicators` found with
an `id` and a fixed `detail` each, `cannot_clear` in the same form, `goodcloud_enabled`,
`uptime_since`, `rebooted_since_incident`, `checked_at` and a `note`; every time in UTC) and exits 0,
or 3 when a strong indicator was found. Every backup runs the same check first and records it in its
manifest. What it looks for comes in two tiers.

**Strong indicators** (`indicators`): each one is a trace of the attack itself.

| id | What it means | Source |
|----|---------------|--------|
| `proc-crond-log` | a running process containing `crond -i`, GL.iNet's published indicator | GL.iNet's notice |
| `proc-remote-shell` | a running process with `mkfifo`, `nc` to an IPv4 address and port, `/bin/sh -i` or a bare `sh -i`: the remote shell found on GL-AXT1800 routers | incident record, [router-reverse-shell.md](https://github.com/RemoteToHome-io/gl-security-incident-2026/blob/main/docs/router-reverse-shell.md) |
| `tmp-fifo` | `/tmp/f` is a named pipe: that shell has run since the last boot | incident record, [findings.md](https://github.com/RemoteToHome-io/gl-security-incident-2026/blob/main/docs/findings.md) |
| `tmp-log` | `/tmp/.log` exists (the file named in GL.iNet's indicator) | GL.iNet's notice |
| `netstat-replaced` | a `netstat` that is neither a link to `busybox` nor identical to the firmware's `/rom` copy; it is read, never run | GL.iNet staff, via findings.md |
| `marker-dir` | `/etc/config/.gl` or `/etc/glinet/.cache`, the paths the cleanup in GL.iNet's KVM firmware removes | findings.md |
| `boot-script-changed` | `/etc/init.d/urandom_seed` or `/lib/upgrade/keep.d/netifd` differs from its `/rom` copy (an unconfirmed report) | findings.md |
| `nat-loopback-rule` | a firewall rule the remote-shell attack leaves, which stays until a reboot | router-reverse-shell.md, findings.md |
| `conn-attacker-range` | an open TCP connection to 170.39.226.0/24, the range the remote shells connected to | findings.md |
| `udhcpc-user-changed` | a file under `/etc/udhcpc.user.d/` that differs from its `/rom` copy (an unconfirmed report) | an unconfirmed forum report |

**Cannot-clear findings** (`cannot_clear`): each one stops the check from clearing the router, and
none of them shows a compromise.

| id | What it means | Source |
|----|---------------|--------|
| `mp-ip-mapping-file` | `/etc/mp_ip_mapping_info` written on or after 2026-11-20 while multi-path tunnelling is off: the cloud client's handler that the attack used has run on this router. It is the only trace of that handler known to survive a restart. We have read it on a compromised router and on routers with no other trace (21 November 2026), and whether an ordinary cloud message also writes it is not known, so on its own it does not show a compromise and does not rule one out | router-reverse-shell.md |
| `restarted-since-incident` | the router has restarted since the attack window opened (about 20:47 UTC on 2026-11-20, from the incident record and open to revision); the remote shell and its traces do not survive a restart | router-reverse-shell.md |
| `check-incomplete` | the check could not read something it needs: the process command lines under `/proc` (it then reads `ps w`), the process list, or the TCP connection table | — |

Processes are read from `/proc/<pid>/cmdline`, which holds the whole command line. Only when no
command line there can be read does the check fall back to `ps w`, and it adds `check-incomplete`,
because BusyBox cuts `ps w` lines at the terminal width and a pattern near the end of a
long command line is then not seen. The check leaves out only its own process and its ancestors (read
from `/proc/<pid>/stat`), so the shell of a person running it over SSH is not reported; any other
process is matched whatever its command line names. No command line, address or rule is printed:
each indicator carries fixed text only.

There are three results:

- **`indicators`**: at least one strong indicator was found. The backup is a record only and is not
  restored. See below.
- **`inconclusive`**: no strong indicator was found, but at least one cannot-clear finding was. The
  backup is not a record: it restores, and `restore` first prints `WARNING: this archive was made on a
  router that could not be cleared (<ids>). Restore its keys and passwords only if you accept that.`,
  which the restore dialog shows too. If you have any other reason to suspect the router, treat it as
  compromised and follow "If indicators are found".
- **`none`**: nothing of either tier was found (a router whose uptime cannot be read counts as not
  restarted). This does not show the router was never compromised: the known remote shell leaves no
  file and is gone after a reboot, and the check only knows the indicators above.

### If indicators are found

Nothing from that router is restored. Treat every key and password on it as read by someone else and
replace it: VPN keys and profiles (client and server), Wi-Fi passwords, the admin password, DDNS and
cloud credentials, SSH keys. VPN client profiles and SSH client keys that this router held must also
be revoked on the server they connect to; deleting them from the router is not enough. The incident
record's "If you find something" section lists the steps per VPN type.

A backup taken now still completes, as a record of what was on the router and a reference for setting
it up again. Its file name carries `-COMPROMISED-` after the mode
(`gl-backup-full-COMPROMISED-<host>-…`), the create output says it is a record only, and
`gl-portable-backup restore` refuses it before anything is written. Restore also refuses an archive
made by 1.1.0 whose `suspect_markers` is not empty. There is no option that restores either.
`gl-portable-backup inspect` reports `"restore_refused": true` for both, and the restore dialog shows
the refusal and no Restore button.

### If no indicator is found

Take a **Full** backup before the factory reset; the plugin page marks it "Security incident backup"
and selects it. After the reset and the fixed firmware, install the plugin again and restore the Full
archive on the same router. Before rebooting, read every file the restore dialog flags as running at
startup or controlling logins (see "Startup and login files" below). Full is the only mode whose
restore has been run on a router (see Compatibility).

With an `inconclusive` result the page still marks Full as the security incident backup and adds that
you should treat the router as compromised if you have any other reason to suspect it; the archive
restores, after the could-not-be-cleared warning.

What each mode carries, among the files that matter here:

| Item | Full | Clone | Remote-Safe | Profile |
|------|------|-------|-------------|---------|
| Hidden entries under `/etc/config` | no | no | no | no |
| Root crontab `/etc/crontabs/root` | when it differs from the firmware's `/rom` copy | when it differs from `/rom` | when it differs from `/rom` | no |
| `/etc/rc.local` | when it differs from `/rom` | no | no | no |
| `/etc/dropbear/authorized_keys` | yes | yes | no | no |
| `/etc/shadow` | when it differs from `/rom` | no | no | no |
| SSH host keys | yes | no | no | no |
| Files outside `/etc` | only with `--include-plugins` | only with `--include-plugins` | only with `--include-plugins` | no |

When another mode fits better:

- **Clone**, to set up a different unit of the same model: it leaves out the MAC addresses, VPN keys,
  DDNS identity, ZeroTier node secret, Tailscale state, SSH host keys and TLS keys (see "Hardware
  Fields Stripped"), so those are set up again on the target.
- **Profile**, to move to a different model: it stores the replies of the router's own API rather
  than files, and carries no GoodCloud binding, SSH keys or root password. It still carries the
  Wi-Fi passwords and VPN client keys, and settings that could have been changed on the source (DNS
  mode and hosts entries, port forwards, WAN access, firewall rules, VPN client configurations): read
  those in the archive's `api/` replies before restoring. Profile restore covers only a few settings
  in this release (see Profile).

Clone, Remote-Safe and Profile restore have not been run on a router.

### Hidden entries, refusals and flags

- **Hidden entries are not carried.** Every entry whose name starts with a dot, at any depth under
  `/etc/config` and in the persistent-file lists, is left out of the archive (`Skipped N hidden
  entries …` in the create output). At restore time no hidden entry, no symbolic link or other
  non-regular entry, and nothing under the archive's `extra/etc/config/` is written, even from an
  archive made by hand; each kind dropped gets its own `WARNING: … were NOT restored` line.
- **An archive no backup of this tool can produce is refused before anything is extracted.**
  `restore`, `inspect`, `fingerprint` and `packages` stop with an `Invalid archive` error, naming a
  count and never a file name, for a hard link, a device node, a fifo or another special member; a
  member name with a `..` component, a control character or a backslash; a symbolic link in place of
  the archive's own `gl-portable-backup/` directory, `manifest.json`, `config`, `extra`, `api`,
  `packages.json` or `packages.txt`; a regular file whose name contains ` -> ` (how BusyBox `tar`
  lists a hard link); and a manifest not in the layout this tool writes or with an incident-check
  result it never writes.
- **Startup and login files.** `gl-portable-backup inspect` adds `startup_and_login_files`: the files
  a restore would write under `/etc/rc.local`, `/etc/crontabs/`, `/etc/init.d/`, `/etc/rc.d/`,
  `/etc/hotplug.d/`, `/etc/hotplug-preinit.d/`, `/etc/uci-defaults/`, `/etc/rc.button/`,
  `/etc/rc.common`, `/etc/preinit`, `/etc/inittab`, `/etc/profile`, `/etc/profile.d/`,
  `/etc/sysctl.conf`, `/etc/sysctl.d/`, `/etc/firewall.user`, `/etc/opkg/`, `/etc/sysupgrade.conf`,
  `/etc/shadow`, `/etc/passwd`, `/etc/group`, `/etc/dropbear/authorized_keys` and the dropbear host
  keys, plus every file outside `/etc`. Paths are normalised first. `restore` lists the same files in
  a warning before anything is written, and the LuCI dialog shows them and repeats every `WARNING`
  line after a restore. The flag does not block the restore.

The flagged list covers only the paths named above, and the incident check only the indicators in
its table. A missing warning is not evidence that the router or the archive is unaffected.

## Restoring Across Firmware Versions

One tested data point so far: a Full archive created on a GL-MT3000 running firmware 4.9.0 (beta4) was restored onto the same unit after a clean flash to 4.11.0 (beta1), with GL's "Keep Settings" off. Every item checked came back: LAN/guest/IoT subnets, Wi-Fi SSIDs and passwords, WireGuard and OpenVPN client profiles, ZeroTier and Tailscale node identities, GoodCloud binding, hostname, DNS settings, WAN MAC mode, IPv6 mode, deleted default DHCP domains, and DDNS re-registration.

Two caveats on that result, because they change what it proves. It was run with the **1.0.0** CLI, and the archive was **filtered by hand** before restoring — plugin files, vendor scripts that differ on the newer firmware, modem cron files, the package-keep list, DPI engine files and opkg conffile backups were all removed manually first. Version 1.1's automatic exclusion rules (see "What Is Excluded, and Why") are the productisation of that hand filter, but they are not the same set — they compare against the *source's* `/rom`, and nothing drops configs belonging to a package the target firmware no longer ships. **The 1.1 rules have not yet been exercised on a cross-firmware restore.**

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
gl-portable-backup check
gl-portable-backup packages ARCHIVE
gl-portable-backup install-package PKG
gl-portable-backup update-check
gl-portable-backup update-start [--fetch-only]
gl-portable-backup update-status
gl-portable-backup update-install [--fetch-only]
gl-portable-backup version
```

`-v`/`--verbose`, placed before the subcommand, prints each local API call including its request payload — a verbose log may contain keys and secrets, so don't share one. `--output` accepts a directory (the default filename is written inside it) or a full file path. `--include-plugins` also backs up files outside `/etc` — installed packages' binaries, libraries, and plugin files, including Tor's identity under `/var/lib/tor/` — which are excluded by default (see "What Is Excluded, and Why"). `--keep-host-keys` keeps this device's own SSH host keys during a restore instead of installing the archive's; it only matters for Full archives, since Clone, Remote-Safe, and Profile archives never carry host keys. `update-check` prints one JSON line (installed and newest stable version, whether an update is offered); `update-start` detaches the worker (`update-install`) and `update-status` reports its progress; `--fetch-only` downloads and verifies without installing.

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

Output: `build/out/luci-app-gl-portable-backup_<version>_all.ipk`. This is also what `.github/workflows/build-ipk.yml` runs on every push and pull request (uploading the ipk as a build artifact), and, on `v*` tags, to publish a GitHub Release with the ipk and `SHA256SUMS` attached — marked as a prerelease when the tag carries a suffix (`v1.2.0-beta.1`), stable otherwise, which is what the plugin's self-updater follows.

## Tests

`tests/run.sh` runs the unit test suite under `dash` with mock BusyBox applets on `PATH` (requires `dash` and `python3`):

```bash
./tests/run.sh
```

`tests/on-router-smoke.sh <router-ip>` (shipped with 1.1.0) re-runs the target-sensitive checks against a real GL router from `/tmp`, without installing anything. Its self-update checks fetch a fake release served on the loopback of the laptop running the test and reached by the router through an SSH reverse tunnel on the test's own connection, so they need no firewall opening and no GitHub release, and install nothing.

## Compatibility

- **Firmware**: GL.iNet 4.x. Full backup and restore after a factory reset were tested on a GL-MT3000 at firmware 4.8.2; a Full archive from 4.9.0-beta4 was restored onto the same unit after a clean flash of 4.11.0-beta1 (see Restoring Across Firmware Versions). API module inventories were checked on GL-MT5000 4.8.4 and GL-AXT1800 4.8.2. The 1.1.0 on-router smoke run on a GL-MT3000 at firmware 4.11.0 exercised all four capture modes, Full-mode inspect and fingerprint, the self-updater's fetch-and-verify path against a fake release, and a restore into a scratch root — the restore ran against a synthetic source tree, not the live configuration, and no Clone, Remote-Safe or Profile restore was run on a router. Not tested on other models or firmware versions.
- **Models**: Architecture-independent package — installs on any GL.iNet router. Actual behavior is verified only on the models above; Clone, Remote-Safe, and Full restores are hard-blocked to the same model regardless.
- **Dependencies**: None beyond stock GL.iNet firmware (`jsonfilter`, `uci`, `curl`, `awk`, `tar`, `dropbearkey` for host-key fingerprints)
- **Package install**: Uses `/usr/libexec/opkg-call` from `luci-app-opkg` (present on all GL.iNet firmware)

## Project Structure

```
gl-portable-backup/
├── README.md
├── build/out/                            # Built .ipk packages (not committed)
├── docs/
│   └── device-specific-identifiers.md    # Reference: HW ID sources
├── pkg/                                  # No-SDK ipk build: build.sh, control, postinst, prerm
├── tests/                                # dash-based unit tests + on-router smoke test
│   └── js/                               # node harnesses for the LuCI view (Contents block, Plugin section)
├── .github/workflows/
│   └── build-ipk.yml                     # CI build; GitHub Release on v* tags (prerelease when the tag has a suffix)
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
