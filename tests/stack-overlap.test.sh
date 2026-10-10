#!/usr/bin/env bash
# T-278: approved-scope overlap rule, the approved-scope reader and the
# dispatch holds or stacks it decides. No network; dispatch runs dry.
# Python fixture dependency: tests/lib/stack_overlap.py
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do unset "$_fm_k" || true; done
export HERDR_ENV=0 FM_TRANSPORT=direct
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
isolate_tmpdir
python3 "$ROOT/tests/lib/stack_overlap.py" "$ROOT"
assert_eq 0 "$?" 'T-278 overlap, approved-scope reader and dispatch cases'
finish
