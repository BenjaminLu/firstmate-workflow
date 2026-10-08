#!/usr/bin/env bash
# Feature dependencies: bin/fm-worker.sh bin/lib/fm_conventions.py bin/lib/fm_public_text.py
# Shared fixtures: tests/lib/external_branch_prefix.py tests/lib/external_rebuild.py tests/lib/external_registry.py
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/external_branch_prefix.py" "$ROOT"
assert_eq 0 "$?" 'external branch prefix, CI triggers and refusal before publication'
finish
