# Sequoia 24H32 Skywalk queue and packet-pool ABI audit — Stage 12

## Stage 11 build result

The Stage 11 root `output.log` was checked on 2026-11-01. It ends with
`LD RTL88WiFi`, kext synchronization, and `OK build/out/RTL88WiFi.kext`.
There are compiler warnings but no compile or link errors in that run. This is
a build result only; it is not a kext-load or Wi-Fi runtime test.

## Why Stage 12 is an ABI evidence stage

The Stage 10 registration disassembly established the call chain and
`IOReturn` convention, and Stage 11 added a persistent, initialized
`0x130`-byte `RegistrationInfo` payload. The remaining high-risk unknowns are
how packet queues and packet-buffer pools are created, retained, transferred,
used by the queue set/logical link, and released during failed registration,
stop, and free.

Stage 12 therefore expands the read-only 24H32 kernel-collection capture to
include every exact method symbol in these four IOSkywalk classes:

- `IOSkywalkPacketQueue`
- `IOSkywalkPacketBufferPool`
- `IOSkywalkQueueSet`
- `IOSkywalkLogicalLink`

This includes their constructors/initializers, queue factories, pool methods,
retain/release paths, start/stop/free methods, and any other methods actually
present in the matching 24H32 method lists. Names are discovered from the
local kernel collection's method lists, not guessed or hard-coded. The
existing Stage 8–10 registration targets are preserved in the second pass.

## Collector behavior

`tools/collect-sequoia-abi-24H32-stage12.sh` is a two-pass, read-only helper:

1. It verifies macOS 15.8.1, Darwin 24H32, and Intel x86_64.
2. Pass 1 runs `kcabi` with the existing exact registration targets and obtains
   the full class method lists.
3. `prepare-kcabi-ref-24H32-stage12.py` extracts exact Itanium symbols from
   the four selected `.methods.txt` files. It accepts symbols embedded in
   method-list rows and, when those rows are demangled-only, falls back to
   exact class-owned mangled symbols in `INDEX.txt`. It never synthesizes or
   guesses a symbol. Existing seed references are retained.
4. If extraction still fails, the collector prints the method-list preview and
   preserves its temporary pass data, including all four `.methods.txt` files
   and `INDEX.txt`, for inspection. A failed extraction is not a completed
   audit and must not be treated as one.
5. Pass 2 asks `kcabi` to disassemble all those exact methods, in addition to
   the existing registration targets.
6. The full evidence tree is archived under the specified Stage 12 build
   directory and SHA-256 is printed.

The script does not load a kext, alter OpenCore/EFI, modify the kernel
collection, or call any Skywalk registration API.

## Run on the target Mac

From the Stage 12 repository root:

```sh
python3 tests/test-wcl-queue-pool-ref-stage12.py
bash -n tools/collect-sequoia-abi-24H32-stage12.sh

tools/collect-sequoia-abi-24H32-stage12.sh build/sequoia-abi-24H32-stage12 2>&1 | tee output.log
```

Upload only the project-root `output.log` to the same GitHub location for
review. The ABI archive remains in the ignored `build/` directory; do not upload
it unless a later review specifically needs its raw contents. If the collector
fails, its output will include a `diagnostic pass data retained at` temporary
path and a short method-list preview; the full temp tree remains available on
the Mac for further inspection.

## Safety boundary

Stage 12 deliberately does not add queue/pool object creation, reference
counting, registration calls, registration rollback, BSD publication, RX
delivery, or TX completion. Those must wait until the newly captured function
bodies support a precise ownership and lifetime map. The Stage 11
`RTW88WCLInfraInterface::start()` fail-closed behavior remains unchanged.
