#!/usr/bin/env bash
# External wakes reach the engine queue and only its firstmate doorbells.
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
t="$(safe_tmpdir)"; eng="$t/engine"; export FM_HOME="$t/home"
mkdir -p "$eng/state/session/wake.d" "$eng/state/session/autopilot.d"
cat > "$eng/config.yaml" <<'YAML'
default_project: self
projects:
  self:
    repo: .
    github: owner/engine
    base: main
    required_check: ci
  private-app:
    github: owner/private-app
    base: trunk
    required_check: ci
YAML
queue="$eng/state/session/wake.jsonl"
store="$FM_HOME/projects/private-app/state/session/wake.jsonl"
mkfifo "$eng/state/session/wake.d/1-a.fifo" "$eng/state/session/autopilot.d/1-a.fifo"
exec 7<> "$eng/state/session/wake.d/1-a.fifo"
exec 8<> "$eng/state/session/autopilot.d/1-a.fifo"
python3 - "$ROOT" "$eng" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_watch as watch
assert watch.take(sys.argv[2]) == []
PY
assert_eq 0 "$?" "watch cursor starts before the external push"
FM_PROJECT=private-app python3 "$ROOT/bin/lib/fm_lifeline.py" push "$eng" worker-x round_end 'finished: T-001 worker-x ok #1' '{"task":"T-001","actor":"worker-x","head":"abc"}' > "$t/count"
assert_eq 0 "$?" "external push succeeds"
assert_eq 0 "$(cat "$t/count")" "push returns the private store ring count"
assert_eq T-001 "$(jq -r .task "$store")" "private wake retains its task"
assert_eq true "$(jq -sc 'length == 1 and (.[0] | keys == ["id","line","origin_project","origin_reason","reason","woken"] and .id == "private-app_worker-x" and .reason == "forwarded" and .origin_project == "private-app" and .origin_reason == "round_end" and .line == "finished: private-app T-001 worker-x ok #1" and (.woken | type == "number"))' "$queue")" "engine receives exactly one minimal projected wake"
received=''
IFS= read -r -t 2 received <&7
assert_eq 'finished: private-app T-001 worker-x ok #1' "$received" "engine firstmate doorbell receives the projected line"
assert_fail 'IFS= read -r -t 1 received <&8' "external forwarding does not ring engine autopilot"
python3 - "$ROOT" "$eng" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_watch as watch
items = watch.take(sys.argv[2])
assert len(items) == 1, items
assert items[0]['id'] == 'private-app_worker-x', items
assert watch.wake_line(items[0]) == 'finished: private-app T-001 worker-x ok #1'
assert watch.take(sys.argv[2]) == [], 'forwarded wake must be delivered once'
PY
assert_eq 0 "$?" "engine watch takes the forwarded wake exactly once"
python3 "$ROOT/bin/lib/fm_lifeline.py" push "$eng" worker-s round_end 'finished: T-002 worker-s ok' >/dev/null
assert_eq true "$(jq -sc 'length == 2 and ([.[] | select(.id == "worker-s" and .reason == "round_end")] | length == 1) and ([.[] | select(.reason == "forwarded")] | length == 1)' "$queue")" "self push adds exactly one ordinary wake"
long_line="$(python3 -c 'print("review:\t" + "x" * 400 + "\n tail")')"
FM_PROJECT=private-app python3 "$ROOT/bin/lib/fm_lifeline.py" push "$eng" long verdict "$long_line" >/dev/null
assert_eq true "$(jq -sc '[.[] | select(.id == "private-app_long")] | length == 1 and (.[0].line | length == 300 and startswith("review: private-app ") and (contains("\n") | not) and (contains("\t") | not))' "$queue")" "forwarded line collapses whitespace and is bounded"
before="$(cat "$queue")"
assert_fail 'python3 "$ROOT/bin/lib/fm_lifeline.py" forward "$eng" Bad_Name x round_end l' "forward refuses an invalid project"
assert_fail 'python3 "$ROOT/bin/lib/fm_lifeline.py" forward "$eng" private-app bad.id round_end l' "forward refuses an invalid wake id"
assert_eq "$before" "$(cat "$queue")" "invalid forwarding appends nothing"
# A forwarding failure cannot undo the original private write or ring result.
python3 - "$ROOT" "$eng" <<'PY'
import contextlib
import io
import os
import sys
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_lifeline as life
error = io.StringIO()
with patch.dict(os.environ, FM_PROJECT='private-app'), patch.object(life, 'forward', side_effect=OSError('unavailable')), contextlib.redirect_stderr(error):
    assert life.push(sys.argv[2], 'retained', 'round_end', 'finished: retained') == 0
assert 'fm: the wake for retained was not forwarded to firstmate: unavailable' in error.getvalue()
PY
assert_eq 0 "$?" "forwarding failure is reported without failing push"
assert_eq 1 "$(jq -sc '[.[] | select(.id == "retained")] | length' "$store")" "failed forwarding retains the private item"
exec 7>&- 8>&-
safe_rm_rf "$t"
finish
