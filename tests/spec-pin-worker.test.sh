#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/worker.sh"
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
printf 'state/\n' > "$repo/.gitignore"
git -C "$repo" add config.yaml .gitignore; git -C "$repo" commit -qm contract
git -C "$repo" push -q origin main
printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
printf '%s' "${FM_PINNED_DIR:-}" > "$FM_SEEN/pinned-path"
mkdir -p "$3/src"
printf 'implemented\n' > "$3/src/feature"
M
chmod +x "$repo/bin/adapters/mock.sh"
seed_spec_preflight "$repo" T-Z "" firstmate-workflow
seed_self_pr_authoring "$repo" T-Z firstmate-workflow
(cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z --project firstmate-workflow) > "$d/out" 2>&1
assert_eq 0 "$?" 'authorized worker pins before running its adapter'
assert_ok "test -f '$repo/state/pins/T-Z/1.json'" 'worker stores its first pin outside the worktree'
assert_contains "$(cat "$d/prompt.md")" '# Approved spec pin' 'worker prompt uses the shared pin resolver'
assert_contains "$(cat "$d/prompt.md")" '"approval_binding": "dispatch-time"' 'worker exposes the dispatch-time approval limit'
assert_eq committed "$(jq -r '.snapshots.spec.source' "$repo/state/pins/T-Z/1.json")" 'worker records committed self spec provenance'
assert_eq 1 "$(jq -s '[.[]|select(.type=="spec_pinned")]|length' "$repo/state/events.jsonl")" 'worker emits one initial pin event'
assert_contains "$(cat "$d/prompt.md")" '# Complete round inputs in pinned/' 'stock worker prompt indexes complete approved design'
assert_lacks "$(cat "$d/prompt.md")" '# Launcher project context' 'self worker retains its existing prompt sections'
python3 - "$d/pinned-path" "$repo/state/pins/T-Z/1.json" <<'PY_PINNED'
import json
from pathlib import Path
import sys
folder = Path(Path(sys.argv[1]).read_text())
pin = json.loads(Path(sys.argv[2]).read_text())
assert folder.name == 'pinned' and folder.is_absolute()
assert folder.stat().st_mode & 0o777 == 0o755
for key, name in [('spec', 'spec.json'), ('design', 'design.md'), ('contract', 'contract.yaml')]:
    path = folder / name
    assert path.read_bytes() == pin['snapshots'][key]['text'].encode()
    assert path.is_file() and not path.is_symlink()
    assert path.stat().st_mode & 0o7777 == 0o444
PY_PINNED
assert_eq 0 "$?" 'worker adapter receives exact read-only pin files'
# A valid mutable branch spec must never rescue an existing corrupt pin.
for corruption in hash unreadable; do
  rm -f "$d/prompt.md"
  if [ "$corruption" = hash ]; then
    jq '.snapshots.design.text += "tampered"' "$repo/state/pins/T-Z/1.json" > "$d/corrupt.json"
    cp "$d/corrupt.json" "$repo/state/pins/T-Z/1.json"
  else
    printf '{broken' > "$repo/state/pins/T-Z/1.json"
  fi
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  assert_eq 65 "$?" 'worker refuses corrupt existing pin without branch fallback'
  assert_ok "test ! -e '$d/prompt.md'" 'worker never invokes adapter with corrupt pin'
  if [ "$corruption" = hash ]; then
    assert_contains "$(cat "$d/out")" 'hash mismatch' 'worker names corrupt snapshot reason'
  fi
done
rm -rf "$d"
# A resumed PR's first pin must receive the actual round worktree, not main.
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
printf 'state/\n' > "$repo/.gitignore"
git -C "$repo" add config.yaml .gitignore; git -C "$repo" commit -qm contract
git -C "$repo" push -q origin main
git -C "$repo" checkout -qb t-z-resume
jq '.scope += ["wider/**", "design/tasks/T-Z.json"]' "$repo/design/tasks/T-Z.json" > "$d/spec.json"
cp "$d/spec.json" "$repo/design/tasks/T-Z.json"
mkdir -p "$repo/src"
printf 'earlier implementation\n' > "$repo/src/prior"
git -C "$repo" add design/tasks/T-Z.json src/prior
git -C "$repo" commit -qm 'approved scope and earlier implementation'
head="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin t-z-resume
git -C "$repo" checkout -q main
mkdir -p "$repo/state/ready" "$repo/state/decisions"
printf '%s\n' '{"task":"T-Z","ended":"D-ready","ended_at":"2026-10-03T00:03:00Z"}' > "$repo/state/ready/T-Z.json"
printf '%s\n' '{"id":"D-ready","task":"T-Z","kind":"choice","chosen":"A"}' > "$repo/state/decisions/D-ready.json"
jq -n --arg head "$head" '{id:"D-scope",task:"T-Z",kind:"choice",chosen:"A",expected_head:$head}' > "$repo/state/decisions/D-scope.json"
printf '%s\n' \
  '{"type":"decision_made","actor":"captain","task":"T-Z","ts":"2026-10-03T00:00:00Z","data":{"decision":"D-ready","chosen":"A"}}' \
  '{"type":"decision_made","actor":"captain","task":"T-Z","ts":"2026-10-03T00:01:00Z","data":{"decision":"D-scope","chosen":"A"}}' > "$repo/state/events.jsonl"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
cp "$FM_PINNED_DIR/spec.json" "$FM_SEEN/adapter-spec.json"
mkdir -p "$3/wider"
printf 'resumed implementation\n' > "$3/wider/feature"
M
chmod +x "$repo/bin/adapters/mock.sh"
# fixture() seeded only main's narrower spec. A refused approved-branch
# snapshot must not fall back to that otherwise valid legacy receipt.
(cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z --pr 42) > "$d/refused.out" 2>&1
assert_eq 65 "$?" 'resumed branch requires its own exact-byte preflight'
assert_eq 0 "$(jq -s '[.[] | select(.type=="dispatched" or .type=="commit_pushed")]|length' "$repo/state/events.jsonl")" 'resumed refusal emits no dispatch or checkpoint'
assert_ok "test ! -e '$repo/state/worktrees/T-Z.pid'" 'resumed refusal publishes no pid'
assert_ok "test ! -d '$repo/state/worktrees/T-Z'" 'resumed refusal creates no worktree'
assert_eq "$head" "$(git -C "$repo" ls-remote --heads origin t-z-resume | awk '{print $1}')" 'resumed refusal leaves remote branch unchanged'
assert_ok "test ! -e '$d/prompt.md'" 'approved-branch refusal never falls back to the main receipt'
assert_ok "test ! -e '$repo/state/pins/T-Z/1.json'" 'approved-branch refusal publishes no pin'
seed_spec_preflight "$repo" T-Z "$d/spec.json"
(cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z --pr 42) > "$d/out" 2>&1
assert_eq 0 "$?" 'resumed PR worker pins after readiness retirement'
assert_eq approved-branch "$(jq -r '.snapshots.spec.source' "$repo/state/pins/T-Z/1.json")" 'resumed launcher passes worktree for approved branch scope'
assert_eq D-ready "$(jq -r '.approval.decision' "$repo/state/pins/T-Z/1.json")" 'resumed pin retains retired dispatch authority'
assert_eq D-scope "$(jq -r '.spec_approval.decision' "$repo/state/pins/T-Z/1.json")" 'resumed pin binds exact scope approval'
assert_ok "cmp '$d/spec.json' '$d/adapter-spec.json'" 'resumed adapter receives the approved branch spec bytes'
assert_contains "$(cat "$d/prompt.md")" 'first-pin-on-resume' 'resumed prompt names first-pin provenance'
rm -rf "$d"

# Authorized legacy sources cannot pin, but exact-byte preflight is still
# required before the adapter can run in either self mode.
for missing in contract design; do
  for mode in default explicit; do
    d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
    if [ "$missing" = design ]; then
      printf 'vendor: mock\nproject:\n  check: true\n' > "$repo/config.yaml"
      git -C "$repo" rm -q design/design.md
      git -C "$repo" add config.yaml
      git -C "$repo" commit -qm 'legacy missing design'
      git -C "$repo" push -q origin main
    else
      printf 'vendor: mock\n' > "$repo/config.yaml"
      git -C "$repo" add config.yaml
      git -C "$repo" commit -qm 'legacy missing contract'
      git -C "$repo" push -q origin main
    fi
    mkdir -p "$repo/state/pins/T-Z"
    touch "$repo/state/pins/T-Z/.lock"
    printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
    cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
cp "$2" "$FM_SEEN/prompt.md"
printf '%s' "${FM_PINNED_DIR:-}" > "$FM_SEEN/pinned-path"
mkdir -p "$3/src"
printf 'implemented\n' > "$3/src/feature"
printf 'Adapter report\n' > "$3/.fm-say.md"
M
    chmod +x "$repo/bin/adapters/mock.sh"
    # The default fixture has no default_project; explicit self selects its
    # named evidence namespace. Seed the namespace this invocation reads.
    evidence_project=self
    [ "$mode" != explicit ] || evidence_project=firstmate-workflow
    project_args=(); [ "$mode" != explicit ] || project_args=(--project firstmate-workflow)
    rm -rf "$repo/state/evidence"
    (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z ${project_args[@]+"${project_args[@]}"}) > "$d/refused.out" 2>&1
    assert_eq 65 "$?" "legacy missing preflight refuses ($missing, $mode)"
    assert_eq 0 "$(jq -s '[.[] | select(.type=="dispatched" or .type=="commit_pushed")]|length' "$repo/state/events.jsonl")" 'legacy refusal emits no dispatch or checkpoint'
    assert_ok "test ! -e '$repo/state/worktrees/T-Z.pid'" 'legacy refusal publishes no pid'
    assert_ok "test ! -d '$repo/state/worktrees/T-Z'" 'legacy refusal creates no worktree'
    assert_eq '' "$(git -C "$repo" ls-remote --heads origin 't-z-*')" 'legacy refusal pushes no branch'
    seed_spec_preflight "$repo" T-Z "" "$evidence_project"
    seed_self_pr_authoring "$repo" T-Z "$evidence_project"
    (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z ${project_args[@]+"${project_args[@]}"}) > "$d/out" 2>&1
    assert_eq 0 "$?" "authorized worker survives missing $missing ($mode self)"
    assert_ok "test -s '$d/prompt.md'" 'legacy worker still runs its adapter'
    assert_ok "test ! -e '$repo/state/pins/T-Z/1.json'" 'failed first pin writes no record'
    assert_contains "$(cat "$d/out")" 'no pin; gate 3 (scope) will refuse' 'failed first pin warns on stderr'
    assert_ok "grep -Rq 'no pin; gate 3 (scope) will refuse' '$repo/state/evidence'" 'failed first pin warning retained in round report'
    rm -rf "$d"
  done
done

finish
