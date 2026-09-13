# GL.iNet Router — Device-Specific Hardware Identifiers

Reference document for all identifiers that are unique to an individual GL.iNet
router device. These are the fields that must be stripped or preserved when
creating portable backups for fleet deployment.

Copyright (c) 2026 RemoteToHome Consulting — https://remotetohome.io

---

## 1. MAC Addresses

MAC addresses are the primary device identifier. Every router has factory-assigned
MACs burned into hardware. GL.iNet firmware copies these into UCI config files at
first boot. A stock `sysupgrade -b` backup captures these values, and restoring
to a different device overwrites the target's MACs — breaking networking.

### 1.1 Wired Interface MACs

| Location | UCI Path | Description | Example |
|----------|----------|-------------|---------|
| `/etc/board.json` | `network.lan.macaddr` | Authoritative LAN MAC (from hardware) | `94:83:c4:6b:0d:81` |
| `/etc/board.json` | `network.wan.macaddr` | Authoritative WAN MAC (from hardware) | `94:83:c4:6b:0d:80` |
| `/etc/board.json` | `system.label_macaddr` | Silk-screen label MAC (printed on device) | `94:83:c4:6b:0d:80` |
| `/etc/config/network` | `network.@device[N].macaddr` | Per-device-section MAC (br-lan, eth0, etc.) | `94:83:c4:c4:03:d0` |

**Notes:**
- `board.json` is the authoritative source — read-only, set by firmware at factory.
- Network device sections reference the board.json values. Multiple device sections
  may share the same MAC (e.g., br-lan, eth1 both use the LAN MAC).
- WAN MAC is typically LAN MAC minus 1 or 2 (vendor-specific offset).
- On MT6000: 6 device sections use LAN MAC, 1 uses WAN MAC.
- On MT3000: fewer device sections but same pattern.
- The same `network.@device[N].macaddr` pattern also covers `br-guest` and `br-iot` device
  sections where they exist — one strip rule (`option macaddr` in `network`) covers all of them.

### 1.2 Wi-Fi Interface MACs

| Location | UCI Path | Description | Example |
|----------|----------|-------------|---------|
| `/etc/config/wireless` | `wireless.wifi2g.macaddr` | 2.4 GHz main interface | `6E:91:70:EB:40:3A` |
| `/etc/config/wireless` | `wireless.wifi5g.macaddr` | 5 GHz main interface | `8A:53:8C:A0:3C:92` |
| `/etc/config/wireless` | `wireless.guest2g.macaddr` | 2.4 GHz guest interface | `16:8D:F3:BB:4E:B1` |
| `/etc/config/wireless` | `wireless.guest5g.macaddr` | 5 GHz guest interface | `22:3E:88:27:53:9D` |
| `/etc/config/wireless` | `wireless.<iface>.factory_macaddr` | Hardware MAC, firmware 4.9+ | (vendor-assigned) |

**Notes:**
- Wi-Fi MACs are **locally-administered** (LAA bit set) — generated per-device
  at first boot, NOT burned into hardware like wired MACs.
- These are NOT in `board.json`. They are only in `/etc/config/wireless`.
- Number of interfaces varies by model (some have 6G, some have only 2G+5G).
- On restore, the target device's existing Wi-Fi MACs must be preserved.
- `factory_macaddr` (firmware 4.9+) is the radio's hardware MAC, distinct from the
  locally-administered `macaddr` above. It is stripped in Clone and Remote-Safe alongside
  `macaddr`.

### 1.3 Repeater (observed on firmware 4.9+) and Per-Port Hardware MACs (firmware 4.11)

| Location | UCI Path | Description |
|----------|----------|-------------|
| `/etc/config/repeater` | `repeater.@main[0].macaddr` | Repeater main-section MAC |
| `/etc/config/repeater` | `repeater.@network[N].macaddr` | Per-saved-network MAC (repeater's saved-AP list) |
| `/etc/config/eth_ports_config_map` | `eth_ports_config_map.@port[N].default_mac` | Per-Ethernet-port hardware MAC, firmware 4.11 |

**Notes:**
- Both files are stripped in Clone and Remote-Safe mode, the same as the MAC fields in §1.1–1.2.
- Repeater `macaddr` fields were observed on firmware 4.9+; earlier firmware was not checked for
  this file.
- `eth_ports_config_map` is new in firmware 4.11 (per-port MAC-mode mapping); it does not exist
  on 4.9 or earlier.

### 1.4 MAC Address in API Responses

| API Endpoint | Field | Description |
|-------------|-------|-------------|
| `system.get_info` | `mac` | WAN MAC address (same as `board.json` wan macaddr) |
| `ui.check_initialized` | `mac` | WAN MAC address |

These are read-only API responses — the API does not set MACs.

---

## 2. Serial Number

| Location | UCI Path / Field | Description | Example |
|----------|-----------------|-------------|---------|
| GL.iNet API | `system.get_info` → `sn` | Device serial number | (model-specific format) |

**Notes:**
- The serial number is returned by the GL.iNet API `system.get_info` endpoint.
- It is stored in firmware/EEPROM, not in UCI config files.
- It does NOT appear in `/etc/config/` — no UCI path to strip.
- It is NOT captured in `sysupgrade -b` backups.
- **Clone/Remote-Safe:** nothing to strip from `/etc/config/` — the serial number was never
  there. **Profile:** captured — the stored `system.get_info` reply includes `sn`, `sn_bak`, and
  the WAN `mac` (see §1.4).

---

## 3. DDNS Identity

GL.iNet routers have a built-in DDNS service (glddns.com) that assigns a unique
domain derived from the device's MAC address. Every field in this config is
device-specific.

| Location | UCI Path | Description | Example |
|----------|----------|-------------|---------|
| `/etc/config/gl_ddns` | `gl_ddns.glddns.username` | DDNS account (MAC-derived, no colons) | `9483c4c403ce` |
| `/etc/config/gl_ddns` | `gl_ddns.glddns.password` | DDNS auth password (device-specific) | `46dafe84031abc92` |
| `/etc/config/gl_ddns` | `gl_ddns.glddns.domain` | Assigned DDNS hostname | `aa403ce.glddns.com` |
| `/etc/config/gl_ddns` | `gl_ddns.glddns.param_enc` | Encoded device parameter | `rkb0d80` |
| `/etc/config/gl_ddns` | `gl_ddns.glddns.lookup_host` | DNS lookup hostname | `aa403ce.glddns.com` |
| `/etc/config/gl_ddns` | `gl_ddns.glddnsv6.username` | IPv6 DDNS username | (same as v4) |
| `/etc/config/gl_ddns` | `gl_ddns.glddnsv6.password` | IPv6 DDNS password | (same as v4) |
| `/etc/config/gl_ddns` | `gl_ddns.glddnsv6.domain` | IPv6 DDNS hostname | (same as v4) |
| `/etc/config/gl_ddns` | `gl_ddns.glddnsv6.param_enc` | IPv6 encoded parameter | (same as v4) |
| `/etc/config/gl_ddns` | `gl_ddns.glddnsv6.lookup_host` | IPv6 lookup hostname | (same as v4) |

**API access:**

| API Endpoint | Field | Description |
|-------------|-------|-------------|
| `system.get_info` | `ddns` | DDNS domain string |
| `ddns.get_config` | `device_id` | Unique DDNS device ID |

**Notes:**
- Username is derived from the WAN MAC (colons removed, lowercase).
- Domain is an abbreviated hash of the MAC.
- Password is device-specific, assigned at DDNS registration.
- All DDNS fields must be stripped in Clone/Remote-Safe modes. On restore, the
  target device's own DDNS identity is re-injected from its existing config.
- The `gl_ddns.orig` backup file (if present) is a factory copy of the original
  DDNS config — also device-specific.

---

## 4. WireGuard Cryptographic Keys

WireGuard server and client keys are generated per-device. They form a
cryptographic identity — transferring them to another device creates a key
conflict with existing peers.

### 4.1 WireGuard Server Keys

| Location | UCI Path | Description |
|----------|----------|-------------|
| `/etc/config/wireguard_server` | `*.private_key` | Server private key |
| `/etc/config/wireguard_server` | `*.public_key` | Server public key |
| `/etc/config/wireguard_server` | `*.preshared_key` | Per-peer preshared keys |

### 4.2 WireGuard Client Keys (standard WG)

| Location | UCI Path | Description |
|----------|----------|-------------|
| `/etc/config/network` | `network.wgclient*.private_key` | Client private key |
| `/etc/config/network` | `network.@wireguard_*[*].public_key` | Peer public key |
| `/etc/config/network` | `network.@wireguard_*[*].preshared_key` | Peer PSK |

### 4.3 AmneziaWG Client Keys

| Location | UCI Path | Description |
|----------|----------|-------------|
| `/etc/config/network` | `network.awgclient*.private_key` | AWG client private key |
| `/etc/config/network` | `network.@amneziawg_*[*].public_key` | AWG peer public key |
| `/etc/config/network` | `network.@amneziawg_*[*].preshared_key` | AWG peer PSK |

### 4.4 WireGuard Keys in API

| API Endpoint | Field | Description |
|-------------|-------|-------------|
| `wg-server.get_peer_list` | `public_key`, `private_key`, `preshared_key` | Per-peer key material |

**Notes:**
- All WG/AWG keys must be stripped in Clone and Remote-Safe modes.
- On restore, the WG server will need to regenerate keys. Existing peers will
  need to be re-provisioned with new keys.
- WG client configs (connections TO remote servers) also contain keys — these are
  stripped because the client identity must be unique per device.
- The `wireguard_server` config also contains peer endpoint addresses and allowed
  IPs, which are deployment-specific (not hardware-specific per se, but coupled to
  the key identity).

---

## 5. OpenVPN Server Identity

The OpenVPN server generates a CA certificate and server certificate/key pair at
first start. These form a PKI identity unique to the device.

| Location | Description |
|----------|-------------|
| `/etc/config/ovpnserver` | UCI config (protocol, port, cipher settings — NOT device-specific) |
| `/etc/openvpn/` | CA cert, server cert, server key, DH params, TLS auth key |

**Notes:**
- The `ovpnserver` UCI config file itself is mostly not device-specific (it
  contains protocol/port/cipher settings that are deployment choices).
- The actual PKI material lives in `/etc/openvpn/`, outside `/etc/config/`, so it is not part of
  `config/`. It IS captured under `extra/` via the `openvpn` keep.d declaration — in Full, Clone,
  and Remote-Safe modes alike.
- This PKI is device-specific: certs are issued by this device's own CA and are not portable to
  a different physical unit. A **Full** restore puts it back onto the *same* device, which is
  correct. Clone and Remote-Safe capture it too, but restoring onto a *different* device (Clone's
  normal use case) carries the source device's OpenVPN PKI onto the target rather than generating
  new, target-specific material — treat OpenVPN server certs as same-device-only, same as the SSH
  host keys in §6, and regenerate them on the target after a cross-device Clone restore if you use
  the OpenVPN server role.
- OpenVPN user credentials (username/password) are stored in the `ovpnserver`
  config and ARE deployment-specific — they transfer with the backup.

---

## 6. SSH Host Keys (Dropbear)

| Location | Description |
|----------|-------------|
| `/etc/dropbear/dropbear_rsa_host_key` | RSA host key (device identity for SSH) |
| `/etc/dropbear/dropbear_ed25519_host_key` | Ed25519 host key |
| `/etc/dropbear/dropbear_ecdsa_host_key` | ECDSA host key (if present) |

**Notes:**
- SSH host keys are unique per device. They are what SSH clients use to verify
  they're connecting to the same device (host key fingerprint).
- These files live in `/etc/dropbear/`, NOT in `/etc/config/`. They ARE captured under `extra/`
  via the `dropbear` keep.d declaration, but only in **Full** mode — Clone and Remote-Safe strip
  them at capture time.
- The `dropbear` UCI config (`/etc/config/dropbear`) contains SSH port and
  authentication settings — this IS in the backup but is not device-specific
  (it's a deployment choice). In Remote-Safe mode, this file is excluded to
  preserve the target's SSH configuration.
- On a **Full** restore, the target's SSH host keys are overwritten with the source's — SSH
  clients will see a changed key on the next connection. `gl-portable-backup restore` and
  `gl-portable-backup fingerprint ARCHIVE` both print the expected fingerprint beforehand;
  `--keep-host-keys` keeps the target's own keys instead. Clone and Remote-Safe restores never
  touch host keys (they were never captured), so the target keeps its own as before.

---

## 7. ZeroTier Node Identity

| Location | UCI Path | Description | Example |
|----------|----------|-------------|---------|
| `/etc/config/zerotier` | `zerotier.gl.join` | ZT network join ID | `93afae59635b3dfe` |
| `/etc/config/zerotier` | `zerotier.gl.secret` | ZT node private identity, mirrored into UCI on firmware 4.9+ | (256-bit key) |
| `/var/lib/zerotier-one/identity.secret` | (file) | ZT node private identity | (256-bit key) |
| `/var/lib/zerotier-one/identity.public` | (file) | ZT node public identity | (256-bit key) |

**Notes:**
- The UCI config contains the network join ID — which network this device
  belongs to. Overwriting it disconnects the device from its ZT network.
- The node identity (cryptographic keypair) lives in `/var/lib/zerotier-one/` — NOT in
  `/etc/config/`, and not captured by our backup. On firmware 4.9 and later, GL.iNet also mirrors
  the node's private key into UCI as `zerotier.gl.secret`; this copy IS in `/etc/config/zerotier`
  and IS captured whenever that file is (Full and Clone). Observed outcome: after a **Full**
  restore onto a clean flash, the node came back with its previous node ID rather than a fresh
  one.
- The ZT node identity determines the device's ZT address (10-digit hex).
  Changing it means the device appears as a new node on the network.
- **Excluded entirely in Remote-Safe mode** — both the UCI config file (so `zerotier.gl.secret`
  too) and the associated network/firewall interface sections.
- In Clone mode the ZT config file IS captured, but `option secret` is stripped from it, so the
  archive carries the network join ID (the deployment setting being cloned) and not the node
  identity. GL regenerates an identity when the field is absent. Without that strip two devices
  restored from one archive would share a single ZT node identity and conflict on the network —
  the same same-device-only caution as the SSH host keys (§6) and OpenVPN PKI (§5) above.
- A **Full** archive keeps `zerotier.gl.secret` verbatim. That is the point of Full mode: after a
  clean flash the same unit comes back with its previous node ID rather than a fresh one.

---

## 8. Tailscale Node Identity

| Location | UCI Path | Description |
|----------|----------|-------------|
| `/etc/config/tailscale` | (entire file) | Tailscale enable/config |
| `/etc/tailscale/` | (directory) | Node keys, state, preferences |

**Notes:**
- Tailscale node identity is stored in `/etc/tailscale/`, not in UCI config.
- The UCI config controls whether Tailscale is enabled and basic settings.
- Overwriting the UCI config can disrupt the Tailscale connection.
- **Excluded entirely in Remote-Safe mode** — the UCI config file and `/etc/tailscale/`.
- In Clone mode the UCI config IS captured, but `/etc/tailscale/` is NOT: the node's private key
  and state stay on the source unit. On restore, Tailscale needs to be re-authenticated on the
  target device.
- Only a **Full** archive carries `/etc/tailscale/`, for same-device recovery.

---

## 9. GoodCloud (GL.iNet Cloud) Identity

| Location | UCI Path | Description | Example |
|----------|----------|-------------|---------|
| `/etc/config/gl-cloud` | `gl-cloud.@cloud[0].enable` | Cloud service enabled | `1` |
| `/etc/config/gl-cloud` | `gl-cloud.@cloud[0].server` | Cloud server endpoint | `gslb-eu.goodcloud.xyz` |

**API access:**

| API Endpoint | Field | Description |
|-------------|-------|-------------|
| `cloud.get_config` | `enable` | Cloud enabled |
| `cloud.get_config` | `bind` | Bind status (boolean) |
| `cloud.get_config` | `email` | Bound account email |
| `cloud.get_config` | `username` | Bound account username |
| `cloud.get_config` | `server` | Cloud server URL |
| `cloud.get_config` | `rtty_ssh` | RTTY SSH enabled |
| `cloud.get_config` | `rtty_web` | RTTY web terminal enabled |

**Notes:**
- GoodCloud binding is device-specific. Each device is bound to a GoodCloud
  account with a unique device ID (derived from MAC).
- Overwriting `gl-cloud` config on a target device unbinds it from its
  GoodCloud account.
- The `rtty` config (`/etc/config/rtty`) is tied to GoodCloud — it controls
  remote SSH/web terminal access through the cloud service.
- **Both `gl-cloud` and `rtty` are excluded entirely in Remote-Safe mode.**
- In Clone mode, these configs ARE captured. The target device will lose its
  GoodCloud binding and need to be re-bound.
- **Profile mode does not capture `cloud.get_config`** — the binding is this device's identity,
  and a Profile archive is meant for a different device.

---

## 10. RTTY (Remote Terminal)

| Location | UCI Path | Description |
|----------|----------|-------------|
| `/etc/config/rtty` | (entire file) | RTTY SSH/web enable, tied to GoodCloud session |

**Notes:**
- RTTY provides remote SSH and web terminal access through GoodCloud.
- It is tied to the device's GoodCloud binding — meaningless without it.
- **Excluded entirely in Remote-Safe mode.**

---

## 11. WAN Access Settings

| Location | UCI Path | Description |
|----------|----------|-------------|
| `/etc/config/wan-access` | (entire file) | WAN SSH/HTTPS enable, IP whitelist |

**Notes:**
- Controls whether SSH and HTTPS are accessible from the WAN side.
- Includes IP whitelist for authorized remote access.
- While not a "hardware identifier," overwriting this during a remote restore
  can lock you out of the device.
- **Excluded entirely in Remote-Safe mode.**

---

## 12. Root Password Hash

| Location | Description |
|----------|-------------|
| `/etc/shadow` | Root password hash (line 1) |
| `/etc/config/rpcd` | RPCD authentication (references shadow) |

**Notes:**
- The root password hash in `/etc/shadow` is NOT in `/etc/config/`. It IS captured under
  `extra/` (identity-file list, subject to the `/rom`-identical skip), but only in **Full**
  mode — Clone and Remote-Safe never capture it.
- This is a deployment choice (set by operator), not a hardware identifier.
- On GL.iNet routers, the root password also controls the GL Admin Panel login.
- The password hash is used by our shell backend for API authentication
  (challenge-response auth reads `/etc/shadow`).
- A **Full** restore overwrites the target's `/etc/shadow` with the source's, so the target's
  root/admin password becomes the source's password. `gl-portable-backup restore` warns about
  this; `gl-portable-backup inspect ARCHIVE` reports it as `restores_root_password`. There is no
  opt-out for this in the current release (unlike `--keep-host-keys` for SSH keys, §6).

---

## 13. `board.json` — Complete Hardware Manifest

`/etc/board.json` is the authoritative hardware identity file on every OpenWrt
device. It is generated at factory and describes the physical hardware.

Key fields (from a GL-MT3000):

```
model.id          = "glinet,mt3000-snand"
model.name        = "GL.iNet GL-MT3000"
system.label_macaddr = "94:83:c4:6b:0d:80"
network.lan.macaddr  = "94:83:c4:6b:0d:81"
network.wan.macaddr  = "94:83:c4:6b:0d:80"
```

**Notes:**
- `board.json` is read-only — it is never modified by backups or config changes.
- It is the source of truth for MAC re-injection during portable restore.
- Our backup tool captures `board.json` in `hardware.json` for reference but
  never overwrites the target's `board.json`.

---

## 14. Cellular Modem State (firmware 4.9+)

| Location | Description |
|----------|-------------|
| `/etc/config/cellular/slot_map.json` | Per-slot modem/SIM state; one file inside the 4.9+ cellular subsystem's config directory, present on non-cellular models too (verified on a GL-MT3000) |

**Notes:**
- On firmware 4.9 and later, `/etc/config/cellular` is a directory of JSON state files (not a
  flat UCI file); `slot_map.json` is one of them, alongside `network_check.json` and
  `sms_forward.json`.
- This is device-specific modem/SIM state, not portable configuration — and no stripping rule
  exists for it yet.
- It has always been captured (the plain `cp -a` that copies `/etc/config/*` copies directories
  along with files); as of this release it is also restored, since `/etc/config` directories are
  no longer skipped on restore (they used to be). **Known gap**: Clone and Remote-Safe restore
  this directory as-is onto the target, with no per-field filtering.

---

## Summary: What Gets Stripped by GL Portable Backup

### Clone and Remote-Safe Modes

| Category | Config File | Fields Stripped |
|----------|-------------|----------------|
| Wired MACs | `network` | All `option macaddr` lines (incl. br-guest/br-iot device sections) |
| Wi-Fi MACs | `wireless` | All `option macaddr` lines |
| Wi-Fi hardware MACs | `wireless` | All `option factory_macaddr` lines (firmware 4.9+) |
| Repeater MACs | `repeater` | All `option macaddr` lines (firmware 4.9+) |
| Per-port hardware MACs | `eth_ports_config_map` | All `option default_mac` lines (firmware 4.11) |
| DDNS identity | `gl_ddns` | username, password, domain, param_enc, lookup_host (v4+v6) |
| WG server keys | `wireguard_server` | private_key, public_key, preshared_key |
| WG/AWG client keys | `network` | private_key, public_key, preshared_key |
| ZT node identity | `zerotier` | `option secret` (firmware 4.9+); the `join` network ID is kept |
| WebDAV TLS key | `gl_nas/ssl_webdav.pem` | Whole file dropped from `config/` |

### Remote-Safe Mode (additional exclusions)

| Category | Config File | Action |
|----------|-------------|--------|
| ZeroTier | `zerotier` | Entire file excluded |
| Tailscale | `tailscale` | Entire file excluded |
| GoodCloud | `gl-cloud` | Entire file excluded |
| RTTY | `rtty` | Entire file excluded |
| SSH config | `dropbear` | Entire file excluded |
| WAN access | `wan-access` | Entire file excluded |
| ZT/TS network interfaces | `network` | Interface sections filtered out |
| ZT/TS firewall rules | `firewall` | Zones/rules/forwards filtered out |

### NOT in `/etc/config/` (not captured by any mode)

These device-specific items live outside the UCI config directory. `board.json`'s values are
captured for reference in `hardware.json` (see §13), but the file itself is never restored;
nothing else in this table is in our archives at all:

| Item | Location | Regeneration |
|------|----------|-------------|
| `board.json` | `/etc/board.json` | N/A — factory-set |
| ZeroTier node identity (files) | `/var/lib/zerotier-one/identity.*` | Auto-generated if missing |

Serial number is not in `/etc/config/` either, but it is left out of this table because Profile
mode does capture it, via the stored `system.get_info` reply (`sn`, `sn_bak`, plus the WAN
`mac`) — see §2.

### Captured, But Only in Some Modes

These items also live outside `/etc/config/`, but — unlike the table above — they ARE captured,
via the `extra/` keep.d mechanism, in the modes marked below:

| Item | Location | Full | Clone | Remote-Safe |
|------|----------|:----:|:-----:|:-----------:|
| SSH host keys | `/etc/dropbear/dropbear_*_host_key` | yes | no (stripped) | no (stripped) |
| Root password hash | `/etc/shadow` | yes | no | no |
| OpenVPN PKI (CA, certs, keys) | `/etc/openvpn/` | yes | yes | yes |
| Tailscale node state | `/etc/tailscale/` | yes | no (excluded) | no (excluded) |
| uhttpd / nginx TLS keys | `/etc/uhttpd.key`, `/etc/nginx/nginx.key` | yes | no (excluded) | no (excluded) |
| `authorized_keys` | `/etc/dropbear/authorized_keys` | yes | yes | no (excluded) |

A "yes" here is a caution, not just a feature: SSH host keys, the root password, and OpenVPN PKI
are same-device identity (see §§5, 6, and 12 above). Restoring a Full archive onto anything but the exact
source device, or a Clone/Remote-Safe archive's OpenVPN PKI onto a different physical unit, hands
that unit the source's identity rather than fresh material of its own. The ZeroTier node secret
mirrored into UCI on firmware 4.9+ (`zerotier.gl.secret`, §7) is the same caution again, but it
travels with `/etc/config/zerotier` rather than through `extra/` — so it is stripped from that file
in Clone and Remote-Safe rather than excluded as a whole path.

---

## Identifier Sources by Discovery Method

How to discover all device-specific identifiers on a live router:

```bash
# MAC addresses in UCI configs
grep -r 'option macaddr' /etc/config/
grep -r 'option factory_macaddr' /etc/config/wireless    # firmware 4.9+
grep -r 'option default_mac' /etc/config/eth_ports_config_map    # firmware 4.11

# MAC addresses from board.json (authoritative)
jsonfilter -i /etc/board.json -e '@.network.lan.macaddr'
jsonfilter -i /etc/board.json -e '@.network.wan.macaddr'
jsonfilter -i /etc/board.json -e '@.system.label_macaddr'

# DDNS identity
uci show gl_ddns

# WireGuard keys
uci show wireguard_server | grep '_key'
uci show network | grep '_key'

# Serial number (API only)
# curl -s http://localhost/rpc -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["SESSION","system","get_info",{}]}'
# → look for "sn" field

# GoodCloud binding
uci show gl-cloud

# ZeroTier network + node secret (secret mirrored into UCI on firmware 4.9+)
uci show zerotier

# Cellular modem state (firmware 4.9+, a directory rather than a flat file)
cat /etc/config/cellular/slot_map.json 2>/dev/null

# SSH host key fingerprints
dropbearkey -y -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null | grep Fingerprint
dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null | grep Fingerprint
```
