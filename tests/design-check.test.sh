#!/usr/bin/env bash
# fm-project.sh: the managed clone of a target and what a target needs
# (design 15.1 and 15.6). Nothing here reaches the network: the clone comes
# from a bare repository standing in for GitHub, and gh is the stub, which
# answers the two API calls verify makes in the shapes GitHub returns.
set -uo pipefail
# a live managed run exports FM_ROOT, FM_PROJECT and friends into this shell;
# the fixture names its engine root and project itself
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*|GHSTATE)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
P="$ROOT/bin/fm-project.sh"

t="$(safe_tmpdir)"
export FM_HOME="$t/fm-home"
eng="$t/engine"
mkdir -p "$eng"
git -C "$eng" init -q -b main
cp -R "$ROOT/.githooks" "$eng/.githooks"
{ printf 'vendor: claude\ndefault_project: self-host\n'
  printf 'projects:\n'
  printf '  self-host:\n    repo: .\n    github: owner-a/engine\n    base: main\n    required_check: ci\n'
  printf '  example-app:\n    github: example-org/example-app\n    base: trunk\n    required_check: check\n'
} > "$eng/config.yaml"

# GitHub, locally: example-org/example-app with a trunk and one other branch
remotes="$t/remotes"
bare="$remotes/example-org/example-app.git"
mkdir -p "$bare"; git init -q --bare -b trunk "$bare"
seed="$t/seed"; git init -q -b trunk "$seed"
git -C "$seed" config user.email a@b.c; git -C "$seed" config user.name t
git -C "$seed" config core.hooksPath /dev/null
echo app > "$seed/app.txt"; git -C "$seed" add -A; git -C "$seed" commit -qm init
git -C "$seed" push -q "$bare" trunk trunk:old-branch

gh="$t/gh"; mkdir -p "$gh"
export GHSTATE="$gh" FM_GH="$ROOT/tests/gh-stub.sh" FM_GITHUB_URL="$remotes"
# run the way a caller does: by path, not through bash, so a lost
# executable bit fails here rather than in the first script that calls it
run() { "$P" "$@" > "$t/out" 2> "$t/err"; printf '%s' "$?"; }
clone="$FM_HOME/projects/example-app/repo"


home="$FM_HOME/projects/example-app"
mkdir -p "$home"
printf 'Original body\r\nwithout final newline' > "$home/design.md"
cp "$home/design.md" "$t/body"
assert_eq 0 "$(run sync example-app --repo "$eng")" "unrecorded design does not block sync"
assert_contains "$(cat "$t/err")" "is not bound to a" "legacy design requests review"
assert_ok "! grep -q design_stale '$eng/state/session/wake.jsonl' 2>/dev/null" "unrecorded design does not wake"
sha="$(git -C "$seed" rev-parse HEAD)"
assert_eq 0 "$(run design-checked example-app --repo "$eng")" "mark binds design"
python3 - "$home" "$sha" "$t/body" <<'PYTEST'
import pathlib,sys
home=pathlib.Path(sys.argv[1]); data=(home/'design.md').read_bytes()
assert data.startswith(('---\nbased_on: '+sys.argv[2]+'\nchecked_at: ').encode())
assert data.split(b'---\n',2)[2] == pathlib.Path(sys.argv[3]).read_bytes()
assert (home/'design.md').stat().st_mode & 0o777 == 0o600
PYTEST
assert_eq 0 "$?" "mark preserves body bytes and private mode"
assert_eq 0 "$(run sync example-app --repo "$eng")" "fresh sync succeeds"
assert_ok "! grep -q design.md '$t/err'" "fresh design stays quiet"
mkdir -p "$seed/src"
echo change > "$seed/src/a.txt"
git -C "$seed" add src/a.txt
git -C "$seed" commit -qm change
git -C "$seed" push -q "$bare" trunk
cp "$home/design.md" "$t/bound"
assert_eq 0 "$(run sync example-app --repo "$eng")" "stale design does not block sync"
assert_contains "$(cat "$t/err")" "may be stale" "sync reports staleness"
assert_contains "$(cat "$t/err")" "1 commits, 1 files" "sync reports change counts"
assert_ok "cmp '$home/design.md' '$t/bound'" "check never edits design"
assert_eq 0 "$(run sync example-app --repo "$eng")" "repeat stale sync succeeds"
python3 - "$home" "$eng" <<'PYTEST'
import json,pathlib,sys
home,engine=map(pathlib.Path,sys.argv[1:])
record=json.loads((home/'state/onboarding/design-check.json').read_text())
assert record['status']=='stale' and record['files']==['src/a.txt']
assert record['files_total']==1 and len(record['commits'])==1
items=[json.loads(line) for line in (engine/'state/session/wake.jsonl').read_text().splitlines()]
assert len(items)==1 and items[0]['reason']=='forwarded'
assert items[0]['origin_reason']=='design_stale' and 'example-app' in items[0]['line']
PYTEST
assert_eq 0 "$?" "stale evidence and one deduplicated engine wake"
# A distinct home avoids sharing the first engine's notified pair.
eng2="$t/engine2"; mkdir -p "$eng2"
git -C "$eng2" init -q
cp -R "$ROOT/.githooks" "$eng2/.githooks"
sed 's/default_project: self-host/default_project: example-app/' "$eng/config.yaml" > "$eng2/config.yaml"
(
 export FM_HOME="$t/home2" FM_PROJECT=example-app FM_EXTERNAL=1
 h="$FM_HOME/projects/example-app"; mkdir -p "$h"; cp "$t/bound" "$h/design.md"
 assert_eq 0 "$(run sync example-app --repo "$eng2")" "external default sync succeeds"
 python3 - "$eng2" "$h" <<'PYTEST'
import json,pathlib,sys
engine,home=map(pathlib.Path,sys.argv[1:])
items=[json.loads(line) for line in (engine/'state/session/wake.jsonl').read_text().splitlines()]
assert len(items)==1 and items[0]['reason']=='forwarded' and items[0]['origin_reason']=='design_stale'
assert 'example-app' in items[0]['line']
assert not (home/'state/session/wake.jsonl').exists()
PYTEST
 assert_eq 0 "$?" "external routing still wakes only the engine"
 finish
)
assert_eq 0 "$?" "second engine routing fixture passes"
assert_eq 0 "$(run design-checked example-app --repo "$eng")" "review rebinds stale design"
assert_eq 0 "$(run sync example-app --repo "$eng")" "rebound sync succeeds"
assert_ok "! grep -q design.md '$t/err'" "rebound design stays quiet"
printf '%s\n' --- "based_on: 1111111111111111111111111111111111111111" "checked_at: old" --- body > "$home/design.md"
assert_eq 0 "$(run sync example-app --repo "$eng")" "rewritten history does not block sync"
assert_contains "$(cat "$t/err")" "not in the clone's history" "missing binding commit explained"
rm "$home/design.md"
assert_eq 65 "$(run design-checked example-app --repo "$eng")" "mark refuses absent design"
ln -s "$t/body" "$home/design.md"
assert_eq 65 "$(run sync example-app --repo "$eng")" "registry refuses symlink design"
assert_contains "$(cat "$t/err")" symlink "registry explains refusal"
python3 "$ROOT/bin/lib/fm_design_check.py" check --engine "$eng" --name example-app --home "$home" --base trunk 2> "$t/err"
assert_eq 0 "$?" "direct check safely ignores symlink"
assert_contains "$(cat "$t/err")" "refusing symlink" "direct check explains refusal"
# Boundary cases use bounded git stubs, with real private-file persistence.
python3 - "$ROOT" "$t" <<'PYTEST'
import argparse, json, pathlib, subprocess, sys
from unittest.mock import patch
sys.dont_write_bytecode=True
sys.path.insert(0,str(pathlib.Path(sys.argv[1])/'bin/lib'))
import fm_design_check as D
home=pathlib.Path(sys.argv[2])/'unit-home'; home.mkdir()
args=argparse.Namespace(home=str(home),engine=str(home/'engine'),name='example-app',base='trunk')
design=home/'design.md'
old='a'*40; origin='b'*40
body=b'---\r\nother: retain exactly  \r\nbased_on: '+old.encode()+b'\r\nchecked_at: old\r\n---\r\nBody\r\nno final newline'
design.write_bytes(body)
with patch.object(D,'git',return_value=origin), patch.object(D,'forward') as wake:
    D.mark(args)
    result=design.read_bytes()
    assert b'other: retain exactly  \r\n' in result
    assert result.split(b'---\r\n',2)[2]==body.split(b'---\r\n',2)[2]
    assert b'based_on: '+origin.encode()+b'\r\n' in result
    assert not wake.called
design.write_text('---\nbased_on: '+old+'\nchecked_at: old\n---\nbody')
def git(home,*command):
    if command[0]=='rev-parse': return origin
    if command[0]=='cat-file': return ''
    if command[0]=='log': return '\n'.join('commit '+str(i) for i in range(20))
    return '\n'.join('file '+str(i) for i in range(55))
with patch.object(D,'git',side_effect=git), patch.object(D,'forward') as wake:
    D.check(args)
    data=json.loads((home/'state/onboarding/design-check.json').read_text())
    assert len(data['files'])==50 and data['files_total']==55
    assert len(data['commits'])==20 and wake.call_count==1
    D.check(args)
    assert wake.call_count==1
# Every subprocess invocation is bounded and detached from input.
with patch.object(D.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=origin)) as run:
    assert D.git(home,'rev-parse','ref')==origin
    assert run.call_args.args[0][:3]==['git','-C',str(home/'repo')]
    assert run.call_args.kwargs['timeout']==30
    assert run.call_args.kwargs['stdin']==subprocess.DEVNULL
# CLI check treats unreadable git as unknown and does not emit a wake.
with patch.object(sys,'argv',['design-check','check','--engine',args.engine,'--home',args.home,'--name',args.name,'--base',args.base]), patch.object(D,'git',side_effect=subprocess.TimeoutExpired('git',30)), patch.object(D,'forward') as wake:
    assert D.main()==0 and not wake.called
PYTEST
assert_eq 0 "$?" "front matter preservation, bounded evidence and unknown git behavior"
finish
