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

### 1.2 Wi-Fi Interface MACs

| Location | UCI Path | Description | Example |
|----------|----------|-------------|---------|
| `/etc/config/wireless` | `wireless.wifi2g.macaddr` | 2.4 GHz main interface | `6E:91:70:EB:40:3A` |
| `/etc/config/wireless` | `wireless.wifi5g.macaddr` | 5 GHz main interface | `8A:53:8C:A0:3C:92` |
| `/etc/config/wireless` | `wireless.guest2g.macaddr` | 2.4 GHz guest interface | `16:8D:F3:BB:4E:B1` |
| `/etc/config/wireless` | `wireless.guest5g.macaddr` | 5 GHz guest interface | `22:3E:88:27:53:9D` |

**Notes:**
- Wi-Fi MACs are **locally-administered** (LAA bit set) — generated per-device
  at first boot, NOT burned into hardware like wired MACs.
- These are NOT in `board.json`. They are only in `/etc/config/wireless`.
- Number of interfaces varies by model (some have 6G, some have only 2G+5G).
- On restore, the target device's existing Wi-Fi MACs must be preserved.

### 1.3 MAC Address in API Responses

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
- **No action needed** for portable backup — serial number is not in the backup.

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
- The actual PKI material lives in `/etc/openvpn/` — these files are NOT in
  `/etc/config/` and are NOT captured by our backup tool (which only copies
  `/etc/config/*`).
- If you restore a clone backup and then start the OpenVPN server, GL firmware
  will regenerate the PKI material automatically.
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
- These files live in `/etc/dropbear/`, NOT in `/etc/config/`. They are NOT
  captured by our backup tool.
- The `dropbear` UCI config (`/etc/config/dropbear`) contains SSH port and
  authentication settings — this IS in the backup but is not device-specific
  (it's a deployment choice). In Remote-Safe mode, this file is excluded to
  preserve the target's SSH configuration.
- On restore, the target device keeps its own SSH host keys. Clients will see
  the correct host key fingerprint.

---

## 7. ZeroTier Node Identity

| Location | UCI Path | Description | Example |
|----------|----------|-------------|---------|
| `/etc/config/zerotier` | `zerotier.gl.join` | ZT network join ID | `93afae59635b3dfe` |
| `/var/lib/zerotier-one/identity.secret` | (file) | ZT node private identity | (256-bit key) |
| `/var/lib/zerotier-one/identity.public` | (file) | ZT node public identity | (256-bit key) |

**Notes:**
- The UCI config contains the network join ID — which network this device
  belongs to. Overwriting it disconnects the device from its ZT network.
- The actual node identity (cryptographic keypair) is in `/var/lib/zerotier-one/`.
  This is NOT in `/etc/config/` and is not captured by our backup.
- The ZT node identity determines the device's ZT address (10-digit hex).
  Changing it means the device appears as a new node on the network.
- **Excluded entirely in Remote-Safe mode** — both the UCI config file and
  the associated network/firewall interface sections.
- In Clone mode, the ZT config IS captured (but the node identity in /var/lib
  is not). On restore, ZT will use the target's existing node identity but
  attempt to join the source's network — which may or may not be desired.

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
- **Excluded entirely in Remote-Safe mode.**
- In Clone mode, the UCI config IS captured. On restore, Tailscale will need
  to be re-authenticated on the target device.

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
- The root password hash in `/etc/shadow` is NOT in `/etc/config/` and is NOT
  captured by our backup tool.
- This is a deployment choice (set by operator), not a hardware identifier.
- On GL.iNet routers, the root password also controls the GL Admin Panel login.
- The password hash is used by our shell backend for API authentication
  (challenge-response auth reads `/etc/shadow`).

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

## Summary: What Gets Stripped by GL Portable Backup

### Clone and Remote-Safe Modes

| Category | Config File | Fields Stripped |
|----------|-------------|----------------|
| Wired MACs | `network` | All `option macaddr` lines |
| Wi-Fi MACs | `wireless` | All `option macaddr` lines |
| DDNS identity | `gl_ddns` | username, password, domain, param_enc, lookup_host (v4+v6) |
| WG server keys | `wireguard_server` | private_key, public_key, preshared_key |
| WG/AWG client keys | `network` | private_key, public_key, preshared_key |

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

These device-specific items live outside the UCI config directory and are never
part of our backup archives:

| Item | Location | Regeneration |
|------|----------|-------------|
| Serial number | Firmware/EEPROM | N/A — hardware-burned |
| `board.json` | `/etc/board.json` | N/A — factory-set |
| SSH host keys | `/etc/dropbear/dropbear_*_host_key` | Auto-generated if missing |
| ZeroTier node identity | `/var/lib/zerotier-one/identity.*` | Auto-generated if missing |
| Tailscale node state | `/etc/tailscale/` | Requires re-authentication |
| OpenVPN PKI (CA, certs, keys) | `/etc/openvpn/` | Auto-generated by GL firmware on server start |
| Root password hash | `/etc/shadow` | Set by operator |

---

## Identifier Sources by Discovery Method

How to discover all device-specific identifiers on a live router:

```bash
# MAC addresses in UCI configs
grep -r 'option macaddr' /etc/config/

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

# ZeroTier network
uci show zerotier

# SSH host key fingerprints
dropbearkey -y -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null | grep Fingerprint
dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null | grep Fingerprint
```
