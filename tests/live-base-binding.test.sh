#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
mkdir -p "$d/stub" "$d/repo"
export FM_TARGET_ROOT="$d/repo" FM_BINDING_REPOSITORY=owner/project
export FM_GH="$d/stub/gh" PATH="$d/stub:$PATH"
export OLD_BASE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export LIVE_BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export LOCAL_BASE="$LIVE_BASE" BASE_NAME=release/next
export FETCH_FILE="$d/fetched" FETCH_LOG="$d/fetch-log" FETCH_FAIL=0
cat > "$d/stub/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
assert sys.argv[1:] == ['pr', 'view', '9', '--repo', 'owner/project', '--json',
                        'headRefOid,baseRefOid,baseRefName,headRefName,state']
# GitHub's recorded base stays old when only the base branch advances.
print(json.dumps(dict(state='OPEN', headRefOid='c' * 40,
                      baseRefOid=os.environ['OLD_BASE'],
                      baseRefName=os.environ['BASE_NAME'], headRefName='task')))
PY
cat > "$d/stub/git" <<'PY'
#!/usr/bin/env python3
import os, sys
from pathlib import Path
assert sys.argv[1:3] == ['-C', os.environ['FM_TARGET_ROOT']]
args = sys.argv[3:]
if args == ['fetch', '--no-tags', 'https://github.com/owner/project.git',
            'refs/heads/' + os.environ['BASE_NAME']]:
    Path(os.environ['FETCH_LOG']).write_text('exact repository and base ref fetched')
    if os.environ['FETCH_FAIL'] == '1':
        sys.exit('live base unavailable')
    Path(os.environ['FETCH_FILE']).write_text(os.environ['LIVE_BASE'])
elif args == ['rev-parse', 'FETCH_HEAD']:
    print(Path(os.environ['FETCH_FILE']).read_text())
elif args == ['rev-parse', os.environ['BASE_NAME'] + '^{commit}']:
    print(os.environ['LOCAL_BASE'])
else:
    sys.exit('unexpected git arguments: ' + repr(args))
PY
chmod +x "$d/stub/gh" "$d/stub/git"
for entry in base view_base; do
  invoke() {
    if [ "$entry" = base ]; then
      python3 "$ROOT/bin/lib/fm_binding.py" base --task T-169 --pr 9
    else
      PYTHONPATH="$ROOT/bin/lib" python3 -c \
        'from fm_binding import view_base; print(view_base("owner/project", 9))'
    fi
  }
  export LOCAL_BASE="$LIVE_BASE" FETCH_FAIL=0
  out="$(invoke 2>&1)"; code=$?
  assert_eq 0 "$code" "$entry accepts synced live base with old recorded OID"
  assert_eq "$BASE_NAME" "$out" "$entry returns the base branch name"
  assert_eq 'exact repository and base ref fetched' "$(cat "$FETCH_LOG" 2>/dev/null)" \
    "$entry fetches the exact base ref from the PR repository"
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
finish
