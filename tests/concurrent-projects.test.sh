#!/usr/bin/env bash
# Feature-owned fail-first coverage; fixture processes are lifeline-owned.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# tests/lib/concurrent_projects.py
python3 "$ROOT/tests/lib/concurrent_projects.py" "$ROOT"
