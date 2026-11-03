# Run Stage 16

1. Apply the Stage 16 overlay to the project root.
2. Run `tools/run-stage16.sh` from any directory.
3. The runner checks the Stage 14 and Stage 15 archives, runs the synthetic
   regression test, and invokes the read-only Stage 16 auditor through `runlog`
   when the configured helper is available.
4. The output archive is written under `build/sequoia-abi-24H32-stage16/` and
   should be uploaded with `output.log` by the runlog helper.

A `PASS` means only that the explicit size/offset/source checks passed. The
report intentionally retains unresolved Apple API ownership and mapping
contracts. It is not permission to enable the packet datapath.
