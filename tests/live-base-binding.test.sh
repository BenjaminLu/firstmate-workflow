#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
python3 "$ROOT/tests/lib/external_adopt.py" "$ROOT" base
assert_eq 0 "$?" 'adopted PR base follows pinned ownership and base'
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
mkdir -p "$d/stub" "$d/repo"
export FM_TARGET_ROOT="$d/repo" FM_BINDING_REPOSITORY=owner/project
export FM_GH="$d/stub/gh" PATH="$d/stub:$PATH"
export FM_EXTERNAL=0
unset PR_STATE VIEW_HEAD FETCHED_PULL_HEAD LOCAL_TASK_HEAD VIEW_BASE_NAME
export PR_HEAD=cccccccccccccccccccccccccccccccccccccccc
export OLD_BASE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export LIVE_BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export LOCAL_BASE="$LIVE_BASE" BASE_NAME=release/next
export VIEW_LOG="$d/view-log"
export FETCH_FILE="$d/fetched" FETCH_LOG="$d/fetch-log" FETCH_FAIL=0
cat > "$d/stub/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:1] == ['api']:
    prefix = 'repos/owner/project/'
    if args[1] == prefix + 'branches/release%2Fnext/protection/required_status_checks':
        print(json.dumps(dict(contexts=['ci'], checks=[])))
    elif args[1] == prefix + 'commits/' + os.environ['PR_HEAD'] + '/check-runs?per_page=100':
        print(json.dumps(dict(check_runs=[dict(id=1, name='ci', head_sha=os.environ['PR_HEAD'],
                                             status='completed', conclusion='success')])))
    elif args[1] == prefix + 'commits/' + os.environ['PR_HEAD'] + '/status?per_page=100':
        print(json.dumps(dict(sha=os.environ['PR_HEAD'], statuses=[])))
    else:
        sys.exit('unexpected API request: ' + repr(args))
    sys.exit(0)
assert args == ['pr', 'view', '9', '--repo', 'owner/project', '--json',
                        'headRefOid,baseRefOid,baseRefName,headRefName,state']
with open(os.environ['VIEW_LOG'], 'a') as log:
    log.write('pr view\n')
# GitHub's recorded base stays old when only the base branch advances.
print(json.dumps(dict(state=os.environ.get('PR_STATE', 'OPEN'),
                      headRefOid=os.environ.get('VIEW_HEAD', os.environ['PR_HEAD']),
                      baseRefOid=os.environ['OLD_BASE'],
                      baseRefName=os.environ.get('VIEW_BASE_NAME', os.environ['BASE_NAME']), headRefName='task')))
PY
cat > "$d/stub/git" <<'PY'
#!/usr/bin/env python3
import os, sys
from pathlib import Path
assert sys.argv[1:3] == ['-C', os.environ['FM_TARGET_ROOT']]
args = sys.argv[3:]
if args[:3] == ['fetch', '--no-tags', 'https://github.com/owner/project.git']:
    source, destination = args[3].split(':')
    assert destination.startswith('refs/fm/fetch/')
    fetched = Path(os.environ['FETCH_FILE']) / destination
    if source == '+refs/heads/' + os.environ['BASE_NAME']:
        with Path(os.environ['FETCH_LOG']).open('a') as log:
            log.write('exact repository and base ref fetched\n')
        if os.environ['FETCH_FAIL'] == '1':
            sys.exit('live base unavailable')
        value = os.environ['LIVE_BASE']
    else:
        assert source == '+refs/pull/9/head'
        value = os.environ.get('FETCHED_PULL_HEAD', os.environ['PR_HEAD'])
    fetched.parent.mkdir(parents=True, exist_ok=True)
    fetched.write_text(value)
elif args[:2] == ['update-ref', '-d']:
    (Path(os.environ['FETCH_FILE']) / args[2]).unlink(missing_ok=True)
elif args == ['rev-parse', 'task^{commit}']:
    print(os.environ.get('LOCAL_TASK_HEAD', os.environ['PR_HEAD']))
elif args[0] == 'rev-parse' and args[1].startswith('refs/fm/fetch/'):
    print((Path(os.environ['FETCH_FILE']) / args[1]).read_text())
elif args == ['rev-parse', os.environ['BASE_NAME'] + '^{commit}']:
    print(os.environ['LOCAL_BASE'])
else:
    sys.exit('unexpected git arguments: ' + repr(args))
PY
chmod +x "$d/stub/gh" "$d/stub/git"
for entry in base view_base head required_checks; do
  invoke() {
    if [ "$entry" = base ]; then
      python3 "$ROOT/bin/lib/fm_binding.py" base --task T-169 --pr 9
    elif [ "$entry" = head ]; then
      python3 "$ROOT/bin/lib/fm_binding.py" head --task T-169 --pr 9 --branch task
    elif [ "$entry" = required_checks ]; then
      PYTHONPATH="$ROOT/bin/lib" python3 -c \
        'import os; from fm_binding import required_checks; print(required_checks(os.environ["FM_TARGET_ROOT"], "owner/project", 9, os.environ["PR_HEAD"])[0]["name"])'
    else
      PYTHONPATH="$ROOT/bin/lib" python3 -c \
        'from fm_binding import view_base; print(view_base("owner/project", 9))'
    fi
  }
  export LOCAL_BASE="$LIVE_BASE" FETCH_FAIL=0
  : > "$FETCH_LOG"
  out="$(invoke 2>&1)"; code=$?
  assert_eq 0 "$code" "$entry accepts synced live base with old recorded OID"
  expected="$BASE_NAME"
  [ "$entry" != head ] || expected="$PR_HEAD"
  [ "$entry" != required_checks ] || expected=ci
  assert_eq "$expected" "$out" "$entry preserves its return contract"
  assert_eq 'exact repository and base ref fetched' "$(cat "$FETCH_LOG" 2>/dev/null)" \
    "$entry fetches the exact base ref once from the PR repository"
  for local_tip in "$OLD_BASE" dddddddddddddddddddddddddddddddddddddddd; do
    export LOCAL_BASE="$local_tip"
    out="$(invoke 2>&1)"; code=$?
    assert_ne 0 "$code" "$entry refuses mismatched local tip $local_tip"
    assert_contains "$out" 'local base is stale; synchronize' "$entry explains stale local base $local_tip"
  done
  # A failed fetch must not reuse the successful fetch's FETCH_HEAD.
  export LOCAL_BASE="$LIVE_BASE" FETCH_FAIL=1
  out="$(invoke 2>&1)"; code=$?
  assert_ne 0 "$code" "$entry fails closed when live tip is unreadable"
  assert_contains "$out" 'live base unavailable' "$entry retains the fetch failure reason"
done
# T-201: a final verdict binds the reviewed head and base name, not the base tip.
review_final() {
  python3 "$ROOT/bin/lib/fm_binding.py" review-final --task T-201 --pr 9 \
    --branch task --head "$PR_HEAD" --base-name "$BASE_NAME"
}
export LOCAL_BASE="$OLD_BASE" FETCH_FAIL=0
: > "$FETCH_LOG"
: > "$VIEW_LOG"
out="$(review_final 2>"$d/final-error")"; code=$?
assert_eq 0 "$code" 'review-final accepts an unchanged head after the live base moves'
assert_eq "$PR_HEAD" "$out" 'review-final prints the reviewed head'
assert_eq '' "$(cat "$FETCH_LOG")" 'review-final never fetches the live base tip'
assert_eq 'pr view' "$(cat "$VIEW_LOG")" 'review-final reads the PR exactly once'
for mode in base head; do
  out="$(python3 "$ROOT/bin/lib/fm_binding.py" "$mode" --task T-201 --pr 9 --branch task 2>&1)"; code=$?
  assert_ne 0 "$code" "$mode still requires a fresh base in the same setup"
  assert_contains "$out" 'local base is stale' "$mode retains its base freshness reason"
done
for control in VIEW_BASE_NAME VIEW_HEAD FETCHED_PULL_HEAD LOCAL_TASK_HEAD PR_STATE; do
  case "$control" in
    VIEW_BASE_NAME) values='other-base'; reason='PR base name differs from reviewed base name' ;;
    VIEW_HEAD) values="$OLD_BASE"; reason='authoritative PR head differs from reviewed head' ;;
    FETCHED_PULL_HEAD) values="$OLD_BASE"; reason='fetched head differs from reviewed head' ;;
    LOCAL_TASK_HEAD) values="$OLD_BASE"; reason='local task ref differs from reviewed head' ;;
    PR_STATE) values='CLOSED MERGED'; reason='PR is not open' ;;
  esac
  for value in $values; do
    export "$control=$value"
    out="$(review_final 2>&1)"; code=$?
    assert_ne 0 "$code" "review-final refuses $control=$value"
    assert_contains "$out" 'fm-binding:' "$control failure comes from binding validation"
    assert_contains "$out" "$reason" "$control failure names the mismatch"
  done
  unset "$control"
done
finish
