#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Dependencies: bin/lib/fm_git_transfer.py bin/lib/fm-ssh-transfer.sh bin/fm-config.sh
# Production migration dependencies: bin/fm-autopilot.sh bin/fm-herdr.py bin/lib/fm_autopilot.py
# Literal helper dependency lets gate 4 select this suite.
python3 "$ROOT/tests/lib/ssh_transfer_lazy.py" "$ROOT"
