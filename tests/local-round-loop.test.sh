#!/usr/bin/env bash
# Exercise the private loop through real launchers. No comment may be written.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
# shellcheck source=tests/lib/binding-fixture.sh
. "$ROOT/tests/lib/binding-fixture.sh"
d="$(fixture)"; repo="$d/repo"
binding_service_fixture "$repo"
cp "$ROOT/bin/fm-review.sh" "$ROOT/bin/fm-gate.sh" "$ROOT/bin/fm-protocol.sh" "$repo/bin/"
mkdir -p "$repo/skills/reviewer"
cp "$ROOT/skills/reviewer/SKILL.md" "$repo/skills/reviewer/"
cat >> "$repo/config.yaml" <<'CONFIG'
default_project: firstmate-workflow
projects:
  firstmate-workflow:
    repo: .
    github: fixture/repository
    base: main
    required_check: ci
    design: design/design.md
    tasks: design/tasks
    projection: local
CONFIG
cat > "$repo/bin/adapters/mock.sh" <<'ADAPTER'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
if [ "$FM_ROLE" = worker ]; then
  [ -z "${FM_CAPTURE:-}" ] || cp "$2" "$FM_CAPTURE"
  mkdir -p "$3/src"
  printf 'implemented\n' > "$3/src/feature"
  printf 'PRIVATE_WORKER_REASONING\n' > "$3/.fm-say.md"
else
  cp "$2" "$FM_CAPTURE"
  if [ "$FM_TEST_VERDICT" = reject ]; then
    printf '1. open fix src/feature:1\nCRITERIA-COMPLETE:T-Z\nREJECT:T-Z\n' > "$3/verdict.txt"
  else
    printf '1. done fix src/feature:1\nCRITERIA-COMPLETE:T-Z\nAPPROVE:T-Z\n' > "$3/verdict.txt"
  fi
fi
ADAPTER
chmod +x "$repo/bin/adapters/mock.sh"
export GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z
git -C "$repo" add .
git -C "$repo" commit -qm 'local loop fixture'
git -C "$repo" push -q origin main
seed_spec_preflight "$repo" T-Z "" firstmate-workflow
seed_self_pr_authoring "$repo" T-Z firstmate-workflow
mkdir -p "$d/stub"
cat > "$d/stub/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CALLS"
case "$1 $2" in
  'pr comment') echo 'comment writes forbidden' >&2; exit 1 ;;
  'pr list') echo null ;;
  'pr create') echo https://example.invalid/pull/42 ;;
  'pr checks') echo '[{"name":"ci","state":"SUCCESS","bucket":"pass"}]' ;;
  'pr view') printf '{"headRefOid":"%s","baseRefName":"main","mergeStateStatus":"CLEAN","comments":[{"author":{"login":"stale"},"body":"REJECT:T-Z"}]}\n' "$(git rev-parse "${FM_TEST_BRANCH:-HEAD}")" ;;
  'api '*)
    case "$2" in
      *protection*) echo '{"contexts":["ci"]}' ;;
      *check-runs*) echo '{"check_runs":[]}' ;;
      */status*) printf '{"sha":"%s","statuses":[]}\n' "$(git rev-parse "${FM_TEST_BRANCH:-HEAD}")" ;;
      *) echo '{}' ;;
    esac ;;
esac
GH
chmod +x "$d/stub/gh"
export FM_TEST_CALLS="$d/calls" FM_GH="$d/stub/gh" FM_ROOT="$repo" FM_REVIEW_CI_WAIT=0
export FM_GATE_LOCK="$d/gate.lock"
(cd "$repo" && bin/fm-worker.sh --task T-Z) > "$d/worker.out" 2>&1
assert_eq 0 "$?" 'local worker completes with a comment-refusing gh'
branch="$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' | head -1)"
head="$(git -C "$repo" rev-parse "$branch")"
export FM_TEST_BRANCH="$branch"
records="$repo/state/evidence/firstmate-workflow/T-Z"
assert_eq 1 "$(jq -s '[.[]|select(.kind=="worker-report")]|length' "$records/"*.json)" 'worker report retained locally'
assert_eq true "$(jq -s 'any(.[]; .data.evidence_event == "brief_coverage" and .summary.en != null and .summary["zh-TW"] != null)' "$repo/state/events.jsonl")" 'coverage reaches the real event writer with both summaries'
assert_eq true "$(jq -s 'any(.[]; .data.evidence_event == "brief_round_finished" and .data.duration >= 0 and .data.turns_source == "unavailable")' "$repo/state/events.jsonl")" 'round cost records unknown mock turns honestly'

printf '1. fix src/feature:1\n' > "$d/brief.md"
(cd "$repo" && bash bin/lib/fm-evidence.sh brief --task T-Z --round 2 --head "$head" --file "$d/brief.md")
assert_eq 0 "$?" 'operator records an approved brief without a PR comment'
(cd "$repo" && bin/fm-gate.sh --task T-Z --repo "$repo" --branch "$branch" --only 6 --pr 42) > "$d/gate.out" 2>&1
assert_eq 6 "$?" 'gate 6 refuses a missing local verdict'
assert_contains "$(cat "$d/gate.out")" 'missing local verdict' 'gate 6 names the missing evidence'
export FM_CAPTURE="$d/review-prompt.md" FM_TEST_VERDICT=reject
(cd "$repo" && bin/fm-review.sh --task T-Z --branch "$branch" --round 1 --pr 42) > "$d/review.out" 2>&1
assert_eq 0 "$?" 'round-one legacy rejection is retained'
assert_eq firstmate-workflow "$(jq -r 'select(.type=="review_opened")|.project' "$repo/state/events.jsonl" | tail -1)" 'review event explicitly carries the resolved project for round counting'
(cd "$repo" && bin/fm-protocol.sh check --task T-Z --round 1) > "$d/protocol.out" 2>&1
assert_eq 0 "$?" 'round-one complete criteria satisfy the local protocol'
export FM_CAPTURE="$d/worker-prompt.md"
(cd "$repo" && bin/fm-worker.sh --task T-Z --pr 42) > "$d/worker-two.out" 2>&1
assert_eq 0 "$?" 'round-two worker reads its local brief without comment transport'
assert_contains "$(cat "$d/worker-prompt.md")" '1. fix src/feature:1' 'approved exact-head brief reaches the worker'
assert_contains "$(cat "$d/worker-prompt.md")" '1. open fix src/feature:1' 'worker receives the local standing list'
export FM_CAPTURE="$d/review-prompt.md"
export FM_TEST_VERDICT=approve
(cd "$repo" && bin/fm-review.sh --task T-Z --branch "$branch" --round 2 --pr 42) > "$d/review.out" 2>&1
assert_eq 0 "$?" 'round-two local review completes'
assert_contains "$(cat "$d/review-prompt.md")" '1. open fix src/feature:1' 'round two receives the local standing list'
assert_lacks "$(cat "$d/review-prompt.md")" PRIVATE_WORKER_REASONING 'reviewer receives no worker reasoning'
(cd "$repo" && bin/fm-gate.sh --task T-Z --repo "$repo" --branch "$branch" --only 6 --pr 42) > "$d/gate.out" 2>&1
assert_eq 0 "$?" 'gate 6 accepts the latest local approval despite stale contradictory comments'
assert_contains "$(cat "$d/gate.out")" provenance=legacy 'gate 6 states the provenance level'
export FM_TEST_VERDICT=reject
(cd "$repo" && bin/fm-review.sh --task T-Z --branch "$branch" --round 3 --pr 42) > "$d/review.out" 2>&1
(cd "$repo" && bin/fm-gate.sh --task T-Z --repo "$repo" --branch "$branch" --only 6 --pr 42) > "$d/gate.out" 2>&1
assert_eq 6 "$?" 'a later local rejection supersedes the local approval'
assert_fail "grep -q '^pr comment' '$d/calls'" 'local projection attempts no comment writes'
rm -rf "$d"
finish
