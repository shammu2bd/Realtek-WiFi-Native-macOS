# RTL88WiFi 1.0.8 — open-network and WPA3-transition handling

## Fixed

- Corrected the Association Request Capability Information field. The old base value `0x0431` set the 802.11 Privacy bit even for open networks. Open joins now use `0x0421`; protected WPA2 joins use `0x0431`.
- Made the WPA2 selection policy require the BSS Privacy capability bit. A stale RSN hint or an unexpected PMK can no longer turn a genuinely open BSS into a protected association.
- Extended RSN AKM inspection to identify SAE/FT-SAE and the PMF Required (MFPR) bit.
- Added WPA2-PSK fallback for WPA2/WPA3 transition BSSs only when the AP permits a non-PMF WPA2 association.
- Rejects SAE-only or PMF-required networks clearly, because this driver does not yet implement SAE commit/confirm, PMF negotiation, or BIP management-frame keys.
- Allows the known WPA2-PSK + WPA3-SAE transition auth mask through the newer host association bridge, while keeping SAE-only requests unsupported.

## Security support status

- Open: supported by the open-system authentication path; association Privacy bit is now clear.
- WPA2-Personal (CCMP-PSK): supported by the existing PSK/4-way handshake path.
- WPA2/WPA3 transition: WPA2-PSK fallback only, where PSK is advertised and PMF is optional.
- WPA3-Personal (SAE-only): **not implemented**.
- PMF-required networks: **not implemented; rejected deliberately**.

This release does not claim full WPA3 support. Real WPA3-Personal needs a complete SAE exchange and PMF/BIP support, not just an RSN AKM flag.

## Validation

The host tests for association-wire parsing and join/security policy pass. The full macOS kernel extension build and hardware association tests still need to be run on macOS with Xcode and a supported PCIe adapter. Two unrelated host tests depend on Apple-only SDK facilities and cannot run in the Linux test container.
