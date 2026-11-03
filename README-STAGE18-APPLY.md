# Stage 18 overlay — apply and run

Target: Intel macOS Sequoia 15.8.1 (24H32), x86_64.

Stage 17 passed its real read-only collection and source gates: 743/743 executable method bodies, 19/19 ownership fences, zero missing methods. Its final activation gate remains blocked pending manual ownership review.

## Apply and run in one command

1. Download `RTL88WiFi-Stage18-ownership-contract-review-overlay.zip` to `~/Downloads`.
2. Paste the following command into Terminal:

```zsh
PROJECT="$HOME/Downloads/RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
OVERLAY="$HOME/Downloads/RTL88WiFi-Stage18-ownership-contract-review-overlay.zip"

set -e
[[ -d "$PROJECT" ]] || { echo "Project folder missing"; exit 2; }
[[ -f "$OVERLAY" ]] || { echo "Stage 18 overlay missing"; exit 2; }

EXPECTED="See the companion SHA256SUMS.txt for the overlay checksum"
ACTUAL=$(shasum -a 256 "$OVERLAY" | awk '{print $1}')
echo "Stage 18 overlay SHA-256: $ACTUAL"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "Overlay checksum mismatch"; exit 3; }

/usr/bin/unzip -tq "$OVERLAY"
/bin/bash "$PROJECT/tools/apply-overlay-and-run.sh" \
  "$OVERLAY" tools/run-stage18.sh
```

The existing `apply-overlay-and-run.sh` extracts the ZIP into the project, then launches Stage 18. The runner finds the newest Stage 17 archive and requires the Stage 14/15/16 prerequisites. It executes the regression test and builds a read-only dossier. When the configured `runlog` helper is available, it uploads `output.log` and the Stage 18 `.tar.gz` archive to `shammu2bd/Realtek-WIFI-Native-macOS`.

## Expected outcome

`Stage 18 status: READY_FOR_MANUAL_REVIEW` is expected. It is not a datapath approval. The report contains six contract dossiers with exact Stage 17 assembly bodies and current source excerpts. Every contract remains `MANUAL_REVIEW_REQUIRED`; queue registration, packet submission/completion, radio start, and interface publication stay blocked.

If the runner fails, do not enable TX/RX. Share the newly uploaded `output.log` for diagnosis.
