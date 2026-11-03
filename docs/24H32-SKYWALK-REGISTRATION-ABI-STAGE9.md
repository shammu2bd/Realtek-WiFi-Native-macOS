# Sequoia 24H32 Skywalk registration ABI evidence — Stage 9

Stage 9 improves the read-only ABI collection path. It does not change the Wi-Fi
controller, TX/RX datapath, native Kext link, installed driver, or OpenCore.

## Why this stage is needed

The Stage 8 user-provided `output.log` (GitHub update 2026-11-01 01:10:08 UTC)
contains a successful legacy Kext build and the focused ABI report. The report
has no compiler, linker, or `make` errors. It also shows that the archive's
method lists contain the exact registration methods, but its `asm/` directory
contains complete bodies for only `IO80211InfraInterface::start` and
`IOSkywalkLegacyEthernet::start` among the selected call paths. In particular,
the report says the bodies for `registerInfraEthernetInterface`, both
`registerEthernetInterface` overloads, deregistration, and
`AppleBCMWLANSkywalkInterface::start(AppleBCMWLANCore*, RegistrationInfo*)`
were not found.

This is a collection-list gap, not proof that those functions are absent from
the kernel collection. The upstream kcabi `dump.py` only disassembles the
functions supplied by its reference dump plus its small built-in extra list.
The previous collector invoked it without a reference dump, so most methods
listed in the class `*.methods.txt` files were not disassembled.

## Stage 9 changes

- `tools/prepare-kcabi-ref-24H32.py` creates a temporary kcabi reference dump
  containing 14 exact mangled symbols copied from the 24H32 method evidence:
  both Ethernet registration overloads, Ethernet and network deregistration,
  `registerInfraEthernetInterface`, the matching Apple interface start/stop,
  and the relevant logical-link helpers.
- If `KCABI_REF` points at an existing reference dump, its function symbols are
  merged. The helper only reads those files and writes its generated reference
  under the collector's temporary directory; it does not edit the kcabi clone.
- `tools/collect-sequoia-abi-24H32.sh` now passes that generated reference to
  `dump.py --ref`, making kcabi disassemble the exact methods when their symbols
  are present in the 24H32 kernel collection.
- `tools/audit-skywalk-registration-24H32.py` additionally extracts the row at
  vtable offset `0xc00` from `IO80211InfraInterface.vtable.txt`. Stage 10 later
  corrected the interpretation: this indirect call is a side-method call to
  `setInterfaceOFDMDesense`, not registration. The actual registration call is
  a direct call from `AppleBCMWLANSkywalkInterface::start`.

## Validation

`tests/test-wcl-kcabi-reference-stage9.py` originally used an incorrect synthetic
vtable-slot fixture for `0xc00`; Stage 10 replaces that assertion with the
verified `setInterfaceOFDMDesense` row and a separate direct-registration-call
fixture. Stage 8 focused audit
regressions, Stage 7 RX ownership, Stage 5 RX staging, Stage 4 TX adapter,
controller lifecycle, packet path, queue owner, PCI backend, registration
fences, and the runnable legacy protocol regressions pass.

The Stage 9 change is tooling-only. It does not need to be linked into the
legacy Kext and does not change the `AIRPORT_ALL_OBJS` list. No new claim of
runtime or hardware validation is made.

## Next action on the target Mac

From the project root on macOS Sequoia 15.8.1 build 24H32, collect a fresh
archive into a new output directory (so no existing ABI archive is overwritten):

```sh
tools/collect-sequoia-abi-24H32.sh build/sequoia-abi-24H32-stage9
```

Then append the focused report to the one project-root `output.log`:

```sh
cd driver/RTL88WiFi
make ABI_ARCHIVE="../../build/sequoia-abi-24H32-stage9/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz" \\
    wcl-abi-audit-24h32 2>&1 | tee -a ../../output.log
```

Upload only the root `output.log` to GitHub. If a required function body still
reports missing, keep its call fenced; do not infer a return type from the
mangled name alone. Registration, RX completion enqueue, BSD publication, and
radio start remain disabled until the target bodies, call-site result checks,
output writes, and cleanup paths have been reviewed.
