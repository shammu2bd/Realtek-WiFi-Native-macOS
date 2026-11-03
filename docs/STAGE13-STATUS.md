# Stage 13 status

- Purpose: identify how Apple's PCIe Skywalk provider creates its packet pools
  and resource queues, while retaining the already-reviewed generic queue/pool
  lifecycle and registration evidence.
- Scope: read-only 24H32 kernel-collection extraction on macOS 15.8.1 x86_64.
- No Kext code is changed or linked; no private calls are enabled.
- Targeted classes: `IOSkywalkPacketQueue`, `IOSkywalkPacketBufferPool`,
  `IOSkywalkQueueSet`, `IOSkywalkLogicalLink`, `AppleBCMWLANPCIeSkywalk`, and
  `AppleBCMWLANPCIeSkywalkPacketPool`.
- Exit condition: all six exact method lists are found, the second kcabi pass
  completes without missing targets, and the Stage 13 archive hash is logged.
