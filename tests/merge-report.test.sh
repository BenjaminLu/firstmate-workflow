#!/usr/bin/env bash
# T-278: the read-only merge report estimates branch updates and CI runs per
# merged self pull request from a mocked GitHub. No network, no writes.
# Python fixture dependency: tests/lib/merge_report.py
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$_fm_k" || true; done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
isolate_tmpdir
python3 "$ROOT/tests/lib/merge_report.py" "$ROOT"
assert_eq 0 "$?" 'T-278 merge report fields, pagination, nulls and refusals'
finish
