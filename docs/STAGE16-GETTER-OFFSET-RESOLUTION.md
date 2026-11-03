# Stage 16 — 24H32 IOSkywalkPacket layout resolution

## Packet-buffer count

The target-build `getPacketBufferCount` method reads `dword ptr [rdi + 0x64]`. The independent `getPacketBuffers` implementation also reads a dword from `this+0x64`, then uses the pointer at `this+0x30` as its buffer-array base. Thus `mActualNumBuffers` is at `0x64` for macOS 15.8.1 build 24H32. The old vendored comment placing it at `0x60` was stale.

## Packet object size and remaining fields

Stage 14's `sizes.txt` records `IOSkywalkPacket` instance size `0x70`. Target-build `initWithPool` stores the pool pointer at `0x40`, maximum buffer count at `0x60`, and packet index at `0x68`. The `setTransferDirection`, `getTransferDirection`, and `clearTransferDirection` bodies access the dword at `0x6c`. The final in-object field therefore ends at `0x70`.

The older vendored header declared a slot-reference pointer at offset `0x70` and corresponding setter/getter methods. That field would begin exactly one byte beyond the valid object extent, and those two methods are absent from the collected 24H32 `IOSkywalkPacket` method list. There are no project call sites. The field and stale declarations have been removed.

The corrected tail layout is: `mPacketState=0x58`, an unnamed four-byte slot at `0x5c`, `mMaxNumBuffers=0x60`, `mActualNumBuffers=0x64`, `mPacketIndex=0x68`, and `mTransferDirection=0x6c`. The `0x5c` slot remains unnamed because its full semantics are not established.

## Scope

This correction aligns local declarations/comments with target-build ABI evidence. Driver code must use supported accessors, not depend on private fields. It does not enable callbacks, queue registration, packet submission, interface publication, or change RX ownership.
