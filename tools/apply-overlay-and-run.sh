#!/bin/bash
# Generic convenience helper for subsequent stage overlays.
# Usage: tools/apply-overlay-and-run.sh /path/to/overlay.zip [runner-script]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OVERLAY="${1:-}"
RUNNER="${2:-}"
if [[ -z "$OVERLAY" || ! -f "$OVERLAY" ]]; then
  echo "Usage: $0 /path/to/overlay.zip [runner-script]" >&2
  exit 2
fi
command -v ditto >/dev/null 2>&1 || { echo "ERROR: ditto is required on macOS" >&2; exit 2; }
# Extract directly into the project root; this overwrites only files present
# in the overlay and leaves all other project files intact.
ditto -x -k "$OVERLAY" "$PROJECT_ROOT"
echo "Overlay applied: $OVERLAY"
if [[ -n "$RUNNER" ]]; then
  case "$RUNNER" in
    /*) exec "$RUNNER" ;;
    *) exec "$PROJECT_ROOT/$RUNNER" ;;
  esac
fi
