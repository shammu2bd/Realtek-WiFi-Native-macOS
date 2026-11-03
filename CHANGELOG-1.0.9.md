# RTL88WiFi 1.0.9 — host association ABI and open-network fix

Build identity: `1.0.9-rtl88wifi-r20-20261031`. This is an unofficial community
source update, not an upstream release. It has not been built with Apple's
macOS kernel SDK or verified against a physical access point in this
environment.

## Fixed / changed

- **Decode the newer 32-bit host ASSOCIATE payload.** The macOS 15/26 restored
  IO80211 path can pass a 32-bit field layout directly to the native
  `apple80211Request` callback. The driver previously interpreted it as the
  older Ventura structure, whose mode/auth fields are 16-bit. For an open
  network this produced the observed false values `auth lower=0`,
  `auth upper=1`, `SSID length=0`, causing the handler to reject the request
  before it reached the open-system association code. The new path validates
  the 108-byte common prefix with the existing strict `RTW88AssocWire` decoder,
  translates it to the legacy internal structure, and then uses the existing
  join path. The unknown request tail is not parsed.
- **WPA3-SAE remains disabled.** SAE-only requests remain rejected. A transition
  request may use the existing WPA2-PSK fallback only when WPA2-PSK is present
  and the decoded request includes the expected PMK.
- **Diagnostics are corrected.** A lower-auth value other than `1` is no longer
  automatically labelled WPA3. An empty SSID and the exact `lower=0 / upper=1`
  signature are reported as a possible 32-bit/16-bit ABI mismatch, not as proof
  of SAE. Early-rejected association headers are logged with lengths and flags
  only. The report now distinguishes a current result from a stale return value.
- **Country behavior remains host-driven.** The driver has no forced US or BD
  default. It continues to apply a valid country code supplied by Apple80211;
  this release does not claim to correct a country code that macOS itself
  reports as `US`.

## Validation

- Association wire decoder tests pass, including a regression reproducing the
  exact `lower=0 / upper=1 / SSID length=0` misread and verifying that the
  32-bit open request decodes to `lower=1 / upper=0 / SSID length=3`.
- Join-report tests pass.
- Roaming scan-policy source tests pass.
- Apple-only tests requiring `xcrun`/Xcode could not run in the Linux build
  environment. One unrelated test also hits a Linux `thread_t`/`NULL` type
  incompatibility. The macOS kext build and hardware join test remain required.
