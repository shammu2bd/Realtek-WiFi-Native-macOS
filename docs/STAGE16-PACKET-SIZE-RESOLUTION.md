# Stage 16 — IOSkywalkPacket size discrepancy: resolved

The Stage 14 24H32 kernel collection reports `IOSkywalkPacket` instance size `0x70`. Stage 16 previously expected `0x78` from a stale SDK header, creating a false `REVIEW_REQUIRED`.

The target method evidence is internally consistent with a `0x70` object:

- `initWithPool`: pool pointer `[this+0x40]`, maximum-buffer count `[this+0x60]`, packet index `[this+0x68]`.
- `getPacketBufferCount`: 32-bit actual count `[this+0x64]`.
- `getPacketBuffers`: count `[this+0x64]`, buffer-array pointer `[this+0x30]`.
- transfer-direction setter/getter/clear: 32-bit direction `[this+0x6c]`.

The final 32-bit member at `0x6c` ends at `0x70`. The old SDK's slot-reference pointer at `0x70` cannot belong to this 24H32 class instance. The collected class method list also has no slot-reference setter/getter symbol; the project has no call sites. The stale header declarations and member were removed.

The audit now requires Stage 14 size `0x70`, validates all documented private-field offsets in the vendored header, and verifies that no slot-reference field or accessors remain. It does not infer the meaning of the unnamed 4-byte slot at `0x5c`.
