#!/usr/bin/env bash
# Private project inspection, confirmation, chat edit and drift proposal.
set -euo pipefail
exec < /dev/null
exec python3 "$(dirname "${BASH_SOURCE[0]}")/lib/fm_onboard.py" "$@"
