# Stage 18 — RX/TX ownership contract review dossier

## Purpose

Stage 17 is accepted as a read-only evidence-collection pass: its 24H32 run reported 743/743 executable target method bodies, 19/19 source ownership fences, and zero missing functions. Stage 17 explicitly left the datapath blocked pending manual contract review.

Stage 18 packages the exact relevant Stage 17 method bodies next to numbered source excerpts for six unresolved contracts:

1. RX completion enqueue ownership and callback packet-array semantics.
2. RX submission dequeue, buffer replenishment and retry ownership.
3. TX completion queue acceptance and packet-retain transfer.
4. Packet-buffer and memory-segment prepare/complete requirements.
5. Ethernet interface registration, failure ownership and deregistration.
6. Queue enable/disable/synchronize and teardown ordering.

## What the tool verifies

- Stage 14, 15, 16 and 17 archive SHA-256 linkage.
- PASS state and complete executable-method coverage in the Stage 17 report.
- Stage 17 platform identity: macOS 15.8.1 (24H32), x86_64.
- Each target class method list and `asm/INDEX.txt` entry.
- Exact assembly bodies for methods selected into each contract dossier.
- Current driver source snapshots with line-numbered excerpts for relevant operations.

Method-name filtering is only a retrieval aid. It does not infer ownership from a method name or claim that a selected method implements a particular contract. Each candidate body and call path must be read manually.

## Output

`stage18-work/STAGE18-OWNERSHIP-CONTRACT-REVIEW.md` and `.json` list evidence for each contract, candidate kernel methods, source snippets, and explicit review questions. Exact method bodies are copied to `stage18-work/evidence/methods/`; source snapshots are placed in `stage18-work/evidence/source/`.

The expected status is `READY_FOR_MANUAL_REVIEW`, not `PASS`. Each contract remains `MANUAL_REVIEW_REQUIRED` until an engineer documents the actual success/failure ownership transitions, reference counts, callback context, retries and teardown ordering.

## Safety boundary

This stage changes no driver source and does not register queues, submit/enqueue packets, start the radio, publish the Ethernet interface, or enable TX/RX callbacks. The output explicitly keeps datapath activation blocked.
