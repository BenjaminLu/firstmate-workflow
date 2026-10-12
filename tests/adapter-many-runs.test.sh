#!/usr/bin/env bash
# T-300: a Claude round starts however many past run folders state/runs
# keeps. Its deny rules carve around the round's own pinned/ and
# local-tests/ folders, so they name every other run folder; they go in a
# settings file, never on the command line, which macOS caps at 1 MB and
# Linux at 128 KB for one argument. The rules stay as strict as before.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/adapter.sh
. "$ROOT/tests/lib/adapter.sh"
adapter="$ROOT/bin/adapters/claude.sh"

# A self-project state folder with the round's own run folder, one other
# round's, and <n> more past run folders named the way the launcher names them.
nr="$(safe_tmpdir)"; st="$nr/state"
own_run="$st/runs/worker-imani-t300-r1c"
other_run="$st/runs/worker-b-t2-r1"
mkdir -p "$st/worktrees/T-Z" "$st/worktrees/T-Y" "$own_run/pinned" "$own_run/local-tests" \
  "$other_run/pinned" "$st/evidence"
: > "$st/events.jsonl"; : > "$own_run/prompt.md"
printf '{"id":"T-1"}\n' > "$own_run/pinned/spec.json"
printf '{"id":"T-2"}\n' > "$other_run/pinned/spec.json"
: > "$own_run/local-tests/runner.py"; : > "$own_run/local-tests/plan.json"
chmod 0444 "$own_run/pinned/spec.json" "$other_run/pinned/spec.json" \
  "$own_run/local-tests/runner.py" "$own_run/local-tests/plan.json"
chmod 0755 "$own_run/pinned" "$own_run/local-tests"
past_runs() { # past_runs <from> <to>: make run folders worker-past-t<i>-r1
  local i
  for ((i = $1; i < $2; i++)); do printf '%s/runs/worker-past-t%05d-r1\n' "$st" "$i"; done | xargs mkdir -p
}
(
  export HOME="$pk/home"
  # shellcheck source=bin/fm-config.sh
  . "$ROOT/bin/fm-config.sh"
  printf 'vendor: mock\n' > "$nr/reads.yaml"
  fm_policy worker "" "$nr/reads.yaml" | jq --arg s "$st" '.never_read += [$s]' > "$nr/reads.json"
)
d="$(safe_tmpdir)"; make_sandbox "$d"
echo "do the thing" > "$d/prompt"
{ printf '#!/usr/bin/env bash\n'; fake_claude_settings "$d/argv.settings"
  printf 'cat > /dev/null\nprintf "%%s\\n" "$@" > "%s/argv"\nprintf "ran\\n"\nexit 0\n' "$d"; } > "$d/fakebin/claude"
chmod +x "$d/fakebin/claude"

# run_round: one Claude worker round in its own tree, behind the suite's
# recording sandbox-exec; prints the bytes its command line took
run_round() {
  rm -f "$d/argv" "$d/argv.settings" "$d/log"
  FM_SANDBOX_OS=darwin FM_SANDBOX_TOOL="$pk/sandbox-exec" FM_CONTEXT_READY=1 FM_MODEL_ROLE=worker \
    FM_RUN_DIR="$own_run" FM_PINNED_DIR="$own_run/pinned" FM_LOCAL_TESTS_DIR="$own_run/local-tests" \
    FM_POLICY="$nr/reads.json" PATH="$d/fakebin:$closed_path" \
    "$adapter" run "$d/prompt" "$st/worktrees/T-Z" "$d/log" >"$d/out" 2>&1
  wc -c < "$d/argv" 2>/dev/null | tr -d ' ' || echo 0
}
# denied_over <path>: every Read deny rule of the last round that covers <path>
denied_over() {
  jq -r --arg p "$1" '
    .permissions.deny[] | select(startswith("Read("))
    | sub("^Read\\("; "") | sub("\\)$"; "") | sub("/\\*\\*$"; "") | sub("^/+"; "/")
    | . as $d | select($d == $p or ($p | startswith($d + "/")))' "$d/argv.settings" 2>/dev/null
}

# --- adapter: many runs still start (fail-first) -----------------------------
past_runs 0 10
few="$(run_round)"
assert_contains "$(cat "$d/log" 2>/dev/null)" "ran" "a round with a few past runs starts"
past_runs 10 3000
many="$(run_round)"
assert_contains "$(cat "$d/log" 2>/dev/null)" "ran" 'adapter: many runs still start'
assert_eq "$few" "$many" "and its command line is no longer with 3,000 past runs than with ten"
assert_lacks "$(cat "$d/argv" 2>/dev/null)" "worker-past-t" "no past run folder is named on the command line"

# --- adapter: other runs unreadable -----------------------------------------
assert_eq "true" "$(jq -r '.permissions.defaultMode == "dontAsk"' "$d/argv.settings" 2>/dev/null)" \
  "the many-runs round started under claude's own rules"
assert_ne "" "$(denied_over "$st/runs/worker-past-t02999-r1/pinned/spec.json")" 'adapter: other runs unreadable'
assert_ne "" "$(denied_over "$st/runs/worker-past-t00000-r1")" "the first past run folder too"
assert_ne "" "$(denied_over "$other_run/pinned/spec.json")" "and another round's pinned spec"
assert_ne "" "$(denied_over "$own_run/prompt.md")" "and the round's own run files beside pinned/"
assert_ne "" "$(denied_over "$st/events.jsonl")" "and the rest of state/"
assert_ne "" "$(denied_over "$st/worktrees/T-Y/x")" "and another task's worktree"
assert_eq "" "$(denied_over "$own_run/pinned/spec.json")" "while the round's own pinned spec stays readable"
assert_eq "" "$(denied_over "$own_run/local-tests/runner.py")" "and its local tests"
assert_eq "" "$(denied_over "$st/worktrees/T-Z/x")" "and its own tree"
settings_path="$(awk 'on{print;exit} $0=="--settings"{on=1}' "$d/argv" 2>/dev/null)"
assert_eq "true" "$(jq -r --arg f "$settings_path" \
  'any(.permissions.deny[]; . == "Edit(/\($f))") and any(.permissions.deny[]; . == "Write(/\($f))")' \
  "$d/argv.settings" 2>/dev/null)" "and no file tool may rewrite the round's own settings file"

finish
