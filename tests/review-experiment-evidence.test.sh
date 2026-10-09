#!/usr/bin/env bash
# Feature dependencies: bin/lib/fm_experimental_evidence.py bin/lib/fm_evidence.py
# bin/lib/fm-evidence.sh bin/fm-review.sh bin/lib/fm_review_context.py
# bin/adapters/codex.sh tests/lib/review_experiment_evidence.py
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tests/lib/review_experiment_evidence.py" "$ROOT"
