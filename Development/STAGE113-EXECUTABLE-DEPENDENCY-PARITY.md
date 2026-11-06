# Stage113 — executable-derived dependency parity

**Target:** macOS Sequoia 15.8.1 (24H32), x86_64  
**Scope:** synchronize native bundle `OSBundleLibraries` from the linked executable  
**Status:** implementation published; target-Mac test/build not yet run

## Why this stage exists

The EFI native bundle's executable was brought into byte-for-byte parity with the Stage108 build, but the bundle plist still contained an inherited dependency dictionary. The target Mac's `kmutil libraries --bundle-path ... --xml` output for that executable included `com.apple.kpi.private = 24.6.0`, which was absent from the plist. Stage112 also reported bad code-signature and ownership diagnostics. This stage addresses the metadata discrepancy only; it does not claim that this is the sole load blocker.

## Implementation

`tools/sync-native-dependencies-from-linked-binary.py` runs after the native link and bundle skeleton sync. It:

1. Invokes `/usr/bin/kmutil libraries --bundle-path <bundle> --xml` against the just-linked bundle.
2. Parses the returned XML plist, tolerating the human-readable status preamble.
3. Requires IO80211Family, IOSkywalkFamily, IOPCIFamily and IONetworkingFamily entries.
4. Rejects IO80211FamilyLegacy.
5. Replaces only `OSBundleLibraries` in the output bundle's Info.plist with the executable-derived dictionary.
6. Preserves the bundle identifier, executable name, personalities and other plist keys.

The Makefile makes the native link target wait for the mocked dependency-sync regression test and runs the synchronizer after linking. The normal legacy target is unchanged.

## Tests

Run on the target Mac from the repository root:

```sh
python3 tests/test-native-dependency-sync-stage113.py
make -C driver/RTL88WiFi rtl88wifi-native
```

The test covers XML preamble parsing, required dependency enforcement, legacy dependency rejection, exact dictionary replacement and preservation of unrelated metadata.

## Safety and limits

This stage does not sign, install, load or unload a kext. It does not change EFI/OpenCore, SIP, NVRAM or hardware state. The generated bundle remains unsigned. `kmutil libraries` output is dependency metadata, not proof that AMFI accepts the bundle or that the kernel loads it. Stage112's filesystem ownership and bad-code-signature diagnostics remain separate and must be addressed through a separately authorized, supported signing/packaging path. No ownership changes or signing are performed here.

**PR #4 remains draft/open/unmerged.**
