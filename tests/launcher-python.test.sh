#!/usr/bin/env bash
# T-177: extraction guard and byte-for-byte sandbox profile compatibility.
set -euo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Helpers: tests/lib/launcher_python.py, tests/lib/python_programs.py, tests/lib/t177_sandbox_base.py, tests/lib/t177_launcher_base.py
python3 -B "$ROOT/tests/lib/launcher_python.py" "$ROOT"
