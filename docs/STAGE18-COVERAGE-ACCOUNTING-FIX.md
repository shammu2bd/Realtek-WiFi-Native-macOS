# Stage 18 — Stage 17 coverage accounting fix

## Why the previous Stage 18 run stopped

Stage 17 deliberately distinguishes three counts:

- `target_method_symbol_count`: all 782 entries in the 13 target class method lists;
- `target_executable_method_symbol_count`: the 743 methods located in executable kernel segments;
- `target_non_code_symbol_count`: 39 non-code symbols, such as metadata/vtable entries, which must not be expected to have instruction bodies.

`target_method_disassembly_count` is 743. The previous Stage 18 gate incorrectly compared that value to all 782 symbols, so it rejected a complete Stage 17 collection.

## What changed

The Stage 18 builder now validates:

1. Exactly the 13 requested IOSkywalk classes are in the per-class coverage report.
2. For each class, `method_symbols = executable_method_symbols + non_code_symbols`.
3. For each class, `executable_method_symbols = disassembled + missing_disassembly`.
4. The aggregate report totals equal the sum of its per-class counters.
5. Every executable method has an INDEX entry and exact assembly file in the Stage 17 archive.
6. `target_method_disassembly_count = target_executable_method_symbol_count`; all 39 non-code symbols remain explicitly excluded from body coverage.

A negative regression fixture verifies that incomplete executable coverage still fails closed.

## Safety boundary

This update only fixes the Stage 17 evidence accounting gate. The six Stage 18 ownership contracts remain `MANUAL_REVIEW_REQUIRED`, and TX/RX queue activation, packet ownership transfer, radio start and interface publication remain blocked.
