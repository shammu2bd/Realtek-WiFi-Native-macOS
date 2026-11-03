# Sequoia 24H32 WCL — Stage 8: complete registration ABI evidence

## Why this stage exists

Stage 7's native packet ownership can now be built on the target Xcode 16.4
installation, but registration and RX completion are still deliberately fenced.
The first ABI audit included method names, offsets, size metadata, and keyword
context. It did not include the complete disassembly bodies needed to settle
non-virtual return conventions, output parameters, cleanup, or caller-side
success checks. Guessing those contracts would be unsafe.

## Changes

- Expanded `tools/audit-skywalk-registration-24H32.py` with
  `--full-registration-asm` to emit complete disassembly members for matching
  24H32 registration/deregistration overloads and known Apple interface start
  call paths.
- Added matching symbol-index rows to correlate method names with addresses
  and sizes from the same kcabi archive.
- Added `--stdout` so the report can be appended to the user's existing single
  project-root `output.log`; no Desktop or separate audit log is created.
- Added `make wcl-abi-audit-24h32`, with `ABI_ARCHIVE` override and a default
  path matching the previously reported Downloads location.
- Kept output bounded, restricted to safe regular tar members, and avoided
  extracting archive paths to disk.

## How to run on the target Mac

After the normal successful build, from `driver/RTL88WiFi` run:

```sh
make wcl-abi-audit-24h32 2>&1 | tee -a ../../output.log
```

If the archive is in another location:

```sh
make wcl-abi-audit-24h32 ABI_ARCHIVE="$HOME/path/RTL88WiFi-Sequoia-24H32-kcabi.tar.gz" 2>&1 | tee -a ../../output.log
```

Upload only the project-root `output.log` to GitHub. The report is expected to
show complete bodies and caller paths, after which those instructions can be
reviewed to determine register argument usage, bool/status handling, output
writes, packet ownership, and failure cleanup.

## Safety boundary

This is an evidence-collection stage, not a datapath activation. It does not
call `registerEthernetInterface`, `registerNetworkInterface`, or any queue
completion API. The native controller, RX/TX adapters, and queue objects remain
compile-only and excluded from the working legacy Kext link. No radio start,
interface publication, kext installation, or OpenCore change is made.

## Validation

`tests/test-wcl-registration-abi-extractor-stage8.py` constructs a synthetic
kcabi archive and checks complete function-body emission, call-path inclusion,
symbol-index association, compatibility with the old context mode, safe-member
handling, and Makefile integration. The Stage 7 tests continue to guard packet
ownership and teardown sequencing.
