#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# tests/lib/run_project_turns.py
python3 "$ROOT/tests/lib/run_project_turns.py" "$ROOT"
