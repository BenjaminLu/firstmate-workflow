#!/usr/bin/env bash
# T-143: policy, dependency selection, per-PR bases and safe retention.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT/bin/lib"
python3 "$ROOT/tests/lib/stacking_cases.py"
