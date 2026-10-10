#!/usr/bin/env bash
# Periodic retrospective (T-273). The Python cases (tests/lib/retro_cases.py)
# hold the due rule, runs, metrics, prompts, the report format, the card and
# its completion; this file adds what is spoken through the command line:
# the card checker's items, fm-decide.sh's retro purpose and reserved numbers,
# the card end to end, and the --retro route. Every project name is made up.
#
# Fail-first on a tree without the retro: fm_ste.py accepts malformed items,
# fm-decide.sh refuses --purpose retro and lets an ordinary card take a
# reserved number, and the autopilot never queues "retro due". Cases that need
# bin/lib/fm_retro.py, bin/fm-retro.sh or bin/lib/fm-retro-review.sh print
# SKIP there and are never evidence.
# Feature dependencies: bin/lib/fm_retro.py bin/fm-retro.sh bin/lib/fm-retro-review.sh bin/fm-decide.sh bin/lib/fm_ste.py bin/lib/fm_autopilot.py
# Shared cases: tests/lib/retro_cases.py tests/lib/ste_cases.py
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
have_retro=0; [ -f "$ROOT/bin/lib/fm_retro.py" ] && have_retro=1
skip() { printf '    %-52sSKIP (not evidence: %s)\n' "$1" "$2"; }

# --- the Python cases --------------------------------------------------------
# One named outcome per case: ok and FAIL are asserted by name, and a case
# skipped on a tree without bin/lib/fm_retro.py prints SKIP and counts as
# nothing.
python3 "$ROOT/tests/lib/retro_cases.py" "$ROOT" > "$d/cases" 2> "$d/cases.log"
rc=$?
while IFS=$'\t' read -r outcome name; do
  case "$outcome" in
    ok) assert_eq ok ok "$name" ;;
    FAIL) assert_eq ok FAIL "$name" ;;
    SKIP) skip "$name" 'bin/lib/fm_retro.py is absent' ;;
  esac
done < "$d/cases"
[ "$rc" = 0 ] || tail -60 "$d/cases.log" | sed 's/^/      /'
[ -s "$d/cases" ] || assert_eq 'named outcomes' 'none' 'tests/lib/retro_cases.py ran and named its cases'

# --- the card checker's items (bin/lib/fm_ste.py) -----------------------------
for mode in ok dup substituted reordered too-many adds-without-why; do
  python3 "$ROOT/tests/lib/ste_cases.py" retro "$mode" > "$d/items.json"
  python3 "$ROOT/bin/lib/fm_ste.py" check-details --kind choice "$d/items.json" > "$d/report" 2> "$d/error"
  rc=$?
  case "$mode" in
    ok) assert_eq 0 "$rc" 'retro items: a valid list passes the sentence rules'
        assert_eq true "$(jq -r '.items == true and .ok == true and .intent_card == false' "$d/report")" 'retro items: the report says items, not an intent card' ;;
    *) assert_eq 64 "$rc" "retro items: $mode is refused"
       assert_contains "$(cat "$d/error")" 'items' "retro items: $mode names the items field" ;;
  esac
done
spec="$ROOT/design/tasks/T-230.json"
python3 "$ROOT/bin/lib/fm_ste.py" check-explain "$spec" > /dev/null 2>&1
assert_eq 0 "$?" 'an old pinned spec explanation still validates unchanged'
python3 - "$ROOT" "$d/explain.json" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + '/tests/lib')
from ste_cases import retro_card
spec = json.load(open(sys.argv[1] + '/design/tasks/T-230.json'))
for lang in ('en', 'zh-TW'):
    spec['explain'][lang]['items'] = retro_card('ok')[lang]['items']
json.dump(spec, open(sys.argv[2], 'w'))
PY
python3 "$ROOT/bin/lib/fm_ste.py" check-explain "$d/explain.json" > /dev/null 2>&1
assert_eq 64 "$?" 'a spec explanation never carries retro items'

# --- fm-decide.sh: the retro purpose and reserved numbers -----------------------
e="$d/engine"; mkdir -p "$e/state/pending" "$e/state/decisions"
cp -R "$ROOT/bin" "$e/bin"; cp -R "$ROOT/i18n" "$e/i18n" 2>/dev/null
git -C "$e" init -q
run='20261009T120000Z-abcdef'
mkdir -p "$e/state/retro/ids" "$e/state/retro/$run"
printf '{"run_id":"%s"}\n' "$run" > "$e/state/retro/ids/1000.json"
printf '{"run_id":"20261001T000000Z-123456"}\n' > "$e/state/retro/ids/1001.json"
python3 "$ROOT/tests/lib/ste_cases.py" retro ok > "$d/card.json"
jq '{ids:[.en.items[].id]}' "$d/card.json" > "$e/state/retro/$run/card-items.json"
decide() { FM_ROOT="$e" bash "$e/bin/fm-decide.sh" "$@" --repo "$e" > "$d/decide.out" 2> "$d/decide.err" < /dev/null; }
decide --request D-1000 --kind choice --purpose retro --retro-run "$run" --details "$d/card.json"
assert_eq 0 "$?" 'fm-decide accepts a retro card on the number reserved for its run'
assert_eq 'retro|self/R1,P-0a1b2c3d/R2' "$(jq -r '.purpose + "|" + ([.details.en.items[].id]|join(","))' "$e/state/pending/D-1000.json" 2>/dev/null)" 'the pending card keeps its purpose and items'
rm -f "$e/state/pending/D-1000.json"
# Each refusal names its own reason: a tree without the retro refuses the
# purpose itself ("bad purpose"), which is not this validation.
for mode in with-b with-questions; do
  python3 "$ROOT/tests/lib/ste_cases.py" retro "$mode" > "$d/bad.json"
  decide --request D-1000 --kind choice --purpose retro --retro-run "$run" --details "$d/bad.json"
  assert_eq 64 "$?" "a retro card refuses $mode"
  assert_contains "$(cat "$d/decide.err")" 'options A and C only, and no questions' "and says a retro card offers A and C only ($mode)"
done
python3 "$ROOT/tests/lib/ste_cases.py" retro ok | jq '.en.items |= reverse | ."zh-TW".items |= reverse' > "$d/order.json"
decide --request D-1000 --kind choice --purpose retro --retro-run "$run" --details "$d/order.json"
assert_eq 65 "$?" 'a retro card whose items differ from card-items.json is refused'
assert_contains "$(cat "$d/decide.err")" "differ from the run's card-items.json" 'because its items differ from the run'"'"'s order'
decide --request D-1001 --kind choice --purpose retro --retro-run "$run" --details "$d/card.json"
assert_eq 65 "$?" 'a retro card refuses a number reserved for another run'
assert_contains "$(cat "$d/decide.err")" "is not reserved for retrospective $run" 'because the reservation names another run'
decide --request D-1000 --task T-1 --kind choice --purpose retro --retro-run "$run" --details "$d/card.json"
assert_eq 64 "$?" 'a retro card names no task'
assert_contains "$(cat "$d/decide.err")" 'belongs to no task' 'because a retrospective card belongs to no task'
# An ordinary card carries why, how and glossary like every card (T-270).
python3 "$ROOT/tests/lib/ste_cases.py" fixture legacy \
  | jq '(.en, ."zh-TW") |= (. + {why: [{kind: "fact", text: .title}], how: [{kind: "fact", text: .title}], glossary: []})' > "$d/ordinary.json"
decide --request D-1001 --task T-1 --kind choice --details "$d/ordinary.json"
assert_eq 65 "$?" 'an ordinary card cannot take a number a retrospective reserved'
assert_contains "$(cat "$d/decide.err")" 'reserved for a retrospective card' 'because a retrospective reserved it'
assert_ok "[ ! -e '$e/state/pending/D-1001.json' ]" 'and nothing was published under it'
decide --request D-1002 --task T-1 --kind choice --details "$d/ordinary.json"
assert_eq 0 "$?" 'an ordinary hand-raised card on a free number publishes as before'
decide --request D-1003 --task T-1 --kind choice --details "$d/card.json"
assert_eq 64 "$?" 'items are refused on a card whose purpose is not retro'
assert_contains "$(cat "$d/decide.err")" 'items apply only to a retrospective card' 'because items belong to a retrospective card'
# A copied tree without bin/lib/fm_retro.py holds no reservations: it
# publishes a numeric card directly, exactly as before.
c="$d/copy"; mkdir -p "$c/state/pending" "$c/state/retro/ids"; cp -R "$ROOT/bin" "$c/bin"; cp -R "$ROOT/i18n" "$c/i18n"; rm -f "$c/bin/lib/fm_retro.py"
printf '{"run_id":"%s"}\n' "$run" > "$c/state/retro/ids/1004.json"
FM_ROOT="$c" bash "$c/bin/fm-decide.sh" --request D-1004 --task T-1 --kind choice --details "$d/ordinary.json" --repo "$c" >/dev/null 2>&1 </dev/null
assert_eq 0 "$?" 'a tree without fm_retro.py publishes a numeric card directly'

# --- the card end to end, and the --retro route ---------------------------------
if [ "$have_retro" = 1 ] && [ -f "$ROOT/bin/fm-retro.sh" ]; then
  f="$d/full"; mkdir -p "$f/state"; cp -R "$ROOT/bin" "$f/bin"; cp -R "$ROOT/i18n" "$f/i18n"; git -C "$f" init -q
  printf 'retro:\n  vendor: claude\n  model: claude-opus-5-5\n' > "$f/config.yaml"
  run="$(python3 - "$ROOT" "$f" <<'PY'
import json, sys, time
sys.path.insert(0, sys.argv[1] + '/bin/lib')
import fm_retro as R
retro = R.Retro(sys.argv[2])
run = '20261009T120000Z-fedcba'
projects = R.load_projects(retro)
R.write_json(retro.run_dir(run) / 'private/labels.json', R.labels(retro, projects))
items = [dict(id=f'R{n}', kind='cleanup', carried_from=None, effect='removes', removes=['tests/old.test.sh'],
              en=dict(title='Delete the old suite.', why='Another suite covers the same checks.', how='Remove the file.',
                      evidence=['tests/a.sh:1'], scope=[]),
              **{'zh-TW': dict(title='刪除舊的測試。', why='另一組測試已涵蓋同樣的檢查。', how='移除檔案。',
                               evidence=['tests/a.sh:1'], scope=[])}) for n in (1, 2)]
R.write_json(retro.run_dir(run) / 'projects/self/items.json', dict(items=items, generic=[]))
R.write_json(retro.run_dir(run) / 'state.json', dict(schema=1, run_id=run, state='reviewed', rounds=['self'],
             window=dict(start='2026-10-01T00:00:00Z', end='2026-10-09T12:00:00Z')))
R.write_json(retro.index_path, dict(schema=1, baseline_at='2026-10-01T00:00:00Z', last_completed=None, open_run=run))
print(run)
PY
)"
  started=$(date +%s)
  bash "$f/bin/fm-retro.sh" card --run "$run" > "$d/card.out" 2> "$d/card.err" </dev/null
  rc=$?; took=$(( $(date +%s) - started ))
  assert_eq 0 "$rc" 'fm-retro.sh card publishes the run'"'"'s card'
  assert_ok "[ $took -le 30 ]" "and finishes within 30 seconds (took ${took}s)"
  assert_eq 'D-1000.json' "$(ls "$f/state/pending")" 'exactly one card, on the first reserved number'
  assert_eq 'awaiting-answer' "$(jq -r .state "$f/state/retro/$run/state.json")" 'the run waits for the answer'
  bash "$f/bin/fm-retro.sh" card --run "$run" > /dev/null 2>&1 </dev/null
  assert_eq 'D-1000.json' "$(ls "$f/state/pending")" 'a repeated card raises nothing'
  bash "$f/bin/fm-retro.sh" card > /dev/null 2>&1 </dev/null
  assert_eq 64 "$?" 'card without --run is a usage error'
else
  skip 'fm-retro.sh card end to end' 'bin/fm-retro.sh is absent'
fi
if [ -f "$ROOT/bin/lib/fm-retro-review.sh" ]; then
  bash "$ROOT/bin/fm-review.sh" --retro not-a-run --retro-cross > /dev/null 2> "$d/route.err" </dev/null
  assert_eq 64 "$?" 'fm-review.sh --retro routes to its own launcher before any task logic'
  assert_contains "$(cat "$d/route.err")" '--retro needs a run id' 'and the launcher is what refused it'
  bash "$ROOT/bin/fm-review.sh" --retro 20261009T120000Z-abcdef --retro-cross --project x > /dev/null 2> "$d/route.err" </dev/null
  assert_eq 64 "$?" 'a retro round takes one of --project and --retro-cross'
else
  skip 'fm-review.sh --retro routing' 'bin/lib/fm-retro-review.sh is absent'
fi
finish
