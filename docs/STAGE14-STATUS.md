# Stage 14 status

- Purpose: collect generic 24H32 Skywalk memory-segment, packet-buffer, packet
  and network-packet method bodies needed to close pool/buffer ownership.
- Stage 13 archive was fetched from the GitHub root and its SHA-256 was checked
  against the hash printed by the target Mac collector.
- Stage 13 established that Apple BCM PCIe uses a provider-specific pool and
  memory-segment subclass; that implementation is reference-only.
- Stage 14 adds only a read-only WTLKcAbi collector, reference-preparation
  helper, host regression tests and documentation. No Kext source or OpenCore
  config is changed.
- Root cause of the first Stage 14 failure: upstream `dump.py` writes method
  and vtable reports only for its explicit `CLASSES` allow-list, which omitted
  `IOSkywalkMemorySegment`; its separate size inventory still included it.
- The collector now makes an isolated temporary copy of WTLKcAbi and adds
  `IOSkywalkMemorySegment` to that copy's class list. The user's source checkout
  is not modified. No symbols are fabricated.
- Stage 14 unit tests, Python syntax checks, shell syntax validation and the
  Stage 8–13 host regression tests pass in the prepared bundle.
- Target-Mac 24H32 collection remains pending; Stage 14 is not marked complete
  until the collector writes all eight method lists and the two-pass archive.
