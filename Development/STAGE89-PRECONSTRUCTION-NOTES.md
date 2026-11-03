# Stage 89 — queue service-class and array preconstruction notes

**Target:** macOS Sequoia 15.8.1 / build 24H32 / x86_64 / PCIe RTL8821CE.  
**Status:** in progress; constructor ABI review precedes the pointer-array patch.

## Why the first Stage 89 pass is an audit

The Stage 61/80 evidence establishes four queue role typecodes: 1 TX submission, 2 TX completion, 3 RX submission, and 4 RX completion. The Stage 85/87 evidence establishes a separate WMM predicate: exactly one supplied queue must return each of the four service-class values decoded in Stage 88. The Stage 88 evidence also establishes that the caller's pointer array must remain valid through the synchronous registration call, while QueueSet copies and retains the queue objects after successful initialization.

The current SDK headers expose an explicit service-class factory/initializer for TX submission and an explicit service-class argument for RX submission. The TX-completion and RX-completion factory signatures do not expose the same parameter. The current driver source calls the default TX-submission factory, uses service class 0 for RX submission, and calls default completion factories.

This API asymmetry means the four values returned by the actual 24H32 queue objects must be established from target kernel-collection method bodies before the array is implemented. The numeric WMM table alone does not identify which concrete queue constructor supplies which value.

## Stage 89 V1 audit

Run `Development/stage89-v1-queue-service-class-constructor-audit.sh` on the target Mac. It verifies the Stage 88 predecessor and Stage 73 source fingerprint, rechecks the queue typecode/WMM evidence, inventories the current public factory signatures and source arguments, and extracts the actual 24H32 `getServiceClass`, `withPool`, `withPoolAndServiceClass`, and `initWithPool` method bodies from `BootKernelExtensions.kc`.

The script stores local artifacts under `run log/stage89/<run>/`, uploads evidence to `Development/Logs/stage89/<run>/`, and appends the result to `Development/output.log`. It does not edit source, build, sign, install, load, alter SIP/NVRAM, or modify OpenCore. Its expected first-pass result is `REVIEW_REQUIRED` until the captured initializer bodies have been reviewed. That is an intentional safety gate, not a run failure.

## Implementation gate

Only after reviewing the captured methods should Stage 89 add explicit service-class construction and a typed four-pointer array in deterministic typecode order. The pointer array must remain valid through the synchronous registration call. No `mServiceClass` writes or other private-field patches are permitted without exact 24H32 evidence and a reviewed need. The native registration call and all four TX/RX callback handoffs remain disabled.
