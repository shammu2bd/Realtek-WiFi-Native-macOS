#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 -m py_compile tests/test-wcl-stage97-independent-audit.py
python3 tests/test-wcl-stage97-independent-audit.py
