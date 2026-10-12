#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_self_pr.py bin/fm-worker.sh tests/lib/self_pr_authoring.py tests/lib/worker.sh tests/lib/herdr.py tests/lib/fixture_plan.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tests/lib/self_pr_authoring.py" "$ROOT"
