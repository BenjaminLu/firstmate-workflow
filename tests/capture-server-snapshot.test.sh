#!/usr/bin/env bash
# T-310 dependencies: bin/lib/fm_capture_server.py bin/lib/fm_lifeline.py
# tests/e2e/capture-server.sh tests/e2e/lib/capture-server.ts
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -d "$ROOT/node_modules/@playwright/test" ]; then
  echo "FAIL capture: $ROOT/node_modules has no Playwright; run bun install --frozen-lockfile" >&2
  exit 1
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-test.XXXXXX")" || { echo "FAIL capture: mktemp failed" >&2; exit 70; }
trap 'rm -rf "$TMP"' EXIT
# A code snapshot, like state/snapshots/code-*: bin only, no node_modules.
mkdir -p "$TMP/code/bin" "$TMP/head"
cp -R "$ROOT/bin/lib" "$TMP/code/bin/lib"
git -C "$ROOT" archive HEAD | tar -x -C "$TMP/head"
[ ! -e "$TMP/code/node_modules" ] && [ ! -e "$TMP/head/node_modules" ]

name='capture: a code snapshot without node_modules still starts the capture server'
if FM_ROOT="$ROOT" PYTHONDONTWRITEBYTECODE=1 python3 - "$TMP/code/bin/lib" "$TMP/head" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fm_capture_server import capture_server
with capture_server(sys.argv[2]) as record:
    assert record and isinstance(record.get('pages'), dict) and record['pages'], record
PY
then
  [ ! -e "$TMP/head/node_modules" ] || { echo "FAIL $name: head got node_modules" >&2; exit 1; }
  echo "ok $name"
else
  echo "FAIL $name" >&2
  exit 1
fi
