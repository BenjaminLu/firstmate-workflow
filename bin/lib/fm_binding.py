"""Outside-round source and GitHub bindings. Unknown evidence fails closed."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid


def gate_list():
    """The frozen code snapshot supplies identities for all gate readers."""
    try:
        return json.loads(Path(__file__).with_name('fm_gates.json').read_text())
    except (OSError, ValueError) as error:
        raise ValueError('gate list unavailable: bin/lib/fm_gates.json') from error


def gate_entry(value, mapping):
    name = mapping['legacy'].get(str(value)) if type(value) is int else value
    return next((gate for gate in mapping['gates'] if gate['name'] == name), None)


def command(argv, cwd=None):
    result = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError('binding command failed: ' + result.stderr.decode(errors='replace')[:500])
    return result.stdout


def git(root, *args):
    return command(['git', '-C', str(root), *args]).decode().strip()


def fetch_ref(root, url, source, *, runner=None):
    """Read one fetch through a private ref, including when reviews overlap."""
    run = command if runner is None else runner
    prefix = ['git', '-C', str(root)]
    ref = 'refs/fm/fetch/' + str(os.getpid()) + '-' + uuid.uuid4().hex
    try:
        run([*prefix, 'fetch', '--no-tags', url, '+' + source + ':' + ref])
        value = run([*prefix, 'rev-parse', ref])
        return sha((value.decode() if isinstance(value, bytes) else value).strip())
    finally:
        run([*prefix, 'update-ref', '-d', ref])


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', value):
        raise ValueError('missing or invalid full head SHA')
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def change(root, head, base):
    sha(head); sha(base)
    git(root, 'merge-base', '--is-ancestor', base, head)
    diff = command(['git', '-C', str(root), 'diff-tree', '-r', '-p', '--no-renames', base, head])
    patch = subprocess.run(['git', 'patch-id', '--stable'], input=diff, capture_output=True, check=True).stdout.decode().split()
    files = command(['git', '-C', str(root), 'diff-tree', '-r', '--name-only', '-z', '--no-renames', base, head]).decode().split('\0')
    return dict(head=head, base=base, patch=patch[0] if patch else '', files=[f for f in files if f])


def source_binding(task, head, base, code):
    root = Path(os.environ['FM_TARGET_ROOT'])
    result = change(root, head, base)
    external = os.environ.get('FM_EXTERNAL') == '1'
    from fm_spec_pins import Pins
    env = dict(os.environ)
    if not external:
        env.update(FM_ENGINE_ROOT=str(root), FM_STATE_DIR=str(root / 'state'),
                   FM_TASKS_DIR=str(root / 'design/tasks'), FM_DESIGN=str(root / 'design/design.md'))
    env.setdefault('FM_ENGINE_ROOT', str(code))
    env.setdefault('FM_DESIGN', str(Path(env['FM_STATE_DIR']).parent / 'design.md'))
    pin = Pins(env, task).resolve(if_present=True)
    if pin is not None:
        # Gate policy and signed review evidence bind the same approved bytes.
        # A corrupt pin never falls back to the branch or mutable private data.
        spec, contract, conventions = (pin['snapshots'][key]['text'].encode('utf-8')
                                       for key in ('spec', 'contract', 'conventions'))
    elif external:
        spec = (Path(os.environ['FM_TASKS_DIR']) / (task + '.json')).read_bytes()
        contract = (Path(os.environ['FM_STATE_DIR']) / 'config.yaml').read_bytes()
        conventions = (Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md').read_bytes()
    else:
        # SK proposals are adopted into design/tasks by fm self-update --adopt,
        # then committed on the task branch just like T tasks. Never fall back
        # to a mutable state/skill-updates proposal or omit the spec hash.
        try:
            spec = command(['git', '-C', str(root), 'show', head + ':design/tasks/' + task + '.json'])
        except ValueError as error:
            raise ValueError('approved committed task spec required: design/tasks/' + task + '.json') from error
        if json.loads(spec).get('id') != task:
            raise ValueError('committed task spec identity mismatch')
        contract = command(['git', '-C', str(root), 'show', head + ':config.yaml'])
        conventions = b''
    engine = hashlib.sha256()
    for path in sorted((Path(code) / 'bin').rglob('*')):
        if path.is_file() and not path.is_symlink() and '__pycache__' not in path.parts:
            engine.update(str(path.relative_to(code)).encode() + b'\0' + hashlib.sha256(path.read_bytes()).digest())
    result.update(spec_sha256=digest(spec), contract_sha256=digest(contract),
                  conventions_sha256=digest(conventions), engine_sha256=engine.hexdigest())
    return result


def github(repository, *args):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('verified repository identity required')
    return json.loads(command([os.environ.get('FM_GH', 'gh'), *args]))


def remote_head(repository, pr):
    view = github(repository, 'pr', 'view', str(pr), '--repo', repository,
                  '--json', 'headRefOid,baseRefOid,baseRefName,headRefName,state')
    if view.get('state') != 'OPEN':
        raise ValueError('PR is not open')
    sha(view.get('headRefOid'))
    sha(view.get('baseRefOid'))
    return view


def authoritative(root, branch, repository, pr):
    view = remote_head(repository, pr)
    head = view['headRefOid']
    # Fetch the actual PR ref, never a caller-supplied remote/branch expression.
    if not re.fullmatch(r'[1-9][0-9]*', str(pr)):
        raise ValueError('invalid PR number')
    fetched = fetch_ref(root, 'https://github.com/' + repository + '.git',
                        'refs/pull/' + str(pr) + '/head')
    if fetched != head or git(root, 'rev-parse', branch + '^{commit}') != head:
        raise ValueError('authoritative PR head differs from fetched head or local task ref; refresh before accepting')
    verified_base(view, repository, root)
    now = remote_head(repository, pr)
    if any(now.get(key) != view.get(key) for key in ('headRefOid', 'baseRefOid', 'baseRefName')):
        raise ValueError('PR head/base moved while verifying')
    return head


def review_final(root, branch, repository, pr, head, base_name):
    """Retain a verdict for this head even when its base branch has advanced."""
    head = sha(head)
    view = remote_head(repository, pr)
    name = view['baseRefName']
    if not isinstance(name, str) or not name or name.startswith('-'):
        raise ValueError('invalid authoritative base name')
    if name != base_name:
        raise ValueError('PR base name differs from reviewed base name')
    if view['headRefOid'] != head:
        raise ValueError('authoritative PR head differs from reviewed head')
    if not re.fullmatch(r'[1-9][0-9]*', str(pr)):
        raise ValueError('invalid PR number')
    fetched = fetch_ref(root, 'https://github.com/' + repository + '.git',
                        'refs/pull/' + str(pr) + '/head')
    if fetched != head:
        raise ValueError('fetched head differs from reviewed head')
    if git(root, 'rev-parse', branch + '^{commit}') != head:
        raise ValueError('local task ref differs from reviewed head')
    return head


def required_checks(root, repository, pr, head, *, task=None):
    from fm_project_checks import status_runs
    import fm_adopt
    adopt = fm_adopt.adoption(os.environ, task)
    view = remote_head(repository, pr)
    if adopt:
        fm_adopt.base_matches(view, adopt)
    if view['headRefOid'] != head:
        raise ValueError('checks belong to stale head')
    verified_base(view, repository, root)
    from urllib.parse import quote
    from fm_conventions import read_policy
    external = os.environ.get('FM_EXTERNAL') == '1'
    policy_path = (Path(os.environ['FM_STATE_DIR']).parent if external else Path(root)) / 'CONVENTIONS.md'
    policy = None
    try:
        policy = read_policy(policy_path, repository, (os.environ.get('FM_BASE') or 'main') if external else None)
    except (ValueError, OSError) as error:
        if external:
            raise ValueError('required checks unknown: captain-confirmed checks and policy required: ' + str(error)) from error
    if policy and not adopt and view['baseRefName'] != policy['base'] and policy['stacking'] != 'allowed':
        raise ValueError('required checks unknown: stacked PR base requires confirmed stacking policy')
    try:
        protection = github(repository, 'api', 'repos/' + repository + '/branches/' + quote(view['baseRefName'], safe='') + '/protection/required_status_checks')
        names = set(protection.get('contexts', []) + [c['context'] for c in protection.get('checks', [])])
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if policy is None:
            raise ValueError('required checks unknown: unreadable protection; require captain-confirmed checks and policy') from error
        names = set()
    if policy:
        names.update(policy['required_checks'])
        names.update(policy.get('analysers', []))
    if not names:
        raise ValueError('required checks unknown: no confirmed names')
    try:
        payload = github(repository, 'api', 'repos/' + repository + '/commits/' + head + '/check-runs?per_page=100')
        runs = payload['check_runs']
        statuses = github(repository, 'api', 'repos/' + repository + '/commits/' + head + '/status?per_page=100')
        if payload.get('total_count', len(runs)) > len(runs) or len(runs) >= 100 or len(statuses.get('statuses', [])) >= 100:
            raise ValueError('complete check/status history unavailable')
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise ValueError('required checks unknown: ' + str(error)) from error
    if statuses.get('sha') != head:
        raise ValueError('commit statuses belong to another head')
    runs += status_runs(statuses, head)
    results = []
    for name in sorted(names):
        matches = [r for r in runs if r.get('name') == name and r.get('head_sha') == head]
        # A context present in both APIs must pass in both; neither hides red.
        for source in ('check run', 'commit status'):
            subset = [r for r in matches if r.get('source', 'check run') == source]
            if subset:
                latest = max(subset, key=lambda r: r.get('id', 0))
                if latest.get('status') != 'completed':
                    raise ValueError('required check/status pending: ' + name)
                if latest.get('conclusion') not in ('success', 'neutral', 'skipped'):
                    raise ValueError('required check/status failed: ' + name)
                results.append(latest)
        if not matches:
            raise ValueError('required check/status pending (missing): ' + name)
    now = remote_head(repository, pr)
    if any(now.get(key) != view.get(key) for key in ('headRefOid', 'baseRefOid', 'baseRefName')):
        raise ValueError('PR head/base moved while reading checks')
    return results


def repository(root):
    configured = os.environ.get('FM_BINDING_REPOSITORY') or os.environ.get('GH_REPO')
    if configured:
        return configured
    remote = git(root, 'config', '--get', 'remote.origin.url')
    match = re.fullmatch(r'(?:https://github.com/|git@github.com:)([^/]+/[^/]+?)(?:\.git)?', remote)
    if not match:
        raise ValueError('cannot identify authoritative GitHub repository')
    return match[1]


def review_policy():
    if os.environ.get('FM_EXTERNAL') != '1':
        return 'fm'
    from fm_conventions import read_policy
    return read_policy(Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md')['review']


def external_review(store, root, repo, pr, head):
    """All named reviewers and their threads, separately from local fm finals."""
    from fm_conventions import read_policy
    from fm_external import collect
    policy = read_policy(Path(os.environ['FM_STATE_DIR']).parent / 'CONVENTIONS.md', repo)
    record = collect(store, root, repo, pr, head, policy)
    if not record['ready']:
        raise ValueError('external review not ready: ' + '; '.join(record['blockers']))
    return record


def review_identity(record):
    # Full receipts remain signed and verified by Store. Only external evidence
    # uses a decisive subset for readiness; fm final provenance is unchanged.
    if record.get('kind') == 'external-verdict':
        return record.get('readiness_signature', record['signature'])
    return record['signature']


def selected_review(store, root, repo, pr, head):
    policy = review_policy()
    external = external_review(store, root, repo, pr, head) if policy in ('external', 'both') else None
    if policy == 'external':
        return external, external
    records = store.verdicts()
    if not records or records[-1]['verdict'] != 'APPROVE':
        raise ValueError('no current local approval')
    return records[-1], external


def view_base(repo, pr):
    return verified_base(remote_head(repo, pr), repo)


def verified_base(view, repo=None, root=None):
    name = view['baseRefName']
    if not name or name.startswith('-'):
        raise ValueError('invalid authoritative base')
    root = root if root is not None else os.environ['FM_TARGET_ROOT']
    repo = repo or repository(root)
    # The PR's recorded base OID may lag behind its base branch's live tip.
    live_base = fetch_ref(root, 'https://github.com/' + repo + '.git', 'refs/heads/' + name)
    if git(root, 'rev-parse', name + '^{commit}') != live_base:
        raise ValueError('local base is stale; synchronize before accepting')
    return name


def local_gate_base(root, pr, project_base):
    # Individual local gates also work before a PR exists, or without an
    # origin. Full runs and gate 5 keep the strict authoritative binding.
    try:
        repo = repository(root)
        view = remote_head(repo, pr)
    except ValueError:
        return project_base
    if view['baseRefName'] == project_base:
        return project_base
    # Once a stacked PR is known, a stale parent must not fall back to main.
    return verified_base(view, repo)


def verify_current(root, repo, pr, head, base_tip):
    """Last remote read before retaining or accepting readiness."""
    view = remote_head(repo, pr)
    if view['headRefOid'] != head:
        raise ValueError('PR head/base moved; readiness is stale')
    name = verified_base(view, repo, root)
    if git(root, 'rev-parse', name + '^{commit}') != base_tip:
        raise ValueError('local base moved; readiness is stale')


def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['base', 'local-gate-base', 'head', 'checks', 'ready', 'candidate', 'external-review', 'review-final'])
    p.add_argument('--project-base', default='main')
    p.add_argument('--task', required=True)
    p.add_argument('--pr', required=True)
    p.add_argument('--branch', default='')
    p.add_argument('--head', default='')
    p.add_argument('--base-name', default='')
    p.add_argument('--gate-report', default='')
    args = p.parse_args()
    mapping = gate_list() if args.mode in ('ready', 'candidate') else None
    root = Path(os.environ['FM_TARGET_ROOT'])
    import fm_adopt
    if args.mode in ('base', 'local-gate-base', 'head', 'checks', 'ready', 'candidate'):
        adopt = fm_adopt.adoption(os.environ, args.task)
        if adopt:
            if str(adopt['pr']) != args.pr:
                raise ValueError('PR does not match authorized adoption')
            repo = repository(root)
            fm_adopt.base_matches(remote_head(repo, args.pr), adopt)
            fm_adopt.sync_base(root, repo, adopt['base'])
    if args.mode == 'local-gate-base':
        print(local_gate_base(root, args.pr, args.project_base)); return
    repo = repository(root)
    if args.mode == 'base':
        print(view_base(repo, args.pr)); return
    if args.mode == 'head':
        print(authoritative(root, args.branch, repo, args.pr)); return
    if args.mode == 'review-final':
        print(review_final(root, args.branch, repo, args.pr, args.head, args.base_name)); return
    head = sha(args.head)
    if remote_head(repo, args.pr)['headRefOid'] != head:
        raise ValueError('authoritative PR head moved; candidate is stale')
    from fm_evidence import Store
    store = Store(os.environ['FM_STATE_DIR'], os.environ['FM_EVIDENCE_PROJECT'], args.task)
    if args.mode == 'external-review':
        print(json.dumps(external_review(store, root, repo, args.pr, head))); return
    if args.mode == 'candidate':
        records = [r for r in store.records() if r['kind'] == 'readiness' and r['head'] == head and str(r.get('pr')) == args.pr and r.get('repository') == repo]
        if not records:
            raise ValueError('no signed six-gate readiness for candidate')
        record = records[-1]
        if record.get('gates') not in ([g['name'] for g in mapping['gates']], [int(n) for n in mapping['legacy']]) or not record.get('checks'):
            raise ValueError('candidate lacks all six gates and required checks')
        if required_checks(root, repo, args.pr, head, task=args.task) != record['checks']:
            raise ValueError('required check/status evidence changed; refresh gates')
        selected, external = selected_review(store, root, repo, args.pr, head)
        if review_identity(selected) != record['verdict_signature'] or (external and review_identity(external) != record.get('external_signature')):
            raise ValueError('candidate review superseded')
        if record.get('gate_base') != git(root, 'rev-parse', view_base(repo, args.pr) + '^{commit}'):
            raise ValueError('candidate gate base moved; refresh gates')
        reviewed = record['review']
        binding = reviewed.get('binding', {})
        current_base = git(root, 'merge-base', view_base(repo, args.pr), head)
        current = source_binding(args.task, head, current_base, Path(__file__).parents[2])
        for key in ('spec_sha256', 'contract_sha256', 'conventions_sha256', 'patch', 'files'):
            if current[key] != binding.get(key):
                raise ValueError('candidate source/contract changed: ' + key)
        verify_current(root, repo, args.pr, head, record['gate_base'])
        print(json.dumps(record)); return
    checks = required_checks(root, repo, args.pr, head, task=args.task)
    if args.mode == 'checks':
        print(json.dumps(checks)); return
    report_path = Path(args.gate_report).resolve()
    if report_path.parent != (Path(os.environ['FM_STATE_DIR']) / 'gates').resolve():
        raise ValueError('trusted gate transcript required')
    report = report_path.read_text()
    if not report.startswith('HEAD:' + head + '\n') or re.search(r'^  x gate ', report, re.M):
        raise ValueError('gate transcript is red or belongs to another head')
    if not re.search(r'^GATES:2$', report, re.M):
        raise ValueError('gate transcript lacks GATES:2')
    for gate in mapping['gates']:
        label = str(gate['n']) + ' (' + gate['name'] + ')'
        if not re.search(r'^  \+ gate ' + re.escape(label) + ':', report, re.M):
            raise ValueError('gate transcript lacks gate ' + label)
    base_tip = git(root, 'rev-parse', view_base(repo, args.pr) + '^{commit}')
    if not re.search(r'^BASE:' + re.escape(base_tip) + r'$', report, re.M):
        raise ValueError('gate transcript base moved or is unbound; refresh gates')
    reviewed, external = selected_review(store, root, repo, args.pr, head)
    bound = reviewed.get('binding', {})
    current_base = git(root, 'merge-base', view_base(repo, args.pr), head)
    current = source_binding(args.task, head, current_base, Path(__file__).parents[2])
    if any(current[k] != bound.get(k) for k in ('patch', 'files', 'spec_sha256', 'contract_sha256', 'conventions_sha256')):
        raise ValueError('review changed after the approval gate')
    if reviewed['head'] != head:
        git(root, 'merge-base', '--is-ancestor', reviewed['base'], current_base)
    verify_current(root, repo, args.pr, head, base_tip)
    record = store.append('readiness', reviewed['round'], 'firstmate', head, '',
                         pr=int(args.pr), repository=repo, gates=[g['name'] for g in mapping['gates']], checks=checks,
                         gate_report_sha256=digest(report.encode()), gate_base=base_tip,
                         verdict_signature=review_identity(reviewed), review=reviewed,
                         external_signature=review_identity(external) if external else None)
    print(json.dumps(record))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        import sys
        print('fm-binding: ' + str(error), file=sys.stderr)
        sys.exit(1)
