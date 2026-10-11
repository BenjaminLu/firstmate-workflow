"""Exercise the production shell functions in disposable git trees."""
from pathlib import Path
import subprocess
import sys
root, tmp = map(Path, sys.argv[1:])

def function(path, name):
    text = path.read_text()
    start = text.index(name + '() {')
    return text[start:text.index('\n}', start) + 2]

def shell(body):
    subprocess.run(['bash', '-euc', body], check=True)

repo = tmp / 'rebuild'
repo.mkdir()
shell(f'''git -C '{repo}' init -q -b main
git -C '{repo}' config user.name Fixture
git -C '{repo}' config user.email fixture@example.invalid
mkdir -p '{repo}/design/tasks'
printf 'base\\n' > '{repo}/design/tasks/T-Z.json'
git -C '{repo}' add .
git -C '{repo}' commit -qm base
''')
rebuild_repo = repo
repo = tmp / 'migration'
repo.mkdir()
shell(f'''git -C '{repo}' init -q -b main
git -C '{repo}' config user.name Fixture
git -C '{repo}' config user.email fixture@example.invalid
mkdir -p '{repo}/design/tasks'
printf 'own base bytes\\n' > '{repo}/design/tasks/T-Z.json'
git -C '{repo}' add .
git -C '{repo}' commit -qm base
''')
worker = root / 'bin/fm-worker.sh'
# Both publication modes must restore staged deletions, but not old Landing deletions.
shell(f'''
{function(worker, 'self_specs_unstage')}
FM_EXTERNAL=0; TASK=T-Z; tree='{repo}'; BASE=HEAD; rebuilt=0
printf 'other base bytes\\n' > "$tree/design/tasks/T-OTHER.json"
git -C "$tree" add design/tasks/T-OTHER.json
git -C "$tree" commit -qm 'tracked other spec'
base=$(git -C "$tree" rev-parse HEAD)
for mode in normal rebuild; do
  rebuilt=0; rebuild_base=''
  if [ "$mode" = rebuild ]; then rebuilt=1; rebuild_base="$base"; fi
  rebuild_specs_checked=1
  git -C "$tree" rm --cached -q design/tasks/T-OTHER.json
  self_specs_unstage
  test "$(git -C "$tree" show :design/tasks/T-OTHER.json)" = 'other base bytes' || {{ echo "$mode staged deletion not restored"; exit 1; }}
  test "$(cat "$tree/design/tasks/T-OTHER.json")" = 'other base bytes' || {{ echo "$mode disk bytes not restored"; exit 1; }}
done
git -C "$tree" rm --cached -q design/tasks/T-OTHER.json
git -C "$tree" commit -qm 'Landing deletion'
self_specs_unstage
test -z "$(git -C "$tree" ls-files -- design/tasks/T-OTHER.json)" || {{ echo 'committed Landing deletion restored'; exit 1; }}
''')
# Extract the EXIT publisher, using a fixture checkpoint with the same staging step.
# No production checkpoint or remote service is invoked; the remote is a local bare tree.
checkpoint = tmp / 'checkpoint-code'
(checkpoint / 'bin').mkdir(parents=True)
(checkpoint / 'bin/fm-checkpoint.sh').write_text('''#!/usr/bin/env bash
set -eu
tree="$2"
git -C "$tree" add -A
git -C "$tree" commit -qm "$4"
git -C "$tree" push -q origin HEAD
''')
(checkpoint / 'bin/fm-checkpoint.sh').chmod(0o755)
ignore = tmp / 'user-ignore'
ignore.write_text('.DS_Store\n')
shell(f'''
scratch_new() {{ mktemp "$worker_tmp/fm-worker-XXXXXX"; }}
scratch_add() {{ scratch+=("$1"); }}
fm_git_transfer() {{ "$@"; }}
{function(worker, 'self_specs_unstage')}
{function(worker, 'publish_wip_if_dirty')}
FM_EXTERNAL=0; TASK=T-Z; tree='{repo}'; REPO='{repo}'; BASE=HEAD
FM_CODE_ROOT='{checkpoint}'; worker_tmp='{tmp}'; scratch=()
_fm_wip_done=0; rebuilt=0; pinned_path=''; PR=''
fm_publication_policy() {{ :; }}
emit() {{ :; }}
git -C "$tree" init --bare -q '{tmp}/checkpoint-remote.git'
git -C "$tree" remote add origin '{tmp}/checkpoint-remote.git'
git -C "$tree" switch -qc t-z
# Simulate an older task branch that still tracks its own spec and has no ignore rule.
git -C "$tree" add -f design/tasks/T-Z.json
git -C "$tree" commit -qm 'legacy tracked own spec'
git -C "$tree" push -qu origin HEAD
branch=$(git -C "$tree" symbolic-ref --short HEAD)
git -C "$tree" config core.excludesFile '{ignore}'
printf 'implementation\\n' > "$tree/feature"
printf 'ignored user file\\n' > "$tree/.DS_Store"
# Preserve a caller's existing command-scope settings as well as user ignores.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=test.retained GIT_CONFIG_VALUE_0=yes
publish_wip_if_dirty interrupted || {{ echo 'EXIT checkpoint must return zero'; exit 1; }}
test -z "$(git -C "$tree" ls-tree --name-only HEAD -- design/tasks/T-Z.json)" || {{ echo 'EXIT checkpoint re-staged own spec'; exit 1; }}
test -z "$(git -C "$tree" ls-tree --name-only HEAD -- .DS_Store)" || {{ echo 'EXIT checkpoint lost user ignores'; exit 1; }}
test "$(git -C "$tree" config test.retained)" = yes
test "$GIT_CONFIG_COUNT" = 1
test "$(git --git-dir='{tmp}/checkpoint-remote.git' rev-parse refs/heads/$branch)" = "$(git -C "$tree" rev-parse HEAD)"
rm -f "${{scratch[@]}}"
''')
repo = rebuild_repo
pin = tmp / 'pinned-spec'
pin.write_text('pinned bytes\n\n')
worker = root / 'bin/fm-worker.sh'
shell(f'''
{function(worker, 'rebuild_own_file_restore')}
{function(worker, 'rebuild_lost')}
FM_EXTERNAL=0; TASK=T-Z; tree='{repo}'; pinned_path=design/tasks/T-Z.json
pinned_bytes='{pin}'; pinned_ready=1; rebuild_entry=''
pin_read_bytes() {{ :; }}
# Construct the same unmerged index entries as an own modify/delete conflict.
blob=$(git -C "$tree" rev-parse HEAD:design/tasks/T-Z.json)
git -C "$tree" update-index --force-remove design/tasks/T-Z.json
printf '100644 %s 1\\tdesign/tasks/T-Z.json\\n100644 %s 3\\tdesign/tasks/T-Z.json\\n' "$blob" "$blob" | git -C "$tree" update-index --index-info
rebuild_own_file_restore HEAD
cmp "$pinned_bytes" "$tree/$pinned_path"
test -z "$(git -C "$tree" ls-files -- design/tasks/T-Z.json)"
test -z "$(rebuild_lost index)"
''')
