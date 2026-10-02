#!/usr/bin/env python3
"""Build a bounded, project-local worker pack outside the sandbox."""
import argparse
import datetime
import fnmatch
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from fm_evidence import Store, criteria

CAP = 48000


def bounded(items, cap=CAP):
    notice = f'Context pack cap: {cap} UTF-8 bytes. Largest items trimmed first.\n'
    bodies = [body for _, body in items]
    def render():
        return notice + ''.join(f'\n## {title}\n{body}\n' for (title, _), body in zip(items, bodies))
    while len(render().encode()) > cap:
        choices = [(len(body.encode()), n) for n, body in enumerate(bodies) if len(body.encode()) > 100]
        if not choices:
            raise ValueError('item names alone exceed pack cap; evidence cannot be represented without dropping items')
        _, n = max(choices)
        old = bodies[n].encode()
        keep = max(0, len(old) - max(256, len(render().encode()) - cap + 80))
        bodies[n] = old[:keep].decode('utf-8', errors='ignore') + '\n[TRIMMED: full evidence retained in local pack record.]'
    return render()


def coverage(situation, spec, brief, data, root, events):
    gaps = []
    waived = re.findall(r'(?im)^no brief needed:\s*(\S.*)$', brief)
    deferred = re.findall(r'(?im)^.*\bdeferred:\s*(\S.*)$', brief)
    if not waived:
        if situation == 'first':
            acceptance = '\n'.join(spec.get('acceptance', []))
            if not re.search(r'\bwhy\b', acceptance, re.I):
                gaps.append('spec has no Why')
            paths = sorted(set(re.findall(r'\b(?:bin|tests|board|skills|design)/[A-Za-z0-9_./*-]+', acceptance)))
            for path in paths:
                if any(c in path for c in '*') or path.endswith('/'):
                    continue
                path = path.rstrip('.')
                if not (root / path).exists():
                    gaps.append('named path does not exist: ' + path)
                if not any(fnmatch.fnmatchcase(path, glob) for glob in spec.get('scope', [])):
                    gaps.append('named path outside scope (confirm whether changed): ' + path)
            merged = {e.get('task') for e in events if e.get('type') == 'merged'}
            gaps.extend('dependency not recorded merged: ' + dep for dep in spec.get('depends_on', []) if dep not in merged)
        elif situation == 'red':
            supplied = brief + data.get('pack', '')
            gaps.extend('failing assertion not covered: ' + name for name in data.get('failures', []) if name not in supplied)
            if not data.get('failures'):
                gaps.append('red required check has no readable failing assertion evidence')
        elif situation == 'cancelled':
            if not data.get('cancelled'):
                gaps.append('cancelled check stage or duration unavailable')
            for item in data.get('cancelled', []):
                if not item.get('stage') or item.get('duration') is None:
                    gaps.append('cancelled check stage or duration unavailable')
        elif situation == 'reject':
            for number, _ in data.get('findings', []):
                if not re.search(r'(?im)^\s*' + str(number) + r'[.)]\s+.*\b(fix|deferred:)\b', brief):
                    # deferred: includes punctuation, so handle it explicitly.
                    if not re.search(r'(?im)^\s*' + str(number) + r'[.)]\s+.*deferred:\s*\S', brief):
                        gaps.append(f'finding {number} has no fix or reasoned deferral in approved brief')
        elif situation == 'captain-change':
            if not re.search(r'(?im)^captain:\s*["“].+["”]\s*$', brief):
                gaps.append('captain change lacks quoted captain words')
            match = re.search(r'(?m)^scope:\s*(\[.*\])\s*$', brief)
            try:
                matches = match and json.loads(match[1]) == spec.get('scope')
            except ValueError:
                matches = False
            if not matches:
                gaps.append('captain change scope does not match task scope')
    report = dict(situation=situation, gaps=gaps, waived=waived, deferred=deferred, blocks=False)
    summarize(report)
    return report


def summarize(report):
    # Called after collection too: missing API/log evidence must be visible on
    # the board, not only buried in the event's data object.
    details = '; '.join(report['gaps'])
    en = f"Brief coverage ({report['situation']}): " + (details or 'no uncovered items detected')
    tw = f"簡報涵蓋檢查（{report['situation']}）：" + (details or '未偵測到缺漏項目')
    for key, english, chinese in [('deferred', 'Deferred', '延後'), ('waived', 'No brief needed', '免簡報')]:
        if report[key]:
            reasons = '; '.join(report[key])
            en += f'; {english}: {reasons}'
            tw += f'；{chinese}：{reasons}'
    report['summary'] = {'en': en, 'zh-TW': tw}



class Collector:
    def __init__(self, root, gh, head):
        self.root, self.gh, self.head = root, gh, head
        self.gaps = []

    def command(self, args):
        result = subprocess.run(args, cwd=self.root, capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f'{args[0]} evidence unavailable: {result.stderr.strip()[:500]}')
        return result.stdout

    def github(self, *args):
        try:
            result = subprocess.run([self.gh, *args], cwd=self.root, capture_output=True, text=True)
            allowed = (0, 1, 8) if args[:2] == ('pr', 'checks') else (0,)
            if result.returncode not in allowed:
                raise ValueError(f'gh evidence unavailable: {result.stderr.strip()[:500]}')
            return json.loads(result.stdout)
        except (ValueError, OSError) as error:
            self.gaps.append(str(error))
            return None

    def source(self, path, line):
        if Path(path).is_absolute() or '..' in Path(path).parts:
            return 'Source refused: path outside head'
        try:
            lines = self.command(['git', 'show', self.head + ':' + path]).splitlines()
            return '\n'.join(f'{path}:{n + 1}: {lines[n]}' for n in range(max(0, line - 11), min(len(lines), line + 10)))
        except ValueError as error:
            self.gaps.append(str(error))
            return 'Source unavailable: ' + path

    def assertion_sources(self, message):
        try:
            # Literal messages only. Never execute a runner-provided shell expression.
            hits = self.command(['git', 'grep', '-n', '-F', '-e', message, self.head, '--', 'tests/'])
        except ValueError:
            return 'Assertion source not located by literal message: ' + message
        output = []
        for hit in hits.splitlines():
            match = re.match(re.escape(self.head) + r':(.+?):(\d+):', hit)
            if match:
                output.append(self.source(match[1], int(match[2])))
        return '\n'.join(output)

    def log(self, job):
        # Stream to disk, retain assertion byte offsets instead of loading large logs.
        failures, evidence = [], []
        with tempfile.TemporaryFile() as output:
            result = subprocess.run([self.gh, 'run', 'view', '--job', str(job), '--log-failed'],
                                    cwd=self.root, stdout=output, stderr=subprocess.PIPE)
            output.seek(0)
            offset = 0
            detail = False
            for raw in output:
                start = offset
                offset += len(raw)
                line = re.sub(r'\x1b\[[0-9;]*m', '', raw.decode(errors='replace')).rstrip()
                line = re.sub(r'^.*?\t.*?\t', '', line)
                line = re.sub(r'^\d{4}-\d\d-\d\dT\S+\s*', '', line)
                match = re.match(r'\s*(.*?)\s+FAIL\s*$', line)
                if match:
                    failures.append(match[1])
                if match or detail or '##[error]' in line or re.match(r'\s*x\s', line):
                    evidence.append(f'bytes {start}-{offset}: {line}')
                detail = bool(match)
            if result.returncode:
                self.gaps.append(f'job {job} log unavailable or partial: ' + result.stderr.decode(errors='replace')[:300])
            if not evidence:
                self.gaps.append(f'job {job} has no readable failing assertion lines')
        return failures, '\n'.join(evidence)


def build(args):
    root = Path(args.root)
    store = Store(args.state, args.project, args.task)
    spec = json.loads(Path(args.spec).read_text())
    brief_record = store.brief(args.round, args.head)
    brief = brief_record['text'] if brief_record else ''
    collector = Collector(root, args.gh, args.head)
    items, situations, data = [], [], dict(failures=[], cancelled=[], findings=[])
    reviews = store.verdicts()
    if reviews:
        latest = reviews[-1]
        items.append(('Latest local review (' + latest['provenance']['level'] + ')', latest['text']))
        if latest['verdict'] == 'REJECT':
            situations.append('reject')
            data['findings'] = criteria(latest['text'], args.task)
        for path, line in re.findall(r'([A-Za-z0-9_./-]+\.[A-Za-z0-9]+):(\d+)', latest['text']):
            items.append((f'Review source {path}:{line}', collector.source(path, int(line))))
    if not args.pr:
        situations.append('first')
        brief = brief or 'First round: the approved task spec is the brief.\n' + json.dumps(spec, indent=2)
    else:
        pr = collector.github('pr', 'view', args.pr, '--json', 'headRefOid,baseRefName,mergeStateStatus') or {}
        if pr.get('headRefOid') != args.head:
            collector.gaps.append('PR head differs from local head or could not be verified')
        merge = pr.get('mergeStateStatus', 'UNKNOWN')
        items.append(('PR merge state', merge))
        if merge == 'DIRTY':
            result = subprocess.run(['git', 'merge-tree', '--write-tree', '--name-only', args.base, args.head],
                                    cwd=root, capture_output=True, text=True)
            paths = result.stdout.split('\n\n')[0].splitlines()[1:]
            items.append(('Conflicting paths', '\n'.join(paths) or 'Unknown: conflict paths could not be determined'))
            if not paths:
                collector.gaps.append('DIRTY PR conflicting paths unavailable')
        protection = collector.github('api', 'repos/{owner}/{repo}/branches/' + pr.get('baseRefName', args.base) + '/protection/required_status_checks')
        names = []
        source = 'branch protection'
        if protection:
            names = protection.get('contexts', []) + [c['context'] for c in protection.get('checks', [])]
        if not names:
            source = 'gh pr checks --required'
            required = collector.github('pr', 'checks', args.pr, '--required', '--json', 'name')
            names = [c['name'] for c in required or []]
        if not names and args.required:
            source, names = 'project config required_check', [args.required]
        items.append(('Required checks', f'head={args.head}; source={source}; names={json.dumps(names)}'))
        if not names:
            collector.gaps.append('no source names required checks')
        jobs = collector.github('api', f'repos/{{owner}}/{{repo}}/commits/{args.head}/check-runs?per_page=100')
        statuses = collector.github('api', f'repos/{{owner}}/{{repo}}/commits/{args.head}/status?per_page=100')
        if statuses is not None and statuses.get('sha') != args.head:
            collector.gaps.append('commit statuses do not identify the requested head')
            statuses = None
        if (jobs or {}).get('total_count', 0) > 100:
            collector.gaps.append('check-run listing exceeds 100 entries; remaining evidence unavailable')
        latest_jobs = {}
        for job in (jobs or {}).get('check_runs', []):
            if job.get('head_sha') == args.head:
                name = job['name']
                if job.get('id', 0) > latest_jobs.get(name, {}).get('id', -1):
                    latest_jobs[name] = job
        items.append(('Check runs and commit statuses', f'Exact head {args.head}; sources commit check-runs and status APIs\n' + json.dumps(dict(check_runs=list(latest_jobs.values()), statuses=statuses), indent=2)))
        for name in names:
            job = latest_jobs.get(name)
            matching = [s for s in (statuses or {}).get('statuses', []) if s.get('context') == name]
            if not job and not matching:
                collector.gaps.append('required check missing: ' + name)
            elif job and job.get('status') != 'completed':
                collector.gaps.append('required check pending: ' + name)
            elif matching and matching[0].get('state') == 'pending':
                collector.gaps.append('required commit status pending: ' + name)
            elif matching and matching[0].get('state') in ('failure', 'error'):
                situations.append('red')
        for job in latest_jobs.values():
            conclusion = job.get('conclusion')
            action = re.search(r'/actions/runs/[0-9]+/job/([0-9]+)', job.get('details_url') or job.get('html_url') or '')
            action_job = action[1] if action else None
            if conclusion in ('failure', 'timed_out'):
                situations.append('red')
                if action_job:
                    failures, log = collector.log(action_job)
                else:
                    failures, log = [], 'No Actions job id is available for this check run.'
                    collector.gaps.append(f'job {job["name"]}: {log}')
                data['failures'].extend(failures)
                items.append((f'Job {job["name"]} failing log', log or 'Unavailable'))
                for failure in failures:
                    items.append(('Assertion ' + failure, collector.assertion_sources(failure)))
            if conclusion == 'cancelled':
                situations.append('cancelled')
                detail = (collector.github('api', f'repos/{{owner}}/{{repo}}/actions/jobs/{action_job}') if action_job else {}) or {}
                steps = [s for s in detail.get('steps', []) if s.get('started_at')]
                step = next((s for s in reversed(steps) if s.get('conclusion') == 'cancelled'), steps[-1] if steps else {})
                duration = None
                try:
                    start = datetime.datetime.fromisoformat(step['started_at'].replace('Z', '+00:00'))
                    end = datetime.datetime.fromisoformat((step.get('completed_at') or job['completed_at']).replace('Z', '+00:00'))
                    duration = max(0, (end - start).total_seconds())
                except (ValueError, KeyError, AttributeError):
                    pass
                cancellation = dict(stage=step.get('name'), duration=duration)
                data['cancelled'].append(cancellation)
                items.append(('Cancelled ' + job['name'], json.dumps(cancellation)))
        if merge == 'BEHIND' and not situations and not collector.gaps:
            situations.append('behind')
            brief = brief or 'no brief needed: branch only needs updating with its base'
        if not brief:
            collector.gaps.append('missing authorized local brief for exact project/task/round/head')
    if 'captain:' in brief.lower():
        situations.append('captain-change')
    # Include acceptance verbatim; associations are candidates, never invented semantic matches.
    items.append(('Acceptance items (review relevance for each finding/failure)', '\n'.join(f'{n}. {text}' for n, text in enumerate(spec.get('acceptance', []), 1))))
    associations = []
    for title, body in items:
        if not title.startswith(('Assertion ', 'Review source ')):
            continue
        paths = set(re.findall(r'(?:tests|bin|board|skills|design)/[A-Za-z0-9_./-]+', title + '\n' + body))
        matched = [str(n) for n, item in enumerate(spec.get('acceptance', []), 1)
                   if any(path.rstrip('.') in item for path in paths)]
        associations.append(title + ': ' + ('acceptance ' + ', '.join(matched) + ' (shared path; semantic relevance requires review)'
                                             if matched else 'unmapped; firstmate must identify the acceptance item'))
        if not matched:
            collector.gaps.append('acceptance association unavailable: ' + title)
    if associations:
        items.append(('Acceptance associations', '\n'.join(associations)))
    data['pack'] = '\n'.join(body for _, body in items)
    event_path = Path(args.state) / 'events.jsonl'
    events = []
    if event_path.exists():
        for line in event_path.read_text().splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
    reports = [coverage(s, spec, brief, data, root, events) for s in dict.fromkeys(situations or ['existing'])]
    for report in reports:
        report['gaps'].extend(collector.gaps)
        summarize(report)
    if collector.gaps:
        items.append(('Evidence gaps (warnings; round continues)', '\n'.join(collector.gaps)))
    pack = bounded(items)
    store.append('pack', args.round, args.actor, args.head, pack, items=items, coverage=reports)
    Path(args.output).write_text('# Approved local brief\n\n' + (brief or 'Unavailable; see coverage warnings.') + '\n\n# Context pack\n\n' + pack + '\n\n# Local review history\n\n' + store.history())
    Path(args.coverage).write_text(json.dumps(reports))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('state', 'project', 'task', 'head', 'actor', 'root', 'spec', 'output', 'coverage'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--round', type=int, required=True)
    parser.add_argument('--pr', default='')
    parser.add_argument('--gh', default='gh')
    parser.add_argument('--base', default='main')
    parser.add_argument('--required', default='')
    build(parser.parse_args())


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-context-pack: ' + str(error), file=sys.stderr)
        sys.exit(1)
