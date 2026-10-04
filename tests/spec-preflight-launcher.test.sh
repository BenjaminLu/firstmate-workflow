#!/usr/bin/env bash
# Feature dependencies: bin/fm-review.sh bin/fm-herdr.py bin/lib/fm-spec-preflight.sh
# bin/lib/fm_spec_preflight.py bin/lib/fm_sandbox_policy.py
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/review.sh
. "$ROOT/tests/lib/review.sh"
for vendor in claude codex; do
d="$(fixture)"; repo="$d/repo"
printf 'models:\n  claude: fixture-claude\n  codex: fixture-codex\nreviewer:\n  vendor: %s\n' "$vendor" > "$repo/config.yaml"
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
# Observe the real launcher's start and attempt events while the round is live.
sys.path.insert(0, str(pathlib.Path(os.environ['FM_CODE_ROOT']) / 'bin/lib'))
from fm_watch import inflight
rows = [json.loads(line) for line in (pathlib.Path(os.environ['FM_STATE_DIR']) / 'events.jsonl').read_text().splitlines()]
assert os.environ['FM_ACTOR'] in inflight(os.environ['FM_ROOT'])[0]
own = [r for r in rows if r.get('actor') == os.environ['FM_ACTOR']]
vendors = ['claude','claude','codex'] if os.environ.get('FM_TEST_FALLBACK') else [os.environ['FM_CHAIN_VENDOR']] * 2
assert len(own) == len(vendors) and all(r['type'] == 'crew_status' for r in own), own
for row, vendor in zip(own, vendors):
    assert row['data']['crew_name'] == os.environ['FM_ACTOR']
    assert row['data']['identity']['name']
    assert row['data']['identity']['vendor_resolution']['vendor'] == vendors[0]
    assert row['data']['mode'] == 'spec-preflight'
    assert row['data']['phase'] == 'review'
    assert row['data']['identity']['vendor'] == vendor
    assert row['data']['identity']['model_requested'] == 'fixture-' + vendor
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
assert_eq 'spec-ok ok' "$(jq -sr '[.[]|select(.type=="agent_finished")][-1].data|"\(.preflight_outcome) \(.result)"' "$repo/state/events.jsonl")" 'preflight success closes with retained verdict outcome'
assert_eq '[]' "$(FM_ROOT="$repo" PYTHONPATH="$repo/bin/lib" python3 -c 'import json,os; from fm_watch import inflight; print(json.dumps(inflight(os.environ["FM_ROOT"])[0]))')" 'normal preflight finish clears the watch inflight list'
assert_eq 0 "$(jq -s '[.[]|select(.type=="review_opened")]|length' "$repo/state/events.jsonl")" 'preflight never opens a review round'
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
assert_eq 'spec-gaps ok' "$(jq -sr '[.[]|select(.type=="agent_finished")][-1].data|"\(.preflight_outcome) \(.result)"' "$repo/state/events.jsonl")" 'exit 65 with retained gaps is a completed preflight'
assert_contains "$(cat "$d/gaps")" 'SPEC-GAPS:T-Z' 'firstmate receives gaps'
assert_eq 2 "$(find "$repo/state/evidence" -name '*.json' -type f | wc -l | tr -d ' ')" 'both results retained append-only'
(cd "$repo" && FM_ROOT="$repo" bin/fm-review.sh --spec-preflight --task T-Z --spec design/tasks/T-Z.json) > "$d/waiver" 2>&1
assert_eq 65 "$?" 'same bytes cannot waive a prior gap'
assert_contains "$(cat "$d/waiver")" 'amended spec bytes' 'waiver refusal names amendment requirement'
assert_eq 'failed failed' "$(jq -sr '[.[]|select(.type=="agent_finished")][-1].data|"\(.preflight_outcome) \(.result)"' "$repo/state/events.jsonl")" 'no receipt for this actor cannot reuse an earlier verdict'
# Invalid JSON refuses after identity allocation and must still close the actor.
printf '{' > "$d/invalid.json"
(cd "$repo" && FM_ROOT="$repo" bin/fm-review.sh --spec-preflight --task T-Z --spec "$d/invalid.json") > "$d/refused" 2>&1
assert_eq 65 "$?" 'invalid spec refuses before the vendor runs'
assert_eq 'refused failed' "$(jq -sr '[.[]|select(.type=="agent_finished")][-1].data|"\(.preflight_outcome) \(.result)"' "$repo/state/events.jsonl")" 'early refusal closes the allocated actor'
if [ "$vendor" = claude ]; then
  # Exercise the real chain's prepare callback, not a simulated fallback event.
  cp "$repo/bin/adapters/claude.sh" "$repo/bin/adapters/codex.sh"
  printf '#!/usr/bin/env bash\n# fm:review-run\nexit 2\n' > "$repo/bin/adapters/claude.sh"
  printf 'models:\n  claude: fixture-claude\n  codex: fixture-codex\nreviewer:\n  vendor: claude\nfallback:\n  - codex\n' > "$repo/config.yaml"
  # Amend bytes because an earlier SPEC-GAPS correctly forbids their reuse.
  printf '\n' >> "$repo/design/tasks/T-Z.json"
  (cd "$repo" && FM_ROOT="$repo" FM_TEST_FALLBACK=1 bin/fm-review.sh --spec-preflight --task T-Z --spec design/tasks/T-Z.json) > "$d/fallback" 2>&1
  assert_eq 0 "$?" 'fallback attempt emits its own vendor and requested model'
else
  # Select the registered self project while another project is the default.
  cat >> "$repo/config.yaml" <<J
projects:
  other:
    github: org/other
    base: main
    required_check: ci
  selected:
    repo: .
    github: org/selected
    base: main
    required_check: ci
default_project: other
J
  project_fixture_config "$repo"
  printf '\n' >> "$repo/design/tasks/T-Z.json"
  (cd "$repo" && FM_ROOT="$repo" FM_PROJECT=selected bin/fm-review.sh --spec-preflight --task T-Z --spec design/tasks/T-Z.json) > "$d/project" 2>&1
  assert_eq 0 "$?" 'preflight accepts explicit project on multi-project config'
  assert_eq selected "$(jq -sr '.[-1].project' "$repo/state/events.jsonl")" 'preflight closing event names its selected project'
  assert_eq selected "$(jq -sr '[.[]|select(.type=="crew_status")][-1].project' "$repo/state/events.jsonl")" 'preflight start event names its selected project'
fi
rm -rf "$d"
done
finish
