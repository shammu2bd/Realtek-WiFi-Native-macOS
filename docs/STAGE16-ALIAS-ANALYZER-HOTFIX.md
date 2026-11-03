# Stage 16 conservative `this`-alias analyzer hotfix

The first real Stage 16 run returned `REVIEW_REQUIRED` with 7/8 field getters,
while all 11 source checks passed. The original inspector only accepted a
field read whose base register was exactly `rdi`. This can produce a false
negative when optimized x86_64 code first copies the incoming `this` pointer
to a callee-saved register or spills/reloads it through a stack slot.

This hotfix traces only conservative identity aliases:

- register copies such as `mov rbx, rdi`;
- zero-offset `lea` identity copies;
- `mov [rsp/rbp + slot], rdi` stack spills and matching reloads;
- call-clobber handling for SysV caller-saved registers;
- alias invalidation on common arithmetic/bitwise updates.

It deliberately does not follow non-zero pointer adjustments, pointer chasing,
or unrelated register values. The required header-derived offsets are not
changed and no Stage 16 condition is weakened.

The Stage 16 log now includes a `GETTER_AUDIT` line for each of the eight
methods, showing expected offset, observed offsets, and status, followed by
matching instruction evidence. If a method still fails, the new log identifies
exactly which getter and offsets need manual review.

The hotfix changes only the read-only analyzer, its synthetic regression tests,
and Stage 16 documentation. It does not edit driver source or enable TX/RX.
