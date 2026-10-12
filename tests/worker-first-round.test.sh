#!/usr/bin/env bash
# T-297: the first round on a spec's bytes - a new task, or the first round
# after a repin - reads the spec and the code, then asks or plans before it
# changes a file. Later rounds on the same bytes are not told again.
# Feature dependencies: bin/fm-worker.sh bin/lib/fm_first_round.py
# bin/lib/fm_spec_pins.py skills/worker/SKILL.md
# Shared fixtures: tests/lib/worker.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/worker.sh
. "$ROOT/tests/lib/worker.sh"
d="$(fixture)"; repo="$d/repo"; GH="$(ghstub "$d")"
printf '%s\n' '{"type":"greenlit","actor":"captain","ts":"2026-10-03T00:00:00Z"}' > "$repo/state/events.jsonl"
cat > "$repo/bin/adapters/mock.sh" <<'M'
#!/usr/bin/env bash
[ "$1" = run ] || exit 64
n=$(( $(find "$FM_SEEN" -maxdepth 1 -name 'prompt-*' | wc -l) + 1 ))
cp "$2" "$FM_SEEN/prompt-$n"
mkdir -p "$3/src"
printf 'round %s\n' "$n" > "$3/src/round-$n"
M
chmod +x "$repo/bin/adapters/mock.sh"
run_worker() {
  (cd "$repo" && FM_ROOT="$repo" FM_GH="$GH" FM_SEEN="$d" bin/fm-worker.sh --task T-Z) > "$d/out" 2>&1
  worker_rc=$?
}
section() {  # section <prompt file>: the read-first section, or nothing; each
  # round's own pinned/ folder is written as PINNED
  sed -n '/^# Read first, then ask or plan$/,/^---$/p' "$1" | sed -E 's#\(/[^)]*/pinned/spec\.json\)#(PINNED)#'
}

# --- worker: plans before code -------------------------------------------
run_worker
assert_eq 0 "$worker_rc" 'the first round runs'
first="$(section "$d/prompt-1")"
# Fail-first: main's prompt has no such section.
assert_contains "$first" 'Before you change any file, read the approved spec' 'worker: plans before code'
assert_contains "$first" 'read the approved spec (PINNED)' "it names the round's pinned spec"
assert_contains "$first" 'and the code it touches' 'it asks for the code to be read too'
for reason in 'the spec is unclear' 'it does not match the code' \
    'does not say what happens to records and tasks' 'already in flight' \
    'lists `design/design.md` but does not name' 'the numbered section (§N or §N.M) it edits'; do
  assert_contains "$first" "$reason" "it asks when $reason"
done
assert_contains "$first" '`ASK-SPEC:T-Z` marker and the question to `.fm-say.md`, and change no file.' \
  'a question goes through the existing question path and changes no file'
assert_contains "$first" 'before you change a file, write a short plan into `.fm-say.md`' 'otherwise it plans first'
assert_contains "$first" 'the files you will change, and how you will prove the task is done' 'the plan names files and proof'
assert_contains "$first" 'do the work in this same round' 'and it goes on in the same round'

# The same spec bytes in a later round: not told again.
run_worker
assert_eq 0 "$worker_rc" 'the second round runs'
assert_ok "test -s '$d/prompt-2'" 'the second round got a prompt'
assert_eq '' "$(section "$d/prompt-2")" 'a later round on the same spec is not told to read first again'

# --- worker: plans after repin -------------------------------------------
mkdir -p "$repo/state/decisions"
printf '%s\n' '{"id":"D-repin","task":"T-Z","kind":"choice","chosen":"A"}' > "$repo/state/decisions/D-repin.json"
printf '%s\n' '{"type":"decision_made","actor":"captain","task":"T-Z","ts":"2026-10-04T00:00:00Z","data":{"decision":"D-repin","chosen":"A"}}' \
  >> "$repo/state/events.jsonl"
jq '.acceptance += ["it also exists twice"]' "$repo/design/tasks/T-Z.json" > "$d/repinned.json"
cp "$d/repinned.json" "$repo/design/tasks/T-Z.json"
(cd "$repo" && . bin/fm-config.sh && fm_storage_init "$repo" && fm_pin create --task T-Z --decision D-repin) > "$d/repin" 2>&1
assert_eq 0 "$?" 'the fixture repins the task'
seed_self_pr_authoring "$repo" T-Z
run_worker
assert_eq 0 "$worker_rc" 'the round after the repin runs'
# Fail-first: main's prompt has no such section.
assert_contains "$(section "$d/prompt-3")" 'This is your first round on this spec: a new task, or the first round after' \
  'worker: plans after repin'
assert_eq "$first" "$(section "$d/prompt-3")" 'the round after a repin gets the same read-first instructions'
run_worker
assert_ok "test -s '$d/prompt-4'" 'the round after the repin round got a prompt'
assert_eq '' "$(section "$d/prompt-4")" 'the round after that is not told again'
safe_rm_rf "$d"
finish
