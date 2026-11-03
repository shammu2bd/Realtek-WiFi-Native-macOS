# Stage 15 — generic Skywalk packet-access ABI audit

## Purpose

Stage 14 collected the generic 24H32 method lists and method bodies for the
packet queue, packet-buffer pool, queue set, logical link, memory segment,
packet buffer, packet and network-packet classes. Stage 15 consumes that
archive and audits the exact accessors used by the current packet view and RX
adapter.

The audit checks two things for every required C++ member call:

1. The demangled method appears in the expected class's Stage 14 method list.
2. The exact mangled symbol is also represented in the Stage 14 disassembly
   reference set.

This is an evidence-presence check only. It does not infer return-value
semantics, pointer lifetime, locking, callback context, object ownership
transfers, mapping lifetime, or whether an API is safe to call from TX/RX
callbacks. Those conclusions require individual disassembly and matching
24H32 public/private header review before any datapath callback is enabled.

## Required method surface

The audit covers the methods already called by these files:

- `RTW88WCLPacketView.hpp`
- `RTW88WCLSkywalkRxAdapter.cpp`

Target APIs:

- `IOSkywalkPacket`: packet type, pool, buffer count/list, data offset/length,
  and data-offset/length setter.
- `IOSkywalkPacketBufferPool`: packet allocation and deallocation.
- `IOSkywalkPacketBuffer`: pool, memory segment, segment offset, buffer size,
  and data offset/length.
- `IOSkywalkMemorySegment`: memory descriptor and virtual address.
- `IOSkywalkNetworkPacket`: completion status setter.

## Run on macOS 15.8.1 / 24H32 / x86_64

From the Stage 14 project root:

```sh
python3 tests/test-skywalk-packet-access-stage15.py
python3 tools/audit-skywalk-packet-access-stage15.py \
  --archive build/sequoia-abi-24H32-stage14/RTL88WiFi-Sequoia-24H32-stage14-generic-skywalk-segment-packet-kcabi.tar.gz \
  --out build/sequoia-abi-24H32-stage15
```

The script uses `llvm-cxxfilt` or `c++filt` to demangle the exact Itanium
symbols. If automatic discovery fails, pass `--demangler /absolute/path/to/llvm-cxxfilt`.

Outputs:

- `build/sequoia-abi-24H32-stage15/stage15/STAGE15-ABI-ACCESSOR-AUDIT.md`
- `build/sequoia-abi-24H32-stage15/stage15/STAGE15-ABI-ACCESSOR-AUDIT.json`
- `build/sequoia-abi-24H32-stage15/RTL88WiFi-Sequoia-24H32-stage15-packet-accessor-audit.tar.gz`
- a sibling `.sha256` checksum file

The archive contains matched method-body evidence for the accessor calls that
were found. An incomplete audit still writes a diagnostic report and archive,
but exits with status 2. Do not treat an incomplete result as approval to
change the packet path.

## Safety boundary

Stage 15 is read-only. It does not edit Kext source, instantiate kernel
objects, register or schedule queues, accept TX/RX callback packets, publish a
BSD interface, start the radio, or change OpenCore/legacy-driver settings.
