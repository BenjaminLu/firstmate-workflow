#!/usr/bin/env bash
# T-298: what a Claude round may read under fm's state. The OS sandbox
# already grants a round its own pinned/ and local-tests/ folders read-only;
# claude's own deny rules must not hide them again. A designer round also
# reads the one prototype folder its task names. No round reads another
# round's folders, another prototype, or anything else under state/.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
adapter="$ROOT/bin/adapters/claude.sh"

# A self-project state folder: the round's own worktree and run folder, a
# second round's run folder, and two prototypes.
nr="$(safe_tmpdir)"; st="$nr/state"
mkdir -p "$st/worktrees/T-Z" "$st/worktrees/T-Y" "$st/runs/worker-a-t1-r1" "$st/runs/worker-b-t2-r1/pinned" \
  "$st/prototypes/proto-a" "$st/prototypes/proto-b" "$st/evidence"
: > "$st/events.jsonl"
own_run="$st/runs/worker-a-t1-r1"
mkdir -p "$own_run/pinned" "$own_run/local-tests"
printf '{"id":"T-1"}\n' > "$own_run/pinned/spec.json"
printf '{"id":"T-2"}\n' > "$st/runs/worker-b-t2-r1/pinned/spec.json"
: > "$own_run/local-tests/runner.py"; : > "$own_run/local-tests/plan.json"
: > "$own_run/prompt.md"
printf '<html></html>\n' > "$st/prototypes/proto-a/index.html"
printf '<html></html>\n' > "$st/prototypes/proto-b/index.html"
chmod 0444 "$own_run/pinned/spec.json" "$st/runs/worker-b-t2-r1/pinned/spec.json" \
  "$own_run/local-tests/runner.py" "$own_run/local-tests/plan.json"
chmod 0755 "$own_run/pinned" "$own_run/local-tests"
(
  export HOME="$pk/home"
  # shellcheck source=bin/fm-config.sh
  . "$ROOT/bin/fm-config.sh"
  printf 'vendor: mock\n' > "$nr/reads.yaml"
  fm_policy worker "" "$nr/reads.yaml" | jq --arg s "$st" '.never_read += [$s]' > "$nr/reads.json"
)
d="$(safe_tmpdir)"; make_sandbox "$d"
echo "do the thing" > "$d/prompt"
printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "%%s\\n" "$@" > "%s/argv"\nprintf "ran\\n"\nexit 0\n' \
  "$d" > "$d/fakebin/claude"
chmod +x "$d/fakebin/claude"

# The round's env as its launcher exports it; FM_PROTOTYPE_DIR only when named.
round_env() {
  local role="$1" proto="${2-}"
  env -u FM_PROTOTYPE_DIR ${proto:+FM_PROTOTYPE_DIR="$proto"} FM_CONTEXT_READY=1 FM_MODEL_ROLE="$role" \
    FM_RUN_DIR="$own_run" FM_PINNED_DIR="$own_run/pinned" FM_LOCAL_TESTS_DIR="$own_run/local-tests" \
    FM_POLICY="$nr/reads.json" PATH="$d/fakebin:$closed_path" "${@:3}"
}
# run_round <role> [prototype]: one Claude round in the round's own tree,
# behind the suite's recording sandbox-exec; prints its settings
run_round() {
  rm -f "$d/argv"
  local role="$1" proto="${2-}"
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" round_env "$role" "$proto" \
    "$adapter" run "$d/prompt" "$st/worktrees/T-Z" "$d/log" >"$d/out" 2>&1
  awk 'on{print;exit} $0=="--settings"{on=1}' "$d/argv" 2>/dev/null
}
# denied_over <settings> <path>: every deny rule that covers <path>
denied_over() {
  printf '%s' "$1" | jq -r --arg p "$2" '
    .permissions.deny[] | select(startswith("Read("))
    | sub("^Read\\("; "") | sub("\\)$"; "") | sub("/\\*\\*$"; "") | sub("^/+"; "/")
    | . as $d | select($d == $p or ($p | startswith($d + "/")))' 2>/dev/null
}
# readable <settings> <path>: "started:" when the round ran and no deny rule
# covers <path>; a round that never started is not a readable path
readable() { printf '%s:%s' "$([ -n "$1" ] && echo started)" "$(denied_over "$1" "$2")"; }
allowed() { printf '%s' "$1" | jq -r --arg r "$2" 'any(.permissions.allow[]; . == $r)' 2>/dev/null; }

# --- adapter: own pinned readable (fail-first) -----------------------------
s="$(run_round worker)"
assert_eq "true" "$(jq -r '.permissions.defaultMode == "dontAsk"' <<<"$s" 2>/dev/null)" \
  "the worker round started under claude's own rules"
assert_eq "started:" "$(readable "$s" "$own_run/pinned/spec.json")" 'adapter: own pinned readable'
assert_eq "true" "$(allowed "$s" "Read(/$own_run/pinned/**)")" "and a rule allows reading it"
assert_eq "false" "$(printf '%s' "$s" | jq -r --arg p "$own_run/pinned" \
  'any(.permissions.allow[]; startswith("Edit(/" + $p) or startswith("Write(/" + $p))')" \
  "but nothing allows editing or writing it"
assert_eq "started:" "$(readable "$s" "$own_run/local-tests/runner.py")" "the round's local-tests folder is readable too"
assert_eq "true" "$(allowed "$s" "Read(/$own_run/local-tests/**)")" "and a rule allows reading it"
assert_eq "started:" "$(readable "$s" "$st/worktrees/T-Z/x")" "the round's own tree is still readable"

# --- adapter: other pinned hidden ------------------------------------------
assert_ne "" "$(denied_over "$s" "$st/runs/worker-b-t2-r1/pinned/spec.json")" 'adapter: other pinned hidden'
assert_ne "" "$(denied_over "$s" "$own_run/prompt.md")" "and the round's own run files beside pinned/ stay denied"
assert_ne "" "$(denied_over "$s" "$st/events.jsonl")" "and the rest of state/ stays denied"
assert_ne "" "$(denied_over "$s" "$st/worktrees/T-Y/x")" "and another task's worktree"
assert_ne "" "$(denied_over "$s" "$st/prototypes/proto-a/index.html")" "a worker reads no prototype"
assert_eq "false" "$(allowed "$(FM_DESIGN_SHOTS_DIR="$nr/shots" run_round worker)" "Read(/$nr/shots/**)")" \
  "and a worker gets no rule for a design round's screenshots"

# --- design: prototype readable --------------------------------------------
mkdir -p "$nr/shots"
s="$(FM_DESIGN_SHOTS_DIR="$nr/shots" run_round designer "$st/prototypes/proto-a")"
assert_eq "true" "$(jq -r '.permissions.defaultMode == "dontAsk"' <<<"$s" 2>/dev/null)" \
  "the designer round started under claude's own rules"
assert_eq "true" "$(allowed "$s" "Read(/$nr/shots/**)")" "design: the designer reads its screenshots"
assert_eq "false" "$(printf '%s' "$s" | jq -r --arg p "$nr/shots" \
  'any(.permissions.allow[]; startswith("Edit(/" + $p) or startswith("Write(/" + $p))')" \
  "but nothing allows editing or writing them"
assert_eq "started:" "$(readable "$s" "$st/prototypes/proto-a/index.html")" 'design: prototype readable'
assert_eq "true" "$(allowed "$s" "Read(/$st/prototypes/proto-a/**)")" "and a rule allows reading it"
assert_ne "" "$(denied_over "$s" "$st/prototypes/proto-b/index.html")" "but no other prototype"
assert_ne "" "$(denied_over "$s" "$st/runs/worker-b-t2-r1/pinned/spec.json")" "nor another round's folders"
profile="$(FM_SANDBOX_OS=darwin round_env designer "$st/prototypes/proto-a" \
  "$ROOT/bin/fm-sandbox.sh" profile --policy="$nr/reads.json" --root="$st/worktrees/T-Z" --vendor=claude 2>&1)"
assert_contains "$profile" "(allow file-read* (subpath \"$st/prototypes/proto-a\"))" \
  "the macOS sandbox lets the designer read the task's prototype"
assert_contains "$profile" "(deny file-write* (subpath \"$st/prototypes/proto-a\"))" "and never write it"
assert_lacks "$profile" "proto-b" "and grants no other prototype"
binds="$(FM_SANDBOX_OS=linux round_env designer "$st/prototypes/proto-a" \
  "$ROOT/bin/fm-sandbox.sh" profile --policy="$nr/reads.json" --root="$st/worktrees/T-Z" --vendor=claude 2>&1)"
assert_contains "$binds" "--ro-bind
$st/prototypes/proto-a
$st/prototypes/proto-a" "the Linux sandbox binds the task's prototype read-only"
assert_lacks "$binds" "proto-b" "and binds no other prototype"
# a prototype folder that is not one directly under the round's own
# state/prototypes/, or one a round that is not a designer's names, refuses
# the sandbox profile, so no round starts with it
for os_ in darwin linux; do
  out="$(FM_SANDBOX_OS=$os_ round_env designer "$st/evidence" \
    "$ROOT/bin/fm-sandbox.sh" profile --policy="$nr/reads.json" --root="$st/worktrees/T-Z" --vendor=claude 2>&1)"
  assert_ne 0 "$?" "$os_: a prototype folder outside state/prototypes/ refuses the round"
  assert_contains "$out" "state/prototypes/" "and says where a prototype folder must be"
  out="$(FM_SANDBOX_OS=$os_ round_env worker "$st/prototypes/proto-a" \
    "$ROOT/bin/fm-sandbox.sh" profile --policy="$nr/reads.json" --root="$st/worktrees/T-Z" --vendor=claude 2>&1)"
  assert_ne 0 "$?" "$os_: a round that is not a designer's may not name one"
done

finish
