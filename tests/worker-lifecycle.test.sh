#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
d="$(fixture)"; r="$d/repo"; GH="$(ghstub "$d")"
# T-116: a global run counter far along, so the round-1 actor below cannot
# come from a counter that happens to start at 1
mkdir -p "$r/state/runs"; printf '{"number":472}\n' > "$r/state/runs/counter.json"
out="$(cd "$r" && FM_ROOT="$r" FM_GH="$GH" bin/fm-worker.sh --task T-Z --name worker-1 2>&1)"; rc=$?
assert_eq "0" "$rc" "a clean run exits 0"
branch="$(printf '%s' "$out" | tail -1)"
assert_contains "$branch" "t-z" "it names the branch after the task"
assert_ok "test -d '$r/state/worktrees/T-Z'" "it made a worktree of its own"
assert_ok "git -C '$r' rev-parse --verify '$branch'" "the branch exists"
assert_eq "1" "$(git -C "$r" rev-list --count "main..$branch")" "exactly one commit"
assert_ok "grep -q mock.txt <<<\"\$(git -C '$r/state/worktrees/T-Z' show --stat HEAD)\"" "the adapter's file is in it"
assert_ok "cd '$ROOT' && git --git-dir='$d/remote.git' rev-parse --verify '$branch'" "it pushed to the remote"
assert_contains "$(cat "$d/ghcalls")" "pr create" "it opened a pull request"

log="$r/state/events.jsonl"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "commit_pushed" "it emitted commit_pushed"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "pr_opened" "it emitted pr_opened"
assert_eq "$(jq -r 'select(.type=="dispatched")|.actor' "$log")" \
  "$(jq -r 'select(.type=="dispatched")|.data.crew_name' "$log")" \
  "the worker publishes its exact canonical actor as crew_name"
# T-116: the identity rides every payload of the run as separate fields, and
# a task's first worker run is round 1, attempt 1
wactor="$(jq -r 'select(.type=="dispatched")|.actor' "$log")"
assert_matches "$wactor" '^worker-[a-z0-9-]+-tz-r1$' "a first worker run's actor carries round 1, not a run counter"
assert_eq '["worker","T-Z",1,1,"string",true]' \
  "$(jq -c --arg a "$wactor" 'select(.actor==$a)|.data.identity|[.role,.task,.round,.attempt,(.name|type),has("project")]' "$log" | sort -u)" \
  "every payload of the worker run carries role, task, round, attempt, name and project as fields"
assert_eq "$(jq -r '[.name,.round,.attempt]|join(" ")' "$r/state/runs/$wactor/identity.json")" \
  "$(jq -r 'select(.type=="dispatched")|.data.identity|[.name,.round,.attempt]|join(" ")' "$log")" \
  "and they are the fields identity.json records"
assert_ne "null" "$(jq -r 'select(.type=="dispatched")|.data.activity.en' "$log")" \
  "the worker emits authored activity.en (never invents from a missing field as null-only)"
assert_ne "null" "$(jq -r 'select(.type=="dispatched")|.data.activity["zh-TW"]' "$log")" \
  "the worker emits authored activity.zh-TW"
assert_contains "$(jq -r .type < "$log" | tr '\n' ' ')" "crew_status" \
  "the worker emits mid-run crew_status at a script-known node"
assert_eq "0" "$(jq -c 'select(.type=="crew_status" and (.data.progress!=null))' "$log" | wc -l | tr -d ' ')" \
  "ordinary mid-run status does not invent a percentage without a denominator"

# the prompt carries the task and the skill, and is not left lying around
assert_fail "test -f '$r/state/worktrees/T-Z/.fm-prompt.md'" "the prompt is cleaned up"

# T-147: a new task's spec exists only in firstmate's working tree, never
# committed on the base. T-157's codex round was told the file "is committed
# on this branch", found it was not, and stopped. The worker copies it into
# the new task's worktree before the round, and it goes out in the round's
# commit.
dn="$(fixture)"; rn="$dn/repo"; GHn="$(ghstub "$dn")"
jq -n '{id:"T-N",title:"a new task",scope:["src/**","design/tasks/T-N.json"],acceptance:["it exists"]}' \
  > "$rn/design/tasks/T-N.json"
seed_spec_preflight "$rn" T-N
seed_self_pr_authoring "$rn" T-N self
assert_eq "?? design/tasks/T-N.json" "$(git -C "$rn" status --porcelain -- design/tasks)" \
  "the new task's spec is untracked in the dispatching repository"
outn="$(cd "$rn" && FM_ROOT="$rn" FM_GH="$GHn" bin/fm-worker.sh --task T-N --name worker-n 2>&1)"
assert_eq "0" "$?" "a new task whose spec is untracked runs"
bn="$(printf '%s' "$outn" | tail -1)"
assert_eq "$(cat "$rn/design/tasks/T-N.json")" "$(git -C "$rn" show "$bn:design/tasks/T-N.json" 2>/dev/null)" \
  "its spec file is copied into the worktree and committed with the round's work"
assert_contains "$(git -C "$rn" show --stat --format= "$bn")" "mock.txt" "beside what the round wrote"
assert_contains "$outn" "design/tasks/T-N.json is not on the base; copied into the worktree" "and the worker says so"
# the copy is the script's, not the round's: a round that leaves it as it
# was and changes nothing else changed nothing
dn2="$(fixture)"; rn2="$dn2/repo"; GHn2="$(ghstub "$dn2")"
jq -n '{id:"T-N",title:"a new task",scope:["src/**"],acceptance:["it exists"]}' > "$rn2/design/tasks/T-N.json"
seed_spec_preflight "$rn2" T-N
seed_self_pr_authoring "$rn2" T-N self
outn2="$(cd "$rn2" && FM_ROOT="$rn2" FM_GH="$GHn2" FM_MOCK_FILE=design/tasks/T-N.json \
  FM_MOCK_BODY="$(cat "$rn2/design/tasks/T-N.json")" bin/fm-worker.sh --task T-N --name worker-n2 2>&1)"
assert_eq "1" "$?" "a round that only has the copied spec changed nothing"
assert_contains "$outn2" "the adapter changed nothing" "and is reported as such"
safe_rm_rf "$dn" "$dn2"

# A fresh branch needs no history probe to decide whether to refresh its spec.
dfresh="$(fixture)"; rfresh="$dfresh/repo"; GHfresh="$(ghstub "$dfresh")"
cat > "$dfresh/stub/git" <<'G'
#!/usr/bin/env bash
case "$1" in
  merge-base|log) echo "unexpected fresh-branch history probe: $*" >&2; exit 70 ;;
esac
exec "$WORKER_TEST_GIT" "$@"
G
chmod +x "$dfresh/stub/git"
outfresh="$(cd "$rfresh" && WORKER_TEST_GIT="$(command -v git)" PATH="$dfresh/stub:$PATH" \
  FM_ROOT="$rfresh" FM_GH="$GHfresh" bin/fm-worker.sh --task T-Z 2>&1)"; rcfresh=$?
assert_eq 0 "$rcfresh" "fresh branch completes without spec-refresh history probes"
assert_lacks "$outfresh" 'unexpected fresh-branch history probe' "fresh branch never probes earlier spec commits"
safe_rm_rf "$dfresh"

# T-160: an abandoned branch is not evidence that a worker authored anything.
for leftover in empty commit dirty spec spec_pr; do
  dl="$(fixture)"; rl="$dl/repo"; GHl="$(ghstub "$dl")"
  bl=t-n-leftover; tl="$rl/state/worktrees/T-N"
  mkdir -p "$rl/state/worktrees"
  git -C "$rl" worktree add -q -b "$bl" "$tl" main
  jq -n '{id:"T-N",title:"a new task",scope:["src/**"],acceptance:["WIDENED_SPEC"]}' > "$rl/design/tasks/T-N.json"
  seed_spec_preflight "$rl" T-N
  seed_self_pr_authoring "$rl" T-N self
  case "$leftover" in
    commit)
      echo authored > "$tl/earlier.txt"
      mkdir -p "$tl/design/tasks"
      jq '.acceptance=["AUTHORED_SPEC"]' "$rl/design/tasks/T-N.json" > "$tl/design/tasks/T-N.json"
      git -C "$tl" add earlier.txt design/tasks/T-N.json; git -C "$tl" commit -qm earlier
      seed_spec_preflight "$rl" T-N "$tl/design/tasks/T-N.json" ;;
    dirty) echo authored > "$tl/earlier.txt" ;;
    spec|spec_pr)
      mkdir -p "$tl/design/tasks"
      jq '.acceptance=["OLD_SPEC"]' "$rl/design/tasks/T-N.json" > "$tl/design/tasks/T-N.json"
      git -C "$tl" add design/tasks/T-N.json; git -C "$tl" commit -qm spec ;;
  esac
  echo current > "$rl/current-base.txt"
  git -C "$rl" add current-base.txt; git -C "$rl" commit -qm advance
  git -C "$rl" push -q origin main
  cat > "$rl/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
cp "$2" "$3/seen-prompt.txt"
printf 'done\n' > "$3/done.txt"
M
  if [ "$leftover" = spec_pr ]; then
    sed -e 's/echo null/echo 42/' \
      -e '/case " /a\
  *" pr view "*" --json comments "*) echo FIRSTMATE_SCOPE_REPLY; exit 0 ;;' "$GHl" > "$GHl.next"
    mv "$GHl.next" "$GHl"; chmod +x "$GHl"
  fi
  outl="$(cd "$rl" && FM_ROOT="$rl" FM_GH="$GHl" bin/fm-worker.sh --task T-N 2>&1)"; rcl=$?
  assert_eq 0 "$rcl" "$leftover leftover dispatch completes"
  assert_eq "$bl" "$(printf '%s' "$outl" | tail -1)" "$leftover leftover reports its preserved branch"
  promptl="$(cat "$tl/seen-prompt.txt" 2>/dev/null)"
  case "$leftover" in
    empty)
      assert_ok "git -C '$rl' merge-base --is-ancestor main '$bl'" "empty leftover starts at the current base"
      assert_lacks "$promptl" "Your branch already carries your earlier work" "empty leftover gets a first-round prompt"
      assert_eq "$(cat "$rl/design/tasks/T-N.json")" "$(cat "$tl/design/tasks/T-N.json" 2>/dev/null)" "empty leftover receives the missing spec" ;;
    commit|dirty)
      assert_eq authored "$(cat "$tl/earlier.txt" 2>/dev/null)" "$leftover leftover preserves authored work in the active tree"
      assert_contains "$promptl" "Your branch already carries your earlier work" "$leftover leftover prompt acknowledges earlier work" ;;
    spec|spec_pr)
      assert_lacks "$promptl" "Your branch already carries your earlier work" "$leftover spec-only branch gets a first-round prompt"
      assert_contains "$promptl" WIDENED_SPEC "spec-only branch receives firstmate's revised acceptance"
      assert_lacks "$promptl" OLD_SPEC "spec-only branch no longer prompts with obsolete acceptance"
      assert_eq "$(cat "$rl/design/tasks/T-N.json")" "$(cat "$tl/design/tasks/T-N.json" 2>/dev/null)" "spec-only branch receives the repository spec" ;;
  esac
  if [ "$leftover" = commit ]; then
    assert_contains "$promptl" AUTHORED_SPEC "implementation commits retain the branch spec"
    assert_lacks "$promptl" WIDENED_SPEC "firstmate's copy cannot override an implemented task"
  fi
  if [ "$leftover" = spec_pr ]; then
    assert_lacks "$promptl" FIRSTMATE_SCOPE_REPLY "spec-only draft does not treat a PR comment as an approved brief"
  fi
  safe_rm_rf "$dl"
done

# T-127: the crew runs on the model config.yaml names, and the round
# records vendor, model and cli_version as separate fields, read from the
# run itself. FM_MOCK_MODEL stands in for a real vendor's transcript
# reporting the model it actually ran on (bin/adapters/mock.sh).
d3="$(fixture)"; r3="$d3/repo"; GH3="$(ghstub "$d3")"
printf 'model: mock-model-a\n' >> "$r3/config.yaml"
seed_self_pr_authoring "$r3" T-Z
( cd "$r3" && FM_ROOT="$r3" FM_GH="$GH3" FM_MOCK_MODEL="mock-model-b" bin/fm-worker.sh --task T-Z --name worker-m >/dev/null 2>&1 )
assert_eq "0" "$?" "a round with a configured model still exits 0"
log3="$r3/state/events.jsonl"
m3actor="$(jq -r 'select(.type=="dispatched")|.actor' "$log3")"
# the model is only known once the round's own CLI has run, so only the
# payloads from that point on (commit_pushed onward) carry it; dispatched,
# emitted before any adapter runs, correctly cannot yet
assert_eq '["mock","mock-model-a","mock-model-b","unknown"]' \
  "$(jq -c 'select(.type=="commit_pushed")|.data.identity|[.vendor,.model_requested,.model,.cli_version]' "$log3" | sort -u)" \
  "the round's crew payloads carry vendor, model_requested, model and cli_version as separate fields"
assert_eq '["mock","mock-model-a","mock-model-b","unknown"]' \
  "$(jq -c '[.vendor,.model_requested,.model,.cli_version]' "$r3/state/runs/$m3actor/identity.json")" \
  "and identity.json records the same four fields"
assert_eq "true" "$(jq -r '.model_mismatch' "$r3/state/runs/$m3actor/identity.json")" \
  "flagged as a mismatch since the run reported a different model than config.yaml asked for"
assert_contains "$(jq -r .type < "$log3" | tr '\n' ' ')" "model_mismatch" \
  "the run emits model_mismatch when they differ"
mrow3="$(jq -c 'select(.type=="model_mismatch")' "$log3")"
assert_eq "mock-model-a" "$(jq -r '.data.model_requested' <<<"$mrow3")" "naming what was requested"
assert_eq "mock-model-b" "$(jq -r '.data.model' <<<"$mrow3")" "and what it actually ran on"
assert_ne "" "$(jq -r '.summary.en' <<<"$mrow3")" "with an English summary"
assert_ne "" "$(jq -r '.summary."zh-TW"' <<<"$mrow3")" "and a zh-TW one"

# no mismatch when the run reports the model it was asked for
d4="$(fixture)"; r4="$d4/repo"; GH4="$(ghstub "$d4")"
printf 'model: mock-model-a\n' >> "$r4/config.yaml"
seed_self_pr_authoring "$r4" T-Z
( cd "$r4" && FM_ROOT="$r4" FM_GH="$GH4" FM_MOCK_MODEL="mock-model-a" bin/fm-worker.sh --task T-Z --name worker-n >/dev/null 2>&1 )
log4="$r4/state/events.jsonl"
m4actor="$(jq -r 'select(.type=="dispatched")|.actor' "$log4")"
assert_eq "false" "$(jq -r '.model_mismatch' "$r4/state/runs/$m4actor/identity.json")" \
  "and no mismatch when the run reports the model it was asked for"
assert_eq "0" "$(jq -c 'select(.type=="model_mismatch")' "$log4" | wc -l | tr -d ' ')" \
  "so no model_mismatch event either"

# no model configured at all: the round runs on whatever the CLI defaults
# to, reported as unknown, never guessed - and the fields still ride the
# run, an old-run's-worth of them, so a run with none configured still
# renders the same shape the board reads
d4b="$(fixture)"; r4b="$d4b/repo"; GH4b="$(ghstub "$d4b")"
( cd "$r4b" && FM_ROOT="$r4b" FM_GH="$GH4b" bin/fm-worker.sh --task T-Z --name worker-o >/dev/null 2>&1 )
log4b="$r4b/state/events.jsonl"
m4bactor="$(jq -r 'select(.type=="dispatched")|.actor' "$log4b")"
assert_eq '["mock","","unknown","unknown"]' \
  "$(jq -c '[.vendor,.model_requested,.model,.cli_version]' "$r4b/state/runs/$m4bactor/identity.json")" \
  "with no model configured, the round still records vendor and cli_version; model is unknown, never guessed"
assert_eq "false" "$(jq -r '.model_mismatch' "$r4b/state/runs/$m4bactor/identity.json")" \
  "asking for nothing and getting nothing is never a mismatch"

# T-146: a model is named per vendor. A round that falls back to another
# vendor is handed that vendor's own model, never the first one's, and every
# crew event it emits - crew_status included - carries the vendor and model
# from the start. `down` stands in for a vendor that is unavailable; mock
# then takes the round.
dv5="$(fixture)"; rv5="$dv5/repo"; GHv5="$(ghstub "$dv5")"
cat > "$rv5/config.yaml" <<'Y'
vendor: down
models:
  down: model-down
  mock: model-mock
fallback:
  - mock
Y
seed_self_pr_authoring "$rv5" T-Z
cat > "$rv5/bin/adapters/down.sh" <<D
#!/usr/bin/env bash
printf 'down=%s\n' "\${FM_MODEL-unset}" >> "$dv5/handed"
exit 2
D
chmod +x "$rv5/bin/adapters/down.sh"
( cd "$rv5" && FM_ROOT="$rv5" FM_GH="$GHv5" FM_MOCK_MODEL="model-mock" bin/fm-worker.sh --task T-Z --name worker-p >/dev/null 2>&1 )
logv5="$rv5/state/events.jsonl"
mv5actor="$(jq -r 'select(.type=="dispatched")|.actor' "$logv5")"
assert_eq "down=model-down" "$(cat "$dv5/handed" 2>/dev/null)" "the vendor the round starts on is handed its own model"
assert_eq '["mock","model-mock","model-mock",false]' \
  "$(jq -c '[.vendor,.model_requested,.model,.model_mismatch]' "$rv5/state/runs/$mv5actor/identity.json")" \
  "the fallback vendor is handed its own model, not the first vendor's, and runs on it: no mismatch"
assert_eq "0" "$(jq -c 'select(.type=="model_mismatch")' "$logv5" | wc -l | tr -d ' ')" \
  "so no model_mismatch event"
assert_eq '["down","model-down"]' \
  "$(jq -c 'select(.type=="dispatched")|.data.identity|[.vendor,.model_requested]' "$logv5")" \
  "the round's first event names the vendor it starts on and that vendor's model"
assert_eq "0" "$(jq -c 'select(.actor==$a and .type=="crew_status" and (.data.identity.vendor==null))' \
  --arg a "$mv5actor" "$logv5" | wc -l | tr -d ' ')" \
  "no crew_status of the round goes without the vendor"
assert_eq '["mock","model-mock","model-mock"]' \
  "$(jq -c 'select(.type=="commit_pushed")|.data.identity|[.vendor,.model_requested,.model]' "$logv5" | sort -u)" \
  "and once the round has run, every commit_pushed carries the vendor that ran and what it reported (one line each, all the same)"
# A regression guard, not fail-first: the round's last crew_status already
# carried the vendor and model without T-146. "no crew_status of the round
# goes without the vendor" above is the fail-first one for this property.
assert_eq '["mock","model-mock"]' \
  "$(jq -sc --arg a "$mv5actor" '[.[]|select(.actor==$a and .type=="crew_status")]|last|.data.identity|[.vendor,.model]' "$logv5")" \
  "including its last crew_status, which the board reads the crewman from"

# --vendor sends the round to a vendor config.yaml does not start on; it
# gets that vendor's model
dv6="$(fixture)"; rv6="$dv6/repo"; GHv6="$(ghstub "$dv6")"
cp "$rv5/config.yaml" "$rv6/config.yaml"
seed_self_pr_authoring "$rv6" T-Z
( cd "$rv6" && FM_ROOT="$rv6" FM_GH="$GHv6" FM_MOCK_MODEL="model-mock" bin/fm-worker.sh --task T-Z --vendor mock --name worker-q >/dev/null 2>&1 )
mv6actor="$(jq -r 'select(.type=="dispatched")|.actor' "$rv6/state/events.jsonl")"
assert_eq '["mock","model-mock"]' \
  "$(jq -c '[.vendor,.model_requested]' "$rv6/state/runs/$mv6actor/identity.json")" \
  "--vendor's round is handed that vendor's own model"
# a vendor with no model named runs on its CLI's default, and records it
dv7="$(fixture)"; rv7="$dv7/repo"; GHv7="$(ghstub "$dv7")"
printf 'vendor: mock\nmodels:\n  down: model-down\n' > "$rv7/config.yaml"
seed_self_pr_authoring "$rv7" T-Z
( cd "$rv7" && FM_ROOT="$rv7" FM_GH="$GHv7" FM_MOCK_MODEL="mock-cli-default" bin/fm-worker.sh --task T-Z --name worker-r >/dev/null 2>&1 )
mv7actor="$(jq -r 'select(.type=="dispatched")|.actor' "$rv7/state/events.jsonl")"
assert_eq '["mock","","mock-cli-default",false]' \
  "$(jq -c '[.vendor,.model_requested,.model,.model_mismatch]' "$rv7/state/runs/$mv7actor/identity.json")" \
  "a vendor with no model named asks for none, and records the model its CLI defaulted to"
rm -rf "$dv5" "$dv6" "$dv7"

# an adapter that cannot reach its vendor falls through to the next one
d2="$(fixture)"; r2="$d2/repo"; GH2="$(ghstub "$d2")"
( cd "$r2" && FM_ROOT="$r2" FM_GH="$GH2" FM_MOCK_EXIT=2 bin/fm-worker.sh --task T-Z >/dev/null 2>&1 )
assert_eq "2" "$?" "every vendor unavailable exits 2"
assert_contains "$(jq -r .type < "$r2/state/events.jsonl" | tr '\n' ' ')" "vendor_unavailable" \
  "it emitted vendor_unavailable"
assert_eq "" "$(cat "$d2/ghcalls" 2>/dev/null)" "an unavailable vendor opens no pull request"

# The adapters' library (the login check, T-121) is loaded where the chain
# runs, not at start: a worker that ends before its round - here on its own
# usage error - needs no adapter, which a fixture copying only fm-worker.sh
# and fm-config.sh (tests/reconcile.test.sh) relies on
dn="$(safe_tmpdir)"; mkdir -p "$dn/bin"
# shellcheck source=tests/lib/config-modules.sh
. "$ROOT/tests/lib/config-modules.sh"
cp "$ROOT/bin/fm-worker.sh" "$ROOT/bin/fm-config.sh" "$dn/bin/"; config_modules_fixture "$dn/bin/"
out="$("$dn/bin/fm-worker.sh" 2>&1)"; rc=$?
assert_eq "64" "$rc" "a worker with no adapters' library still reaches its own usage check"
assert_lacks "$out" "adapters/_lib.sh" "and never ends at start for an adapter it has not reached"
rm -rf "$dn"


rm -rf "$d" "$d2"

cd "$ROOT" || exit 1
PATH="$suite_original_path"; export PATH
safe_rm_rf "$suite_tools"
finish
