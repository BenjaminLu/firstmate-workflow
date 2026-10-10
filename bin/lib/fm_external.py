"""External review evidence and optional projections, only outside crew rounds.

GitHub input is authenticated by the API transport and named policy identities,
not by marker text. It never enters the local fm verdict/standing-list stream.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from fm_binding import change, git, github, remote_head, sha, source_binding
from fm_conventions import read_policy
from fm_evidence import Store


def pages(repo, endpoint):
    output = []
    for page in range(1, 1001):
        rows = github(repo, 'api', f'repos/{repo}/{endpoint}?per_page=100&page={page}')
        if not isinstance(rows, list):
            raise ValueError('incomplete external API collection: ' + endpoint)
        output.extend(rows)
        if len(rows) < 100:
            return output
    raise ValueError('external API pagination bound exceeded')


def threads(repo, pr):
    owner, name = repo.split('/')
    query = '''query($owner:String!, $name:String!, $pr:Int!, $cursor:String) {
      repository(owner:$owner,name:$name) { pullRequest(number:$pr) {
        reviewThreads(first:100,after:$cursor) { pageInfo { hasNextPage endCursor }
          nodes { id isResolved path line originalLine
            comments(first:100) { pageInfo { hasNextPage }
              nodes { id databaseId author { login } body url path line originalLine
                commit { oid } originalCommit { oid } } } } } } } }'''
    output, cursor, seen = [], None, set()
    for _ in range(1000):
        args = ['api', 'graphql', '-f', 'query=' + query, '-f', 'owner=' + owner,
                '-f', 'name=' + name, '-F', 'pr=' + str(pr)]
        if cursor:
            args += ['-f', 'cursor=' + cursor]
        response = github(repo, *args)
        if response.get('errors'):
            raise ValueError('external review threads unavailable')
        connection = response['data']['repository']['pullRequest']['reviewThreads']
        for thread in connection['nodes']:
            if thread['comments']['pageInfo']['hasNextPage']:
                raise ValueError('incomplete thread comments; refresh with complete evidence')
            output.append(thread)
        if not connection['pageInfo']['hasNextPage']:
            return output
        cursor = connection['pageInfo']['endCursor']
        if not cursor or cursor in seen:
            raise ValueError('incomplete review thread pagination')
        seen.add(cursor)
    raise ValueError('review thread pagination bound exceeded')


def check_evidence(repo, head, names):
    runs = github(repo, 'api', f'repos/{repo}/commits/{head}/check-runs?per_page=100')
    statuses = github(repo, 'api', f'repos/{repo}/commits/{head}/status?per_page=100')
    if statuses.get('sha') != head:
        raise ValueError('external commit statuses belong to another head')
    if runs.get('total_count', 0) > 100 or statuses.get('total_count', 0) > 100:
        raise ValueError('incomplete external check/status evidence')
    missing = []
    for name in names:
        checks = [r for r in runs['check_runs'] if r.get('name') == name and r.get('head_sha') == head]
        states = [s for s in statuses['statuses'] if s.get('context') == name]
        if not checks and not states:
            missing.append('missing check/status: ' + name)
        if checks:
            latest = max(checks, key=lambda r: r['id'])
            if latest.get('status') != 'completed' or latest.get('conclusion') not in ('success','neutral','skipped'):
                missing.append('check not green: ' + name)
        if states and max(states, key=lambda s: s['id']).get('state') != 'success':
            missing.append('commit status not green: ' + name)
    return dict(check_runs=runs['check_runs'], statuses=statuses), missing


def retain(store, kind, head, **fields):
    # Repeated reads with identical source bytes retain a stable receipt, which
    # lets the merge candidate compare signatures without trusting projections.
    previous = [r for r in store.records() if r['kind'] == kind]
    if previous and previous[-1]['head'] == head and all(previous[-1].get(k) == v for k,v in fields.items()):
        return previous[-1]
    return store.append(kind, 1, 'firstmate-external', head, '', **fields)


def collect(store, root, repo, pr, head, policy):
    sha(head)
    reviewers = policy.get('reviewers')
    if not isinstance(reviewers, list) or not reviewers or any(
            not isinstance(n, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*(?:\[bot\])?', n) for n in reviewers):
        raise ValueError('external review needs named conventions reviewers')
    names = {n.lower() for n in reviewers}
    if len(names) != len(reviewers):
        raise ValueError('duplicate named reviewer')
    before = remote_head(repo, pr)
    if before['headRefOid'] != head:
        raise ValueError('external evidence head is stale')
    if git(root, 'rev-parse', before['baseRefName'] + '^{commit}') != before['baseRefOid']:
        raise ValueError('external evidence base is stale')
    base = git(root, 'merge-base', before['baseRefName'], head)
    binding = source_binding(store.task, head, base, Path(__file__).parents[2])
    reviews = pages(repo, f'pulls/{pr}/reviews')
    discussions = threads(repo, pr)
    comments = pages(repo, f'issues/{pr}/comments')
    states, findings, blockers = {}, [], []
    for name in sorted(names):
        rows = sorted([r for r in reviews if r.get('user', {}).get('login', '').lower() == name
                       and r.get('state') != 'PENDING'], key=lambda r: (r.get('submitted_at', ''), r['id']))
        latest = rows[-1] if rows else {}
        state = latest.get('state', 'UNKNOWN')
        reviewed_head = latest.get('commit_id')
        covers = False
        if state == 'APPROVED':
            try:
                sha(reviewed_head)
                old_base = git(root, 'merge-base', before['baseRefName'], reviewed_head)
                old = change(root, reviewed_head, old_base)
                git(root, 'merge-base', '--is-ancestor', old_base, base)
                covers = old['patch'] == binding['patch'] and old['files'] == binding['files']
            except (ValueError, subprocess.SubprocessError):
                covers = False
        states[name] = dict(state=state, reviewed_head=reviewed_head, covers=covers, review=latest)
        if state != 'APPROVED' or not covers:
            blockers.append(name + ': ' + state + (' (stale or unknown patch)' if state == 'APPROVED' else ''))
        # A COMMENTED review cannot clear an earlier request. Retain the last
        # request until a later approval; bodies remain linked evidence too.
        approval = max((i for i,r in enumerate(rows) if r['state'] == 'APPROVED'), default=-1)
        for row in rows[approval+1:]:
            if row.get('body') and row.get('state') in ('CHANGES_REQUESTED','COMMENTED'):
                findings.append(dict(id='review:' + str(row['id']), reviewer=name,
                    body=row['body'], url=row['html_url'], path=None, line=None,
                    reviewed_head=row.get('commit_id'), resolved=False, reply_id=None))
    for thread in discussions:
        for comment in thread['comments']['nodes']:
            login = (comment.get('author') or {}).get('login', '').lower()
            if login not in names:
                continue
            # Keep the named reviewer's finding, but reply to the thread root.
            # GitHub refuses replies to replies, even when a bot joined later.
            finding = dict(id=thread['id'], reviewer=login, body=comment['body'],
                url=comment['url'], path=thread.get('path'), line=thread.get('line') or thread.get('originalLine'),
                reviewed_head=(comment.get('originalCommit') or comment.get('commit') or {}).get('oid'),
                resolved=thread['isResolved'], reply_id=thread['comments']['nodes'][0]['databaseId'])
            findings.append(finding)
            if not thread['isResolved']:
                blockers.append(login + ': unresolved thread ' + thread['id'])
            break
    for comment in comments:
        login = comment.get('user', {}).get('login', '').lower()
        if login in names:
            findings.append(dict(id='comment:' + str(comment['id']), reviewer=login, body=comment['body'],
                url=comment.get('html_url'), path=None, line=None, reviewed_head=None, resolved=False, reply_id=None))
    analysers = policy.get('analysers', [])
    if not isinstance(analysers, list) or any(not isinstance(n,str) or not n.strip() for n in analysers):
        raise ValueError('conventions analysers must name check/status contexts')
    checks, failures = check_evidence(repo, head, sorted(set(policy['required_checks'] + analysers)))
    blockers.extend(failures)
    after = remote_head(repo, pr)
    if (after['headRefOid'], after['baseRefOid']) != (head, before['baseRefOid']):
        raise ValueError('PR head/base moved while collecting external reviews')
    # The full receipt is still sealed. Candidate identity excludes unrelated
    # API payloads, timestamps and superseded runs while binding decisive input.
    contexts = sorted(set(policy['required_checks'] + analysers))
    decisive_checks = {}
    for name in contexts:
        runs = [r for r in checks['check_runs'] if r.get('name') == name and r.get('head_sha') == head]
        statuses = [s for s in checks['statuses']['statuses'] if s.get('context') == name]
        run = max(runs, key=lambda r: r['id'], default={})
        status = max(statuses, key=lambda s: s['id'], default={})
        decisive_checks[name] = dict(
            check={k: run.get(k) for k in ('head_sha', 'status', 'conclusion')},
            status=status.get('state'))
    decisive_states = {name: dict(state=row['state'], reviewed_head=row['reviewed_head'],
        covers=row['covers'], review_id=row['review'].get('id')) for name, row in states.items()}
    decisive = dict(head=head, repository=repo, pr=int(pr), binding=binding,
                    states=decisive_states, findings=findings, checks=decisive_checks)
    readiness_signature = hashlib.sha256(json.dumps(decisive, sort_keys=True,
        separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    return retain(store, 'external-verdict', head, repository=repo, pr=int(pr),
        readiness_signature=readiness_signature,
        verdict='APPROVE' if not blockers else 'REJECT', ready=not blockers, blockers=blockers,
        states=states, findings=findings, reviews=reviews, threads=discussions, comments=comments,
        checks=checks, base=base, patch=binding['patch'], binding=binding,
        provenance=dict(level='legacy', final_source='github-review-api', reviewers=sorted(names)))


def findings_text(record):
    lines = ['External named-reviewer evidence (not an fm verdict).',
             'Readiness: ' + ('approved' if record['ready'] else '; '.join(record['blockers']))]
    for finding in record['findings']:
        location = f"{finding['path']}:{finding['line']}" if finding.get('path') else 'no cited line'
        lines.append(f"\nFinding {finding['id']} by {finding['reviewer']}; {location}; "
                     f"reviewed commit {finding.get('reviewed_head')}; resolved={finding['resolved']}\n"
                     f"{finding.get('url')}\n{finding['body']}")
    return '\n'.join(lines)


def advise(store, source, text):
    """Advisory plain-writing lint for crew text (T-270): findings go to
    firstmate's log and never stop the post. A glossary that cannot be read
    is logged as a lint failure naming the file, never read as empty."""
    try:
        import fm_plain
    except ImportError:
        return
    log = store.state / 'runtime/plain-writing.jsonl'
    try:
        findings = fm_plain.lint(text, 'en', fm_plain.load_glossary(), [])
    except (OSError, ValueError) as error:
        findings = [dict(check='lint-failed', match=str(error))]
    fm_plain.log_findings(log, source, findings)


def public(text):
    """Authored text with every fm-merge-card block removed (T-270 Change 11).
    The reviewer's merge card stays in local evidence; a closed, duplicate or
    unclosed block never reaches a comment or thread reply. Without the
    helper, only text that names no merge card may be posted."""
    try:
        import fm_plain
    except ImportError:
        if 'fm-merge-card' in text:
            raise ValueError('merge card helper unavailable; nothing posted') from None
        return text
    return fm_plain.without(text)


def write_api(repo, endpoint, body, method='POST'):
    # JSON stdin preserves newlines and literal shell characters. No model text
    # becomes argv syntax, a shell command, or an implicitly selected repository.
    result = subprocess.run([os.environ.get('FM_GH', 'gh'), 'api', f'repos/{repo}/{endpoint}',
                             '--method', method, '--input', '-'], input=json.dumps(body),
                            text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError('optional projection failed; local evidence retained: ' + result.stderr[:500])
    return json.loads(result.stdout)


def project(store, root, repo, pr, head, policy, stage, replies=None, text=None):
    if policy['post'] == 'local':
        return
    store.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (store.directory / '.projection.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _project(store, root, repo, pr, head, policy, stage, replies, text)


def _project(store, root, repo, pr, head, policy, stage, replies=None, text=None):
    mode = policy['post']
    if mode == 'local':
        return
    if mode not in ('summary','check','threads','comments'):
        raise ValueError('unsupported projection mode')
    view = remote_head(repo, pr)
    if view['headRefOid'] != sha(head):
        raise ValueError('projection head is stale')
    receipts = [r for r in store.records() if r['kind'] == 'projection' and r.get('repository') == repo and r.get('pr') == int(pr)]
    summary = (f'Firstmate finished the {stage} step at commit {head}. The review details and evidence stay '
               "in firstmate's private records. This comment reports progress only; it does not approve a merge.")
    def receipt(key, result):
        return store.append('projection', 1, 'firstmate-external', head, '', repository=repo,
                            pr=int(pr), mode=mode, key=key, result=result)
    if mode == 'summary':
        previous = next((r for r in reversed(receipts) if r['mode'] == mode), None)
        endpoint = f"issues/comments/{int(previous['result']['id'])}" if previous else f'issues/{pr}/comments'
        result = write_api(repo, endpoint, {'body':summary}, 'PATCH' if previous else 'POST')
        receipt('summary', result)
    elif mode == 'check':
        # Personal credentials can create commit statuses, but not check runs.
        # This context reports publication progress only, never review approval.
        result = write_api(repo, f'statuses/{head}', dict(context='firstmate local progress',
            state='success', description=f'Firstmate finished the {stage} step. Evidence stays private. This status does not approve a merge.'))
        receipt('check', result)
    elif mode == 'comments':
        text = public(text or '')
        if text.strip():
            advise(store, 'external-comment', text)
            receipt('comments', write_api(repo, f'issues/{pr}/comments', {'body':text}))
    elif replies:
        record = collect(store, root, repo, pr, head, policy)
        findings = {f['id']:f for f in record['findings']}
        prepared, seen = [], set()
        for reply in replies:
            finding = findings.get(reply['finding'])
            if not finding or not finding.get('reply_id') or reply['finding'] in seen:
                raise ValueError('reply must identify one unique review-thread finding')
            seen.add(reply['finding'])
            commit = sha(reply['commit'])
            git(root, 'merge-base', '--is-ancestor', commit, head)
            if not reply.get('language') or not isinstance(reply.get('body'), str) or not public(reply['body']).strip():
                raise ValueError('reply requires authored text in the thread language')
            key = finding['id'] + ':' + commit
            if any(r.get('key') == key and r['mode'] == mode for r in receipts):
                continue
            prepared.append((key, finding, reply))
        for key, finding, reply in prepared:
            if remote_head(repo, pr)['headRefOid'] != head:
                raise ValueError('PR head moved before thread reply')
            authored = public(reply['body'])
            body = authored.rstrip() + '\n\n' + f"{repo}@{reply['commit']}"
            advise(store, 'external-thread-reply', authored)
            result = write_api(repo, f"pulls/{pr}/comments/{int(finding['reply_id'])}/replies", {'body':body})
            receipt(key, result)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['collect','project'])
    for name in ('state','project','task','root','repository','pr','head','conventions'):
        p.add_argument('--'+name, required=True)
    p.add_argument('--stage', choices=['worker','reviewer'], default='worker')
    p.add_argument('--format', choices=['json','prompt'], default='json')
    p.add_argument('--replies')
    p.add_argument('--text')
    args = p.parse_args()
    if not re.fullmatch(r'[1-9][0-9]*', args.pr):
        raise ValueError('invalid PR number')
    policy = read_policy(args.conventions,args.repository)
    store = Store(args.state,args.project,args.task,external=True)
    if args.command == 'collect':
        if policy['review'] in ('external','both'):
            record = collect(store,args.root,args.repository,args.pr,args.head,policy)
            if args.format == 'prompt':
                from fm_context_pack import bounded
                print(bounded([('External findings', findings_text(record))], 12000))
            else:
                print(json.dumps(record))
    else:
        project(store,args.root,args.repository,args.pr,args.head,policy,args.stage,
                json.loads(Path(args.replies).read_text()) if args.replies else None,
                Path(args.text).read_text() if args.text else None)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('fm-external: ' + str(error), file=sys.stderr)
        sys.exit(1)
