# Stage 17 — complete target method-body collection fix

The first real Stage 17 run listed the 13 class method tables but only disassembled the earlier-stage reference subset. The audit then compared every method-table symbol with `asm/INDEX.txt`, producing a misleadingly low body count (27/782).

This fix changes only the temporary `WTLKcAbi/dump.py` copy created by the Stage 17 collector:

1. It still verifies the exact 13 required classes and includes `IOSkywalkMemorySegment`.
2. It enumerates `kc.methods(cls)` for every target class from the actual 24H32 kernel collection.
3. It adds every method whose address is in an executable segment to the `funcs` disassembly queue.
4. It writes `stage17-executable-methods.txt`, separating code symbols from non-code symbols such as static metadata.
5. The audit compares this executable-method inventory with `asm/INDEX.txt`, and reports non-code symbols separately. It does not count data symbols as missing method bodies.

The patch affects only a temporary kcabi working copy. It does not change the user's checked-out kcabi repository or activate driver queue registration, packet submission, RX/TX callbacks, radio start, or interface publication.

## Run

Extract this overlay into the RTL88WiFi project root. Run `tools/run-stage17.sh` through the user's existing runlog helper. The runner creates a timestamped diagnostic archive and uploads it together with `output.log`.

The Stage 17 audit can pass only if every executable method listed by the target-build class method tables has a matching disassembly entry and all 19 source ownership fences remain satisfied. Non-code class symbols are listed separately.
