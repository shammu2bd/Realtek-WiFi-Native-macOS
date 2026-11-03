# Stage 16 status

- Goal: correlate Stage 15 target-build method-body evidence with exact 24H32 class instance sizes and private-field offsets, then audit existing RX conversion/ownership fences.
- Inputs: Stage 14 kcabi archive, Stage 15 accessor audit archive, and the current project source tree.
- The read-only audit checks Stage 14/15 SHA linkage, three class instance sizes, nine getter offsets, the local `IOSkywalkPacket` header boundary, and eleven RX bounds/ownership/publication source invariants.
- Target-build `IOSkywalkPacket` instance size is `0x70`, not the stale header-derived `0x78`. Stage 14 `sizes.txt` is authoritative for the 24H32 MetaClass size.
- In 24H32 `initWithPool` writes the pool pointer at `0x40`, max-buffer count at `0x60`, and packet index at `0x68`. `getPacketBufferCount` and `getPacketBuffers` both read the actual count at `0x64`. Transfer-direction set/get/clear methods use `0x6c`.
- The object ends at `0x70`; there is no room for the old slot-reference field at `0x70`. The 24H32 class method list also contains no slot-reference setter/getter methods, and the project has no call sites. Those stale declarations and the out-of-bounds member are removed from the vendored header.
- The four-byte slot at `0x5c` remains semantically unnamed. No assumption is made about its meaning beyond the observed accesses documented in the header.
- The audit traces only conservative, unadjusted `this` aliases through registers and stack spill/reload slots. It rejects non-zero pointer adjustments and unrelated registers.
- No driver datapath code is enabled. This stage does not register queues, submit packets, publish an interface, or activate callbacks.
- Open contracts remain for memory-segment prepare/complete, RX completion-queue ownership, queue registration, TX submission/completion, and teardown ordering. These need separate evidence before datapath activation.
