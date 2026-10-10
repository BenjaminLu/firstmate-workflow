#!/usr/bin/env bash
# The retrospective's privacy rule (T-273), end to end with a sentinel. A
# made-up external project's sentinel name goes through every stage: its
# metrics and stop records, its round's items and generic statements, the
# cross-project round, the card, the card's archival, an approved external
# item's claim and proposal, and a firstmate item's proposal. It may then be
# found in that project's private state and in the two local exceptions -
# the card's own records and the run's private/labels.json - and nowhere
# else: no other self state/retro file, no cross-project prompt, no card
# diagram, no self proposal, nothing under design/ or tests/.
# The rounds are a stub launcher that answers as a reviewer would; nothing
# here reaches a model. Without bin/lib/fm_retro.py the case prints SKIP.
# Feature dependencies: bin/lib/fm_retro.py bin/fm-retro.sh bin/fm-decide.sh
set -uo pipefail
for _fm_k in $(env | sed -E -n 's/^(FM_[^=]*|HERDR_[^=]*)=.*$/\1/p'); do
  unset "$_fm_k" || true
done
export HERDR_ENV=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
if [ ! -f "$ROOT/bin/lib/fm_retro.py" ] || [ ! -f "$ROOT/bin/fm-retro.sh" ]; then
  printf '    %-52sSKIP (not evidence: bin/lib/fm_retro.py is absent)\n' 'retro privacy sentinel'
  finish; exit 0
fi
d="$(safe_tmpdir)"
trap 'safe_rm_rf "$d"' EXIT
python3 - "$ROOT" "$d" > "$d/result" 2>&1 <<'PY'
import json, os, re, shutil, subprocess, sys, time
from pathlib import Path
root, tmp = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
# built at run time, so this file never holds the sentinel itself
SENTINEL = 'sentinel' + 'wombat'
OWNER = 'sentinel' + 'corp'
engine, home = tmp / 'engine', tmp / 'home'
for part in ('bin', 'i18n', 'board'):
    shutil.copytree(root / part, engine / part, ignore=shutil.ignore_patterns('diagrams'))
(engine / 'state').mkdir(parents=True)
(engine / 'design/tasks').mkdir(parents=True)
home.mkdir()
(engine / 'config.yaml').write_text(f'''home: {home}
retro:
  vendor: claude
  model: claude-opus-5-5
default_project: selfproj
projects:
  selfproj:
    repo: .
    github: owner/selfproj
    base: main
    required_check: ci
  {SENTINEL}:
    github: {OWNER}/{SENTINEL}
    base: main
    required_check: ci
''')
git = lambda *a: subprocess.run(['git', '-C', str(engine), *a], capture_output=True, check=True)
git('init', '-q', '-b', 'main'); git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'init')
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
private = home / 'projects' / SENTINEL / 'state'
(private).mkdir(parents=True)
(home / 'projects' / SENTINEL / 'tasks').mkdir(parents=True)
now = time.time()
stamp = lambda t: time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))
(private / 'events.jsonl').write_text(json.dumps(dict(ts=stamp(now - 600), type='merged', task='T-5', pr=3, actor='captain')) + '\n')
(home / 'projects' / SENTINEL / 'tasks/T-5.json').write_text(json.dumps(dict(id='T-5', title=SENTINEL + ' ledger sync', acceptance=['Pay ' + SENTINEL])))
sys.path.insert(0, str(engine / 'bin/lib'))
from fm_evidence import Store
Store(str(private), SENTINEL, 'T-5', external=True).append('ask', 1, 'worker-x', 'a' * 40, 'ASK-' + SENTINEL.upper() + ':T-5 which owner?')
(engine / 'state/events.jsonl').write_text(json.dumps(dict(ts=stamp(now - 600), type='merged', task='T-1', pr=8, actor='captain')) + '\n')
(engine / 'state/retro').mkdir(parents=True)
(engine / 'state/retro/index.json').write_text(json.dumps(dict(schema=1, baseline_at=stamp(now - 9 * 86400), last_completed=None, open_run=None)))

def item(n, text):
    loc = lambda lang: dict(title=text, why='Another suite covers the same checks.', how='Remove the file.', evidence=['tests/a.sh:1'], scope=[])
    return dict(id=f'R{n}', kind='cleanup', carried_from=None, effect='removes', removes=['tests/old.test.sh'], en=loc('en'), **{'zh-TW': loc('zh-TW')})
answers = tmp / 'answers'; answers.mkdir()
def answer(name, items, generic=()):
    (answers / f'{name}.md').write_text(f'Report about {SENTINEL}.\n```retro-items\n' + json.dumps(dict(schema=1, items=items, generic=list(generic))) + '\n```\nREVIEWER_COMPLETE:retro\n')
answer(SENTINEL, [item(1, f'Trim the {SENTINEL} flow.')], [f'Rounds repeat for {SENTINEL}.', 'Rounds repeat.'])
answer('selfproj', [item(1, 'Delete the old suite.')])
answer('cross', [item(1, 'Merge two checks.'), item(2, f'Copy {SENTINEL} rules.')])
# The stub round keeps its raw answer where the real transport does - the
# round's run directory, state/runs/<actor>/ in the self tree for a self or
# cross round - and then hands over exactly as bin/lib/fm-retro-review.sh
# does: accept with --run-dir, then release with --contain at its exit.
stub = tmp / 'round.py'
stub.write_text(f'''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]; run = args[args.index('--retro') + 1]; repo = args[args.index('--repo') + 1]
cross = '--retro-cross' in args; project = '' if cross else args[args.index('--project') + 1]
name = 'cross' if cross else project
answer = open({str(answers)!r} + '/' + name + '.md').read()
own = name in ('cross', 'selfproj')
runs = (repo + '/state/runs/') if own else ({str(private)!r} + '/runs/')
run_dir = runs + 'reviewer-stub-' + name + '-' + run
os.makedirs(run_dir + '/attempts/1', exist_ok=True)
for file in ('cli.log', 'final.txt'):
    open(run_dir + '/attempts/1/' + file, 'w').write(answer)
lib = repo + '/bin/lib/fm_retro.py'
cmd = ['python3', lib, 'accept', '--engine', repo, '--run', run, '--answer-file', {str(answers)!r} + '/' + name + '.md']
rc = subprocess.run(cmd + (['--cross'] if cross else ['--project', project]) + (['--run-dir', run_dir] if own else [])).returncode
subprocess.run(['python3', lib, 'release', '--engine', repo, '--run-dir', run_dir] + (['--contain'] if own else []), stdout=subprocess.DEVNULL)
sys.exit(rc)
''')
stub.chmod(0o755)
gh = tmp / 'gh'; gh.write_text('#!/bin/sh\nexit 1\n'); gh.chmod(0o755)
# every temporary file of every stage lands here, and is searched at the end
scratch = tmp / 'scratch'; scratch.mkdir()
env.update(FM_RETRO_ROUND=str(stub), FM_GH=str(gh), TMPDIR=str(scratch))
def retro(*args):
    result = subprocess.run(['bash', str(engine / 'bin/fm-retro.sh'), *args], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return result
def ok(name, condition):
    print(('ok' if condition else 'FAIL') + '\t' + name)

first = json.loads(retro('run').stdout.strip().splitlines()[-1])
ok('a retro with the sentinel project reaches reviewed', first['state'] == 'reviewed')
run1 = first['run_id']
ok('the card is raised', retro('card', '--run', run1).returncode == 0)
card1 = json.loads((engine / 'state/retro' / run1 / 'card.json').read_text())['id']
archive = engine / 'state/runtime/archived-pending'; archive.mkdir(parents=True)
(engine / 'state/pending' / f'{card1}.json').rename(archive / f'{card1}.json')
retro('status')
ok('an archived card fails its run', json.loads((engine / 'state/retro' / run1 / 'state.json').read_text())['failure'] == 'card archived')
second = json.loads(retro('run').stdout.strip().splitlines()[-1])
run2 = second['run_id']
ok('the retry reaches reviewed', second['state'] == 'reviewed')
ok('its card is raised', retro('card', '--run', run2).returncode == 0)
card2 = json.loads((engine / 'state/retro' / run2 / 'card.json').read_text())['id']
pending = json.loads((engine / 'state/pending' / f'{card2}.json').read_text())
ok('the card shows the external item text', SENTINEL in json.dumps(pending['details']))
ids = [i['id'] for i in pending['details']['en']['items']]
(engine / 'state/decisions' ).mkdir(exist_ok=True)
(engine / 'state/decisions' / f'{card2}.json').write_text(json.dumps(dict(pending, chosen='A', item_answers=[dict(index=i, id=x, choice='A') for i, x in enumerate(ids)])))
(engine / 'state/pending' / f'{card2}.json').unlink()
ok('the answer is recorded', retro('record', '--run', run2).returncode == 0)
external = next(x for x in ids if x.startswith('P-'))
claimed = json.loads(retro('claim', '--run', run2, '--item', external).stdout)
Path(claimed['draft']).parent.mkdir(parents=True, exist_ok=True)
Path(claimed['draft']).write_text(json.dumps(dict(title=f'{SENTINEL} proposal')))
ok('the external item links in its own project', retro('link', '--run', run2, '--item', external, '--task', 'T-51').returncode == 0)
mine = json.loads(retro('claim', '--run', run2, '--item', 'firstmate/R1').stdout)
(engine / mine['draft']).write_text(json.dumps(dict(id='T-90', title='Merge two checks.')))
ok('the firstmate item links', retro('link', '--run', run2, '--item', 'firstmate/R1', '--task', 'T-90').returncode == 0)
allowed = {f'state/pending/{card1}.json', f'state/decisions/{card2}.json', f'state/runtime/archived-pending/{card1}.json',
           f'state/retro/{run1}/private/labels.json', f'state/retro/{run2}/private/labels.json', 'config.yaml'}
found = sorted(str(p.relative_to(engine)) for p in engine.rglob('*')
               if p.is_file() and '.git' not in p.parts and SENTINEL in p.read_text(errors='ignore').lower())
ok('the sentinel appears only in the card records and labels', set(found) <= allowed)
print('\tfound: ' + ', '.join(found))
ok('the card records do hold it', f'state/decisions/{card2}.json' in found and f'state/runtime/archived-pending/{card1}.json' in found)
cross = (engine / 'state/retro' / run2 / 'cross/prompt.txt').read_text()
ok('the cross-project prompt never holds it', SENTINEL not in cross.lower() and OWNER not in cross.lower())
refused = json.loads((engine / 'state/retro' / run2 / 'cross/refused.json').read_text())['refused']
ok('its generic statement is dropped and recorded as refused', len(refused) == 1 and refused[0]['refused'] is True)
diagrams = list((engine / 'board/public/diagrams').glob(f'{card2}*'))
ok('the card diagram exists and does not hold it', diagrams and all(SENTINEL not in p.read_text().lower() for p in diagrams))
ok('the self proposal manifest holds only its status',
   json.loads((engine / 'state/retro' / run2 / 'proposals' / (external.replace('/', '-') + '.json')).read_text()) == dict(status='linked'))
stores = [p for p in private.rglob('*') if p.is_file() and SENTINEL in p.read_text(errors='ignore').lower()]
names = {p.name for p in stores}
ok('its private state keeps its prompt, report, items and draft', {'prompt.txt', 'report.md', 'items.json'} <= names
   and any(p.parent.name == 'drafts' for p in stores))
temporary = [str(p) for p in scratch.rglob('*') if p.is_file() and SENTINEL in p.read_text(errors='ignore').lower()]
ok('no temporary file of any stage holds it', not temporary)
transport = sorted(engine.glob('state/runs/reviewer-stub-*/attempts/1/*'))
ok('the self and cross rounds kept their transport copies', len(transport) >= 4)
ok('and those copies do not hold it', all(SENTINEL not in p.read_text().lower() for p in transport))
ok('its own round keeps its raw answer in its private state', any(SENTINEL in p.read_text().lower()
   for p in private.glob('runs/reviewer-stub-*/attempts/1/final.txt')))
for top in ('design', 'tests'):
    leaked = [str(p) for p in (root / top).rglob('*') if p.is_file() and SENTINEL in p.read_text(errors='ignore').lower()]
    ok('nothing under ' + top + '/ holds it', not leaked)
PY
rc=$?
while IFS=$'\t' read -r verdict name; do
  case "$verdict" in
    ok) assert_eq ok ok "$name" ;;
    FAIL) assert_eq ok FAIL "$name" ;;
    '') printf '      %s\n' "$name" ;;
    *) printf '      %s\t%s\n' "$verdict" "$name" ;;
  esac
done < "$d/result"
assert_eq 0 "$rc" 'the sentinel walk ran to the end'
finish
