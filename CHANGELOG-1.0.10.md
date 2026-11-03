# RTL88WiFi 1.0.10 — open association and Private Wi-Fi Address modes

Build identity: `1.0.10-rtl88wifi-r21-20261031`. This is an unofficial
community source update. The macOS kernel extension has not been built with
Apple's Xcode kernel toolchain or tested on physical Wi-Fi hardware; host tests
cover the changed decoder and PRIVATE_MAC handler only.

## Changes

- **Open-network association:** the newer 32-bit ASSOCIATE decoder now accepts
  an empty key object whose embedded key-version is zero, as supplied for an
  unsecured network. WPA2 still requires a version-1 key object and 32-byte
  PMK. This addresses the observed host request that otherwise fell through
  to the Ventura 16-bit parser and appeared as `lower=0, upper=1, ssidLen=0`.
- **PRIVATE_MAC transport:** added a narrowly scoped 28-byte GET/SET bridge for
  selector 238 on the primary interface where the restored family rejects the
  selector before forwarding it to the controller. The split SET hook uses the
  same validated payload handler.
- **Private Wi-Fi Address modes:** Off restores the EFuse/permanent station
  MAC; Fixed retains the host-supplied address or generates one if none is
  supplied; Rotating generates a new locally administered unicast address at
  the requested interval. Host-supplied unicast addresses are preserved as
  supplied, matching Apple's reference behavior.
- **Safe rotation:** changes are serialized through an IOKit workloop timer.
  A rotation that expires during a scan, authentication, association or an
  active link is deferred and retried rather than changing the station MAC
  mid-session. The requested interval is range-checked before milliseconds
  conversion.
- **MAC privacy in logs:** the backend no longer prints every full station
  address when programming it.
- **Country code:** no country is forced or hardcoded. The driver continues to
  use a valid regulatory country delivered by Apple80211 and reports the host
  value; this release does not make macOS replace its currently reported `US`
  with `BD`.
- **Security:** WPA3-SAE remains disabled; WPA2 and eligible transition-mode
  WPA2 fallback remain. This release does not implement OWE, SAE, PMF/BIP,
  or 802.11k/v/r.

## Validation

- `test-assoc-wire.py`: host32 open/no-key version-0 decode, 22-byte SSID,
  legacy misread reproduction, WPA2 and transition tests.
- `test-private-mac.py`: 28-byte ABI, Off/Fixed/Rotating state, supplied and
  generated addresses, interval bounds, pending workloop apply and source
  bridge guards.
- No macOS kernel compilation or over-the-air join validation was possible in
  this build environment. Treat the archive as experimental and retain a
  bootable EFI backup.
