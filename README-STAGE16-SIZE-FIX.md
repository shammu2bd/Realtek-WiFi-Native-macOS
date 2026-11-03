# Apply Stage 16 packet-size correction

Download `RTL88WiFi-Stage16-packet-size-fix-overlay.zip` to `~/Downloads`, then run:

```zsh
PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
OVERLAY="$HOME/Downloads/RTL88WiFi-Stage16-packet-size-fix-overlay.zip"

[[ -d "$PROJECT" ]] || { echo "Project folder missing"; exit 2; }
[[ -f "$OVERLAY" ]] || { echo "Overlay ZIP missing"; exit 2; }

/bin/bash "$PROJECT/tools/apply-overlay-and-run.sh" \
  "$OVERLAY" tools/run-stage16.sh
```

The helper extracts the overlay into the project, then Stage 16 runs its synthetic regression suite and real audit against the local Stage 14/15 archives. `runlog` uploads the resulting archive and output log when configured.

Expected target-build packet size: `0x70`. Expected final member: `mTransferDirection` at `0x6c`, ending at `0x70`. The stale slot-reference field/accessors are removed. Stage 16 remains read-only; a PASS does not activate TX/RX callbacks or queue submission.
