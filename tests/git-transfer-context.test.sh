#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Literal dependencies: bin/lib/fm_git_transfer.py bin/lib/fm-ssh-transfer.sh
# bin/fm-config.sh bin/lib/fm_binding.py bin/lib/fm_autopilot.py
# bin/lib/fm_autopilot_loop.py bin/lib/fm_stack.py bin/lib/fm_onboard.py
# tests/lib/ssh_transfer_lazy.py tests/lib/git_transfer_context.py
python3 "$ROOT/tests/lib/git_transfer_context.py" "$ROOT"
