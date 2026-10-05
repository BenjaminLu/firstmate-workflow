"""Inspect first; write private conventions only on explicit captain confirmation."""
import argparse
import base64
from datetime import datetime, timezone
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

sys.dont_write_bytecode = True
import fm_origin
from fm_conventions import read_policy, validate
from fm_project_paths import external_home


def now():
    return datetime.now(timezone.utc).isoformat()


def atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise ValueError('refusing symlink: ' + str(path))
    tmp = path.with_name(path.name + '.tmp-' + str(os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def save(path, value):
    atomic(path, json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def api(endpoint):
    result = subprocess.run([os.environ.get('FM_GH', 'gh'), 'api', endpoint],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip() or 'GitHub unreadable')
    return json.loads(result.stdout)


def observed(call, endpoint):
    try:
        return {'status': 'known', 'value': call(endpoint)}
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        return {'status': 'unknown', 'reason': str(error)}


def inspect_remote(repository, call=api):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('repository must be owner/repo')
    prefix = 'repos/' + repository
    repo = call(prefix)
    if repo.get('full_name', '').lower() != repository.lower():
        raise ValueError('GitHub returned a different repository')
    base = repo['default_branch']
    evidence = dict(repository=repository, inspected_at=now(), source='github',
                    repository_info=repo, base=base,
                    protection=observed(call, prefix + '/branches/' + quote(base, safe='') + '/protection'),
                    languages=observed(call, prefix + '/languages'), files={}, commits=[], pulls=[])
    for path in ('.github/CODEOWNERS', 'CODEOWNERS', 'docs/CODEOWNERS',
                 '.github/pull_request_template.md', '.github/PULL_REQUEST_TEMPLATE.md',
                 'PULL_REQUEST_TEMPLATE.md', 'docs/pull_request_template.md',
                 'CONTRIBUTING.md', '.github/CONTRIBUTING.md'):
        record = observed(call, prefix + '/contents/' + path + '?ref=' + quote(base, safe=''))
        if record['status'] == 'known':
            value = record['value']
            if isinstance(value, dict) and value.get('encoding') == 'base64':
                record['text'] = base64.b64decode(value['content']).decode('utf-8', errors='replace')
        evidence['files'][path] = record
    pulls = observed(call, prefix + '/pulls?state=all&sort=updated&direction=desc&per_page=30')
    evidence['history'] = pulls['status']
    if pulls['status'] == 'unknown':
        evidence['history_reason'] = pulls['reason']
    for pr in pulls.get('value', [])[:30]:
        number = pr['number']; ep = prefix + '/pulls/' + str(number)
        item = dict(pr)
        item['detail'] = observed(call, ep)
        if item['detail']['status'] == 'known': item['detail'] = item['detail']['value']
        for key, endpoint in [('reviews', ep + '/reviews?per_page=100'),
                              ('comments', prefix + '/issues/' + str(number) + '/comments?per_page=100')]:
            item[key] = observed(call, endpoint)
        sha = pr.get('head', {}).get('sha')
        if sha:
            item['statuses'] = observed(call, prefix + '/commits/' + sha + '/status?per_page=100')
            item['checks'] = observed(call, prefix + '/commits/' + sha + '/check-runs?per_page=100')
        evidence['pulls'].append(item)
    return evidence


def git(path, *args):
    proc = subprocess.run(['git', '-C', str(path), *args], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=30)
    return proc.stdout.strip() if proc.returncode == 0 else ''


def inspect_local(path):
    path = Path(path).resolve(strict=True)
    # Opening the directory proves permission even when git's failure is normal
    # for a fresh folder. Never turn a denied read into empty history.
    list(path.iterdir())
    top = git(path, 'rev-parse', '--show-toplevel')
    if top and Path(top).resolve() != path:
        raise ValueError('local target must be its own repository, not a nested folder')
    return dict(source='local', path=str(path), repository='', base=git(path,'symbolic-ref','--short','HEAD'),
                remote=git(path,'remote','get-url','origin'), commits=git(path,'log','-30','--format=%s').splitlines(),
                pulls=[], history='unknown', protection={'status':'unknown','reason':'local onboarding'},
                files={}, languages={'status':'unknown'}, inspected_at=now())


def infer(e):
    info = e.get('repository_info', {})
    flags = [('squash','allow_squash_merge'),('merge','allow_merge_commit'),('rebase','allow_rebase_merge')]
    methods = ([x for x,key in flags if info[key]]
               if all(type(info.get(key)) is bool for _,key in flags) else 'unknown')
    reviewers = {}; statuses = set(); stacked = set(); cadence = []
    authors = {}; mergers = {}; merged_by = {}; states = {}; volume = {}; languages = set()
    for text in [x.get('text','') for x in e.get('files',{}).values()]:
        if re.search(r'[\u4e00-\u9fff]',text): languages.add('zh')
        if re.search(r'[A-Za-z]',text): languages.add('en')
    for pr in e['pulls']:
        author = pr.get('user') or {}
        if author.get('login'): authors[author['login']] = author.get('type','unknown')
        detail = pr.get('detail',{})
        merged_by[str(pr['number'])] = detail.get('merged_by','unknown')
        merger = detail.get('merged_by') or {}
        if merger.get('login'): mergers[merger['login']] = merger.get('type','unknown')
        volume[str(pr['number'])] = {'comments':detail.get('comments','unknown'),
                                     'review_comments':detail.get('review_comments','unknown')}
        for comment in pr.get('comments',{}).get('value',[]):
            body=comment.get('body','')
            if re.search(r'[\u4e00-\u9fff]',body): languages.add('zh')
            if re.search(r'[A-Za-z]',body): languages.add('en')
        for review in pr.get('reviews', {}).get('value', []):
            user = review.get('user') or {}
            if user.get('login'):
                reviewers[user['login']] = user.get('type', 'unknown')
                states.setdefault(user['login'],[]).append({'pr':pr['number'], 'state':review.get('state','unknown'),
                                                           'at':review.get('submitted_at','unknown')})
            if review.get('submitted_at') and pr.get('created_at'):
                cadence.append((datetime.fromisoformat(review['submitted_at'].replace('Z','+00:00')) - datetime.fromisoformat(pr['created_at'].replace('Z','+00:00'))).total_seconds())
        for status in pr.get('statuses',{}).get('value',{}).get('statuses',[]):
            statuses.add(status['context'])
        pr_base=pr.get('base',{}).get('ref')
        if pr_base and pr_base != e.get('base'):
            stacked.add(pr_base)
    protection = e['protection'].get('value', {})
    checks = protection.get('required_status_checks')
    required = 'unknown'
    if e['protection'].get('status') == 'known' and 'required_status_checks' in protection:
        if checks is None:
            required = []  # GitHub explicitly says no status-check requirement.
        elif isinstance(checks, dict) and ('contexts' in checks or 'checks' in checks):
            required = sorted(set(checks.get('contexts',[]) + [x['context'] for x in checks.get('checks',[])]))
    return dict(repository=e['repository'], base=e.get('base') or 'unknown', land='card',
                review='external' if reviewers else 'fm', post='local', merge_method=methods[0] if isinstance(methods,list) and methods else 'unknown',
                available_merge_methods=methods, delete_branch=info.get('delete_branch_on_merge','unknown'),
                required_checks=required, observed_statuses=sorted(statuses), reviewers=sorted(reviewers),
                reviewer_types=reviewers, review_states=states, authors=authors, mergers=mergers, merged_by=merged_by,
                comment_volume=volume, conversation_languages=sorted(languages),
                repository_languages=e.get('languages',{}), visibility=info.get('visibility', ('private' if info['private'] else 'public') if type(info.get('private')) is bool else 'unknown'),
                review_cadence_seconds=cadence, stacked_bases=sorted(stacked),
                stacking='hold', force_with_lease=False, protection=e['protection'],
                watch_seconds=60, debounce_seconds=30, reinspect_seconds=86400,
                posting_languages=['en','zh-TW'], confirmed=False, policy_confirmed=False,
                commit_examples=e.get('commits',[]),
                commit_style={'conventional_subjects':sum(bool(re.match(r'[a-z]+(?:\([^)]*\))?!?: ',x)) for x in e.get('commits',[])),
                              'sample_size':len(e.get('commits',[]))}, bootstrap_authorized=False)


def questions(e, p):
    return [
        dict(id='contract', question='What product intent and project commands should govern this repository?',
             evidence={'commits': e.get('commits',[]), 'contributing':e.get('files',{}).get('CONTRIBUTING.md',{'status':'unknown'})},
             recommendation='Supply product, setup/check/test contract and dated captain intent; never infer a product brief.'),
        dict(id='location', question='Confirm the repository owner, location and visibility (and any initial-commit authorization).',
             evidence={'repository':e['repository'], 'source':e['source'], 'remote':e.get('remote',''), 'private':e.get('repository_info',{}).get('private','unknown')},
             recommendation='Keep external records private in FM_HOME; create no remote without explicit authorization.'),
        dict(id='policy', question='Confirm or correct the inferred checks, merge, review and posting policy below.',
             evidence=p, recommendation='land: card; confirm required checks/statuses, unknown protection, available merge methods and branch deletion; stacking held, no force push, no auto-merge.')]


def render(p):
    validate(p)
    lines = ['---']
    for key, value in p.items():
        lines.append(key + ': ' + (value if key in ('land','review','post','merge_method','stacking') else json.dumps(value, ensure_ascii=False)))
    lines.extend(['---', '', '# Project conventions', '',
                  'Captain intent (' + p['confirmed_at'] + '): ' + p['captain'] + ' — ' + p['intent'],
                  'Product/project contract: ' + p['product'],
                  'Every merge requires the captain intent card or explicit handoff. Never auto-merge.',
                  'Required checks/statuses: ' + ', '.join(p['required_checks']),
                  'Protection visibility: ' + p['protection']['status'] + '; checks and policy explicitly confirmed by the captain.',
                  'Reviewers: ' + ', '.join(p['reviewers']) + '; review mode: ' + p['review'],
                  'Merge method: ' + p['merge_method'] + '; branch deletion: ' + str(p['delete_branch']),
                  'Stacking policy: ' + p['stacking'] + '. Execution remains held for T-143. Force-with-lease: ' + str(p['force_with_lease']) + '; expected old head is mandatory.',
                  'Commits/PRs: follow the inspected CODEOWNERS, CONTRIBUTING and PR template in state/onboarding/inspection.json; private acceptance stays local.',
                  'Commit examples: ' + json.dumps(p['commit_examples'], ensure_ascii=False),
                  f"Watch cadence {p['watch_seconds']}s; debounce {p['debounce_seconds']}s; re-inspect every {p['reinspect_seconds']}s while the owned watcher runs.",
                  'Posting languages: ' + ', '.join(p['posting_languages']) + '; post: ' + p['post'],
                  'Bootstrap initial-commit exception authorized: ' + str(p['bootstrap_authorized']) + '. No remote is created by onboarding; subsequent task pushes never target the protected base.', ''])
    return '\n'.join(lines)


def contract_yaml(contract):
    allowed = {'setup', 'check', 'test', 'tests', 'docs', 'check_env'}
    if set(contract) - allowed:
        raise ValueError('unknown project contract key')
    lines = ['project:']
    for key, value in contract.items():
        if key in ('setup', 'check', 'test'):
            if not isinstance(value, str) or not value.strip():
                raise ValueError('project command must be a nonempty string')
            if key == 'test' and '{file}' not in value:
                raise ValueError('project.test must contain {file}')
            lines.append('  ' + key + ': ' + json.dumps(value, ensure_ascii=False))
        elif key in ('tests', 'docs'):
            if not isinstance(value, list) or any(not isinstance(x, str) for x in value):
                raise ValueError('project globs must be a list of strings')
            lines.append('  ' + key + ':')
            lines.extend('    - ' + json.dumps(x, ensure_ascii=False) for x in value)
        else:
            if not isinstance(value, dict) or any(not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', k) or not isinstance(v, str) for k,v in value.items()):
                raise ValueError('check_env must map variable names to strings')
            lines.append('  check_env:')
            lines.extend('    '+k+': '+json.dumps(v, ensure_ascii=False) for k,v in value.items())
    return '\n'.join(lines) + '\n'


def validate_merge_methods(p):
    methods=p.get('available_merge_methods')
    if (not isinstance(methods,list) or not methods
            or any(x not in ('squash','merge','rebase') for x in methods)):
        raise ValueError('captain must confirm available merge methods; empty methods permit no merge')
    if p['merge_method'] not in methods:
        raise ValueError('merge method disabled by repository')


def approve(home, e, p, answers):
    if answers.get('confirmed') is not True or answers.get('policy_confirmed') is not True:
        raise ValueError('explicit captain confirmation required')
    contract = answers.get('contract')
    if not isinstance(contract, dict) or not contract.get('check'):
        raise ValueError('captain project contract with check required')
    contract_text = contract_yaml(contract)
    p = dict(p)
    p.setdefault('analysers', [])
    allowed = {'repository','visibility','base','land','review','post','merge_method','delete_branch',
               'available_merge_methods','required_checks','reviewers','analysers','stacking','force_with_lease','watch_seconds',
               'debounce_seconds','reinspect_seconds','posting_languages','confirmed',
               'policy_confirmed','bootstrap_authorized','product','captain','intent'}
    for key, value in answers.items():
        if key in allowed: p[key] = value
    if e['source'] == 'github' and (p['repository'] != e['repository'] or p['base'] != e['base']):
        raise ValueError('cannot change inspected repository/base binding')
    if not e.get('commits') and e['source'] == 'local' and answers.get('bootstrap_authorized') is not True:
        raise ValueError('empty local repository needs explicit initial-commit/bootstrap authorization')
    if e['source'] == 'local' and (not answers.get('repository') or answers.get('visibility') not in ('private','public','internal')):
        raise ValueError('remote owner/location/visibility contract required; no remote created')
    observed_methods = infer(e)['available_merge_methods']
    if observed_methods != 'unknown' and p['available_merge_methods'] != observed_methods:
        raise ValueError('cannot override observed repository merge methods')
    validate_merge_methods(p)
    p['confirmed_at'] = now()
    validate(p)
    home = Path(home)
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    save(home/'state/onboarding/inspection.json',e)
    # JSON values are valid YAML scalars/arrays; the existing contract reader
    # owns interpretation, including test globs and commands.
    atomic(home/'state/config.yaml', contract_text)
    atomic(home/'CONVENTIONS.md', render(p))
    return p


def edit(home, changes, captain, intent):
    home = Path(home); path=home/'CONVENTIONS.md'
    p=read_policy(path); old=path.read_text()
    if set(changes) & {'repository','base','confirmed','confirmed_at','captain','intent','policy_confirmed'}:
        raise ValueError('binding/confirmation changes require fresh onboarding')
    p.setdefault('analysers', [])
    if not set(changes) <= set(p): raise ValueError('unknown conventions field')
    p.update(changes); p.update(captain=captain,intent=intent,confirmed_at=now())
    validate_merge_methods(p)
    new=render(p)
    delta=''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='CONVENTIONS.md before',tofile='CONVENTIONS.md after'))
    atomic(home/'state/onboarding/edits'/('edit-'+str(__import__('time').time_ns())+'.diff'),delta)
    atomic(path,new)
    return delta


def drift(home, evidence):
    home=Path(home); previous=json.loads((home/'state/onboarding/inspection.json').read_text())
    # New approvals, reviewers, methods and requirements matter. PR timestamps,
    # volumes and the inspection time alone must not wake the captain every day.
    keys=('reviewers','reviewer_types','protection','available_merge_methods','delete_branch','observed_statuses')
    old=infer(previous); new=infer(evidence)
    delta={k:{'before':old[k],'proposed':new[k]} for k in keys if old[k] != new[k]}
    if not delta: return ''
    text=json.dumps(delta,indent=2,ensure_ascii=False)+'\n'
    path=home/'state/onboarding/drift-proposal.json'
    if path.exists() and path.read_text() == text: return ''
    atomic(path,text)
    save(home/'state/onboarding/drift-inspection.json',evidence)
    return text


def registry_value(engine, name, field):
    code=Path(__file__).resolve().parents[1]/'fm-config.sh'
    p=subprocess.run(['bash','-c','. "$1"; fm_project_get "$2" "$3" "$4/config.yaml"',
                      '_',str(code),name,field,str(engine)],capture_output=True,text=True,timeout=30)
    if p.returncode: raise ValueError(p.stderr.strip())
    return p.stdout.strip()


def register(engine, name, p):
    path=engine/'config.yaml'
    with path.open(newline='') as source:
        text=source.read()
    lines=text.splitlines(keepends=True)
    headers=[i for i,line in enumerate(lines)
             if re.match(r'projects:\s*(#.*)?$',line.rstrip('\r\n'))]
    if len(headers) > 1:
        raise ValueError('config.yaml has more than one projects: block; merge them by hand before onboarding')
    # The public registry receives routing only. Existing names must match;
    # onboarding never overwrites another project or private nested contract.
    if any(re.match(r'^  '+re.escape(name)+r':[ \t]*(#.*)?$',line.rstrip('\r\n')) for line in lines):
        for field,value in [('github',p['repository']),('base',p['base'])]:
            if registry_value(engine,name,field) != value: raise ValueError('existing registry binding differs')
        return
    entry='  '+name+':\n    github: '+json.dumps(p['repository'])+'\n    base: '+json.dumps(p['base'])+'\n    required_check: '+json.dumps(p['required_checks'][0])+'\n'
    if headers:
        insertion=headers[0]+1
        for i in range(insertion,len(lines)):
            raw=lines[i].rstrip('\r\n')
            # Match fm_registry.top_block's boundary, retaining comments and
            # blank lines verbatim. Indented continuations belong to the entry.
            if raw.strip() and not raw.lstrip().startswith('#') and not raw[:1].isspace():
                break
            if raw[:1].isspace():
                insertion=i+1
        before=''.join(lines[:insertion])
        if not before.endswith(('\n','\r')):
            before+='\n'
        text=before+entry+''.join(lines[insertion:])
    else:
        text+='\nprojects:\n'+entry
    atomic(path,text)


def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument('command',choices=['add','edit','drift'])
    parser.add_argument('target')
    parser.add_argument('--name')
    parser.add_argument('--repo',default=os.environ.get('FM_ROOT',os.getcwd()))
    parser.add_argument('--answers',type=Path)
    parser.add_argument('--changes',type=Path)
    parser.add_argument('--captain')
    parser.add_argument('--intent')
    args=parser.parse_args(argv)
    engine=Path(args.repo).resolve()
    try:
        if args.command != 'add':
            home=Path(registry_value(engine,args.target,'home'))
            if home == engine: raise ValueError('onboarding edits apply only to external projects')
            if args.command == 'edit':
                if not args.changes or not args.captain or not args.intent: raise ValueError('edit needs changes, captain and intent')
                print(edit(home,json.loads(args.changes.read_text()),args.captain,args.intent))
                from fm_lifeline import ring, ring_state
                ring(engine, 'conventions edited')
                ring_state(home/'state', 'conventions edited')
            else:
                p=read_policy(home/'CONVENTIONS.md')
                print(drift(home,inspect_remote(p['repository'])) or 'No convention drift.')
            return 0
        local=Path(args.target).is_dir()
        name=args.name or (Path(args.target).name if local else args.target.split('/')[-1]).lower()[:24]
        configured=''
        config=(engine/'config.yaml').read_text()
        match=re.search(r'^home:\s*(.+)$',config,re.M)
        if match: configured=match[1].strip('"\'')
        home=external_home(engine,name,configured)
        home.mkdir(parents=True, exist_ok=True, mode=0o700)
        e=inspect_local(Path(args.target)) if local else inspect_remote(args.target)
        if not local:
            expected=os.environ.get('FM_GITHUB_URL','https://github.com')+'/'+args.target+'.git'
            managed=home/'repo'
            if managed.exists():
                if fm_origin.check(managed, expected) is not None:
                    raise ValueError('managed clone origin does not match inspected repository')
                e['commits']=git(managed,'log','-30','--format=%s').splitlines()
            else:
                # Inspection has no managed-clone side effects. Only sync owns
                # repo/, its full history, checkout, hooks and guard settings.
                scratch=home/'state/onboarding'
                scratch.mkdir(parents=True,exist_ok=True,mode=0o700)
                with tempfile.TemporaryDirectory(prefix='history-',dir=scratch) as temp:
                    result=subprocess.run(['git','clone','--no-checkout','--depth','30',expected,temp],
                                          stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=120)
                    if result.returncode: e['commit_history']='unknown: '+result.stderr.strip()
                    else: e['commits']=git(temp,'log','-30','--format=%s').splitlines()
        p=infer(e)
        save(home/'state/onboarding/pending-inspection.json',e)
        save(home/'state/onboarding/proposal.json',dict(inferred=p,questions=questions(e,p)))
        if not args.answers:
            print(json.dumps(dict(inferred=p,questions=questions(e,p)),indent=2,ensure_ascii=False))
            return 0
        answers=json.loads(args.answers.read_text())
        if re.search(r'^  '+re.escape(name)+r':[ \t]*(#.*)?$',config,re.M):
            for field, proposed in [('github',answers.get('repository',p['repository'])),
                                    ('base',answers.get('base',p['base']))]:
                if registry_value(engine,name,field) != proposed:
                    raise ValueError('existing registry binding differs; choose a different name')
            if registry_value(engine,name,'repo') == '.':
                raise ValueError('external onboarding cannot replace the self project')
        p=approve(home,e,p,answers)
        register(engine,name,p)
        from fm_lifeline import ring, ring_state
        ring(engine, 'conventions approved')
        ring_state(home/'state', 'conventions approved')
        print(str(home/'CONVENTIONS.md'))
        return 0
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print('fm-onboard: '+str(error),file=sys.stderr)
        return 65


if __name__ == '__main__':
    sys.exit(main())
