# Sequoia 24H32 Skywalk RegistrationInfo — Stage 11

## Scope

Stage 11 adds an aligned, persistent `0x130`-byte storage object and a
compile-only builder for the private `IOSkywalkEthernetInterface::RegistrationInfo`
argument. It is limited to the Apple Sequoia 15.8.1 / Darwin 24H32 x86_64 ABI
that was inspected in the Stage 10 kernel-collection archive.

**This stage does not enable interface registration or data-path operation.**
`RTW88WCLInfraInterface::start()` remains fail-closed. The builder is not called
from `start()`, and no call to `registerInfraEthernetInterface()`,
`registerEthernetInterface()`, or `registerNetworkInterface()` was added.

## ABI evidence used

The focused 24H32 disassembly establishes the following producer behavior:

1. `AppleBCMWLANCore::createSkywalkInterface` clears exactly `0x130` bytes of
   stack storage, then calls
   `IOSkywalkEthernetInterface::initRegistrationInfo(info, 1, 0x130)`.
2. `initRegistrationInfo` checks a non-null pointer, option `1`, and exact size
   `0x130`; it clears bytes `[0x08, 0x130)` and writes the first qword as
   `0x0000013000000001`. It fills additional opaque values from interface
   virtual hooks, so the local builder must call this initializer rather than
   fabricate the entire payload.
3. After the initializer returns, Apple's caller overwrites these exact
   locations:

   | Offset | Width | Value / source |
   |---:|---:|---|
   | `0x0c` | 4 bytes | `3` |
   | `0x14` | 4 bytes | `2` |
   | `0x24` | 8 bytes | `0x0000008000000080` |
   | `0x40` | 4 bytes | `0` |
   | `0x108` | 6 bytes | Hardware address copied from create parameters |

   These payload offsets are intentionally called *opaque slots*. The source
   does not assign them speculative field names or meanings. The six-byte
   address range is the only region identified as the hardware address by its
   use in the infra registration routine.
4. `IO80211InfraInterface::registerInfraEthernetInterface` may replace those six
   bytes with the interface's current hardware address before forwarding to
   Ethernet registration. Stage 11 does not call that routine.

## Implementation

- `RTW88WCLRegistrationInfo.hpp` defines `alignas(8)` storage with a compile-time
  size assertion of exactly `0x130` bytes and bounds assertions for every
  explicitly written range.
- `RTW88WCLInfraInterface` owns the storage so its address remains stable for
  any later ABI work. It is cleared on initialization, `stop()`, and `free()`.
- `prepareRegistrationInfo()` calls the audited initializer with option `1`
  and size `0x130`, applies only Apple's observed post-initializer writes, and
  validates those known bytes. All other initializer-populated bytes remain
  untouched.
- No queue, pool, logical-link, BSD-interface, radio, RX-delivery, or TX
  completion state is changed by this stage.

## Validation

Run from the repository root:

```sh
python3 tests/test-wcl-registration-info-stage11.py
python3 tests/test-wcl-registration-abi-stage10.py
python3 tests/test-wcl-registration-contract.py
python3 tests/test-wcl-skywalk-queues.py
python3 tests/test-wcl-rx-packet-retention-stage7.py
python3 tests/test-wcl-rx-adapter-stage5.py
python3 tests/test-wcl-kcabi-reference-stage9.py
python3 tests/test-wcl-tx-adapter-stage4.py
python3 tests/test-wcl-packet-path-stage2.py
python3 tests/test-wcl-pci-backend-owner.py
python3 tests/test-wcl-controller-lifecycle.py
```

The Stage 11 Python test also compiles and runs the header-level C++ test with
`-std=c++17 -Wall -Wextra -Werror`. These are host-side layout and source
checks. They do **not** demonstrate that the native object compiles against the
macOS SDK, that the kext loads, or that Wi-Fi works.

## Remaining blockers before registration

Do not call this builder from `start()` or enable registration until the next
ABI stages independently establish queue ordering and queue-count semantics,
packet-pool roles and ownership, lifetime/refcount behavior, RX refill and
completion behavior, TX completion handoff, and registration failure/stop
rollback. BSD publication and radio start remain fenced as well.
