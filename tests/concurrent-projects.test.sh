#!/usr/bin/env bash
# Feature-owned fail-first coverage; no network or background fixtures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# tests/lib/concurrent_projects.py
python3 "$ROOT/tests/lib/concurrent_projects.py" "$ROOT"
