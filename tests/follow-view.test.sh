#!/usr/bin/env bash
# T-271: a round's window shows what the crew member is doing, readably,
# and `fm.sh follow --all` shows every live round. Driven only through
# bin/fm.sh follow and bin/fm-herdr.py follow; the cases live in
# tests/lib/follow_view.py with the recorded logs in tests/fixtures/follow-view/.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tests/lib/follow_view.py" "$ROOT"
