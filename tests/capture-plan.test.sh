#!/usr/bin/env bash
# T-299 dependencies: bin/lib/fm_design.py bin/lib/fm_capture_server.py
# tests/lib/capture_plan.py
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/lib/capture_plan.py" "$ROOT"
