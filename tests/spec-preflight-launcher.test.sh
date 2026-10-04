#!/usr/bin/env bash
# Feature dependencies: bin/fm-review.sh bin/fm-herdr.py bin/lib/fm-spec-preflight.sh
# bin/lib/fm_spec_preflight.py bin/lib/fm_sandbox_policy.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
for vendor in claude codex; do
d="$(fixture)"; repo="$d/repo"
printf 'reviewer:\n  vendor: %s\n' "$vendor" > "$repo/config.yaml"
# The vendor stub uses the actual managed adapter entry and a vendor-shaped
# completed JSON result. OS confinement is tested separately by policy cases.
cat > "$repo/bin/fm-auth-probe.sh" <<'S'
#!/usr/bin/env bash
printf 'status: authenticated\n'
S
cat > "$repo/bin/adapters/$vendor.sh" <<'S'
#!/usr/bin/env bash
# fm:review-run
set -uo pipefail
. "$(dirname "$0")/_lib.sh"
prompt="$2"; tree="$3"; log="$4"
fm_adapter_context "$0"
python3 - "$prompt" "$log" <<'PY'
import json, os, pathlib, subprocess, sys
policy = json.loads(pathlib.Path(os.environ['FM_POLICY']).read_text())
assert policy['role'] == 'reviewer' and policy['review_root_readonly'] is True
checkout = os.environ['FM_REVIEW_CHECKOUT']
assert subprocess.check_output(['git', '-C', checkout, 'rev-parse', 'HEAD'], text=True).strip() == os.environ['FM_REVIEW_BASE']
assert not subprocess.check_output(['git', '-C', checkout, 'remote'], text=True).strip()
body = pathlib.Path(sys.argv[1]).read_text()
for phrase in ('declared scope', 'caller, mirror, fixture', 'ids, formats, paths', 'already in flight'):
    assert phrase in body
assert 'REVIEWER_COMPLETE' not in body
result = {'type': 'result', 'subtype': 'success', 'is_error': False,
          'result': '1. Checked the acceptance and migration.\n' + os.environ.get('FM_TEST_VERDICT', 'SPEC-OK') + ':' + os.environ['FM_TASK']}
if os.environ['FM_CHAIN_VENDOR'] == 'codex':
    rows = [{'type': 'thread.started', 'thread_id': 'fixture'}, {'type': 'turn.started'},
            {'type': 'item.completed', 'item': {'type': 'agent_message', 'id': 'final', 'text': result['result']}},
            {'type': 'turn.completed', 'usage': {'input_tokens': 1, 'output_tokens': 1}}]
else:
    rows = [result]
pathlib.Path(sys.argv[2]).write_text('\n'.join(json.dumps(row) for row in rows) + '\n')
PY
S
chmod +x "$repo/bin/fm-auth-probe.sh" "$repo/bin/adapters/$vendor.sh"
(cd "$repo" && FM_ROOT="$repo" bin/fm-review.sh --spec-preflight --task T-Z --spec design/tasks/T-Z.json) > "$d/out" 2>&1
assert_eq 0 "$?" 'preflight launcher accepts vendor-shaped final on current base'
assert_contains "$(cat "$d/out")" 'SPEC-OK:T-Z' 'final result is shown to firstmate'
record="$(find "$repo/state/evidence" -name '*.json' -type f | head -1)"
assert_eq spec-preflight "$(find "$repo/state/runs" -name identity.json -exec jq -r .mode {} \;)" 'launcher records preflight identity mode'
assert_eq spec-preflight "$(jq -r .kind "$record")" 'preflight persists local evidence'
sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$repo/design/tasks/T-Z.json")"
assert_eq "$sha" "$(jq -r .spec_sha256 "$record")" 'receipt binds exact proposed bytes'
review_run="$(FM_ROOT="$repo" python3 "$repo/bin/fm-herdr.py" allocate "$repo" reviewer T-Z '')"
assert_eq 1 "$(jq -r .attempt "$review_run/identity.json")" 'first review after recorded preflight retains attempt 1'
assert_eq 1 "$(jq -r .round "$review_run/identity.json")" 'first review after recorded preflight retains round 1'
level=legacy; [ "$vendor" != codex ] || level=authenticated
assert_eq "$level" "$(jq -r .provenance.level "$record")" "$vendor retains its provenance level"
(cd "$repo" && FM_ROOT="$repo" FM_TEST_VERDICT=SPEC-GAPS bin/fm-review.sh --spec-preflight --task T-Z --spec design/tasks/T-Z.json) > "$d/gaps" 2>&1
assert_eq 65 "$?" 'gaps retain evidence and refuse approval'
assert_contains "$(cat "$d/gaps")" 'SPEC-GAPS:T-Z' 'firstmate receives gaps'
assert_eq 2 "$(find "$repo/state/evidence" -name '*.json' -type f | wc -l | tr -d ' ')" 'both results retained append-only'
(cd "$repo" && FM_ROOT="$repo" bin/fm-review.sh --spec-preflight --task T-Z --spec design/tasks/T-Z.json) > "$d/waiver" 2>&1
assert_eq 65 "$?" 'same bytes cannot waive a prior gap'
assert_contains "$(cat "$d/waiver")" 'amended spec bytes' 'waiver refusal names amendment requirement'
rm -rf "$d"
done
finish
