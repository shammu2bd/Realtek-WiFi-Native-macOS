# RTL88WiFi 1.0.11 — Private Wi-Fi Address Skywalk dispatch

Build identity: `1.0.11-rtl88wifi-r22-20261031`. This is an unofficial
community source update. The macOS kernel extension has not been built with
Apple’s Xcode kernel toolchain or tested against the Settings UI on physical
hardware. Host-side tests check selector dispatch structure and the existing
Off/Fixed/Rotating state machine.

## Changes

- **Skywalk GET:** adds `apple80211_ioctl_get(IO80211SkywalkInterface *, void *)`
  and routes primary-interface selector 238 to the private-MAC GET handler.
- **Skywalk SET:** routes selector 238 through the same strict 28-byte payload
  adapter in the Skywalk-only split SET ingress.
- **Legacy split GET:** adds the corresponding `IO80211Interface` GET override.
- **Unified marshalling:** legacy ioctl, Legacy split GET/SET, and Skywalk split
  GET/SET use one checked copyin/copyout adapter. Other selectors and virtual
  interfaces continue to the family implementation.
- **Diagnostics:** records `STA_PRIVATE_MAC_GET_SEEN`,
  `STA_PRIVATE_MAC_SET_SEEN`, `STA_PRIVATE_MAC_LAST_RET` and logs the exact
  ingress name without logging the MAC address.

## Why this change

Version 1.0.10 had a 28-byte selector handler and a Legacy BSD ioctl bridge, but
its source did not override the Skywalk split GET method and did not process
selector 238 in the Skywalk-only split SET method. That left a likely modern
macOS request path unhandled. This release fills those missing hooks. It is a
source-level diagnosis based on the available IO80211Controller SDK method
signatures and the user’s report showing no PRIVATE_MAC GET/SET events.

## What is not claimed

- This cannot override an MDM/configuration-profile restriction. Apple documents
  that a managed Mac may not allow this setting to be changed.
- This release does not add an undocumented CARD_CAPABILITIES bit.
- The dropdown becoming active and MAC changing correctly still require testing
  on the user's macOS version and adapter.
- WPA3-SAE remains disabled. Existing open Wi-Fi and WPA2 paths are preserved.
- Country code is not forced to US or BD.

## Validation

Host-side Python tests can verify source routing and the mode-state handler.
A real Xcode/macOS kernel build, Skywalk callback confirmation, System Settings
menu test, Off/Fixed/Rotating MAC transition test, and MDM-policy check remain
necessary. Keep a bootable EFI backup before installing.
