#!/usr/bin/env bash
# T-299 capture dependencies: bin/lib/fm_design.py bin/lib/fm-design-capture.mjs
# bin/lib/fm_capture_server.py tests/e2e/capture-server.sh tests/e2e/lib/capture-server.ts
# tests/e2e/lib/fixture.ts tests/lib/capture_pages.py
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/lib/capture_pages.py" "$ROOT"
