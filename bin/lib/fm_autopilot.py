"""Session-owned event supervisor (T-141).

Local state is read at subscription/startup and on pushed doorbells, never on
a polling timer. GitHub deadlines use conditional requests. Timers also close
already observed reviewer batches and report overdue judgment; no idle timer
starts a model. Side effects are write-ahead, at most once until reconciled by
firstmate; an ambiguous crash is judgment, not permission to replay a write.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
import fm_lifeline as life
from fm_conventions import read_policy
from fm_watch import Locked, read_json, save_json, notify

BIN = Path(__file__).resolve().parents[1]
DEFAULTS = dict(watch_seconds=60, debounce_seconds=180, reinspect_seconds=86400,
                post='comments', land='card', review='fm', stacking='hold',
                force_with_lease=False, reviewers=[])


def context():
    return dict(engine=os.environ['FM_ENGINE_ROOT'], state=os.environ['FM_STATE_DIR'],
                target=os.environ['FM_TARGET_ROOT'], tasks=os.environ['FM_TASKS_DIR'],
                project=os.environ.get('FM_PROJECT', ''), repository=os.environ['FM_AUTOPILOT_REPOSITORY'],
                base=os.environ.get('FM_BASE') or 'main', external=os.environ['FM_EXTERNAL'] == '1',
                evidence_project=os.environ['FM_EVIDENCE_PROJECT'])


def key(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:32]


class Pilot:
    def __init__(self, ctx, clock=time.time):
        self.ctx = ctx
        self.root = Path(ctx['engine'])
        self.state = Path(ctx['state'])
        self.directory = self.state / 'autopilot'
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / 'state.json'
        self.clock = clock
        first_start = not self.path.exists()
        self.data = {} if first_start else json.loads(self.path.read_text())
        if not isinstance(self.data, dict): raise ValueError('invalid autopilot recovery state')
        for name, default in dict(offset=0, wake_offset=0, actions={}, seen={}, batches={},
                                  wakes={}, pulls={}, cache={}, failures=0, next_poll=0).items():
            self.data.setdefault(name, default)
        if first_start:
            # Snapshot both durable inputs before any poll or policy side effect.
            # Existing recovery state, including zero cursors, remains authoritative.
            for cursor, source in (('offset', self.state / 'events.jsonl'),
                                   ('wake_offset', self.state / 'session/wake.jsonl')):
                try:
                    self.data[cursor] = source.stat().st_size
                except FileNotFoundError:
                    self.data[cursor] = 0
            self.save()
        self.policy = dict(DEFAULTS)
        self.policy_error = None
        self.reload_policy()
        self.push = lambda ident, reason, line, extra: life.push(self.root, ident, reason, line, extra)
        self.notify = notify

    def save(self):
        save_json(self.path, self.data)

    def reload_policy(self):
        if not self.ctx['external']:
            return
        try:
            policy = read_policy(self.state.parent / 'CONVENTIONS.md', self.ctx['repository'], self.ctx['base'])
            fingerprint = key(policy)
            old = self.data.get('policy')
            self.policy = {**DEFAULTS, **policy}
            self.policy_error = None
            if old and old != fingerprint:
                self.queue('conventions-' + fingerprint, '', 'Conventions changed; reassess ongoing work',
                           '專案慣例已變更；請重新評估進行中的工作')
            self.data['policy'] = fingerprint
        except (OSError, ValueError) as error:
            self.policy_error = str(error)
            self.queue('conventions-invalid-' + key(str(error)), '',
                       'Conventions unavailable: ' + str(error), '專案慣例無法驗證；需要判斷')

    def command(self, argv, *, allow_not_modified=False, **kwargs):
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, text=True,
                                capture_output=True, timeout=120, **kwargs)
        # gh reports HTTP 304 as exit 1, with response headers on stdout.
        # Only a conditional API read may opt in; all other command errors stay errors.
        not_modified = allow_not_modified and re.match(r'HTTP/\S+ 304(?:\s|$)', result.stdout)
        if result.returncode and not not_modified:
            raise RuntimeError(result.stderr[:1000] or 'command failed: ' + argv[0])
        return result.stdout

    def script(self, name, *args):
        return ['bash', str(BIN / name), *map(str, args), '--repo', str(self.root),
                *(['--project', self.ctx['project']] if self.ctx['project'] else [])]

    def gh(self, *args):
        return [os.environ.get('FM_GH', 'gh'), *map(str, args)]

    def emit(self, kind, task, en, tw, pr=None):
        self.command(['bash', str(BIN / 'fm-emit.sh'), '--actor', 'autopilot', '--type', kind,
                      *(['--task', task] if task else []), '--en', en, '--tw', tw,
                      *(['--pr', str(pr)] if pr else []),
                      *(['--project', self.ctx['project']] if self.ctx['project'] else [])],
                     env={**os.environ, 'FM_ROOT': str(self.root)})

    def queue(self, identity, task, en, tw):
        ident = 'autopilot-' + key([self.ctx['project'], identity])
        if ident not in self.data['wakes']:
            self.data['wakes'][ident] = dict(task=task, line=en, summary={'en':en, 'zh-TW':tw},
                                            created=self.clock(), pushed=False, notified=False)
            self.save()
        return ident

    def flush(self):
        now = self.clock()
        for reviewer, batch in list(self.data['batches'].items()):
            if now < batch['due']:
                continue
            self.queue('batch-' + key(batch), batch['task'],
                       '; '.join(batch['lines']), '審查意見已成批；請判斷：' + reviewer)
            del self.data['batches'][reviewer]
        for ident, item in self.data['wakes'].items():
            if not item['pushed']:
                # Durable project queue is the recovery source; bridge queue
                # is T-137's transport. Neither record proves model receipt.
                queue = self.state / 'wake-queue'
                queue.mkdir(exist_ok=True)
                save_json(queue / (ident + '.json'), dict(item, id=ident, model_delivery='unverified'))
                self.push(ident, 'autopilot', item['line'],
                          dict(task=item['task'], summary=item['summary'], project=self.ctx['project']))
                item['pushed'] = True
                self.save()
            overdue = now >= item['created'] + max(300, self.policy['debounce_seconds'] * 2)
            if overdue and not item['notified']:
                if not life.is_acknowledged(self.root, ident, item['created']):
                    self.emit('autopilot_waiting', item['task'], 'Waiting for firstmate: ' + item['line'],
                              '等待 firstmate 判斷：' + item['summary']['zh-TW'])
                    self.notify(item['summary']['en'] + '\n' + item['summary']['zh-TW'])
                item['notified'] = True
        self.save()

    def once(self, identity, task, action):
        token = key(identity)
        if token in self.data['actions']:
            return
        self.data['actions'][token] = dict(state='started', identity=identity, task=task)
        self.save()
        try:
            action()
            self.data['actions'][token]['state'] = 'done'
        except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
            self.data['actions'][token]['state'] = 'uncertain'
            self.queue('action-' + token, task, 'Mechanical action needs reconciliation: ' + str(error),
                       '機械步驟結果不確定；請核對後再繼續')
        self.save()

    def recover(self):
        for token, action in self.data['actions'].items():
            if action['state'] == 'started':
                action['state'] = 'uncertain'
                self.queue('action-' + token, action['task'], 'Autopilot stopped during an action; reconcile its outcome',
                           '自動駕駛於步驟執行中停止；請核對結果')

    def api(self, endpoint):
        cached = self.data['cache'].get(endpoint, {})
        argv = self.gh('api', ('repos/' + self.ctx['repository'] + '/' + endpoint).rstrip('/'), '--include')
        if cached.get('etag'):
            argv += ['-H', 'If-None-Match: ' + cached['etag']]
        conditional = bool(cached.get('etag')) and 'body' in cached
        output = self.command(argv, allow_not_modified=conditional).replace('\r\n', '\n')
        headers, separator, body = output.partition('\n\n')
        match = re.match(r'HTTP/\S+ (\d+)', headers)
        if not match or not separator:
            raise ValueError('GitHub response has no HTTP headers')
        status = int(match[1])
        if status == 304 and conditional:
            return cached['body']
        if status != 200:
            raise ValueError('GitHub status ' + str(status))
        value = json.loads(body)
        etag = re.search(r'^etag:\s*(.+)$', headers, re.I | re.M)
        self.data['cache'][endpoint] = dict(etag=etag[1] if etag else '', body=value)
        return value

    def pages(self, endpoint):
        rows = []
        for page in range(1, 1001):
            part = self.api(endpoint + ('&' if '?' in endpoint else '?') + 'per_page=100&page=' + str(page))
            if not isinstance(part, list):
                raise ValueError('incomplete GitHub list: ' + endpoint)
            rows.extend(part)
            if len(part) < 100:
                return rows
        raise ValueError('GitHub pagination bound reached')

    def network_failure(self, reason):
        self.data['failures'] = min(10, self.data['failures'] + 1)
        delay = min(3600, self.policy['watch_seconds'] * 2 ** self.data['failures'])
        self.data['next_poll'] = self.clock() + delay
        self.queue('network-' + str(self.data.get('network_episode', 0)), '', 'GitHub unavailable; backing off: ' + reason,
                   'GitHub 無法連線；已延後重試')
        self.save()
        return delay

    def network_success(self):
        if self.data['failures']:
            self.data['network_episode'] = self.data.get('network_episode', 0) + 1
        self.data['failures'] = 0
        self.data['next_poll'] = self.clock() + self.policy['watch_seconds']
        self.save()

    def task(self, pr):
        match = re.match(r'^((?:t|sk)-[0-9]+)(?:-|$)', pr['head']['ref'], re.I)
        task = match[1].upper() if match else ''
        return task if task and (Path(self.ctx['tasks']) / (task + '.json')).is_file() else ''

    def needs_base_review(self, task, pr, old):
        # Only the narrowly authorized replacement of a non-carrying APPROVE.
        # Store verifies signatures; unknown/corrupt evidence queues judgment
        # through once(), never supplies permission to launch a model.
        from fm_binding import git, source_binding, change
        from fm_evidence import Store
        rows = Store(str(self.state), self.ctx['evidence_project'], task).verdicts()
        if not rows or rows[-1]['verdict'] != 'APPROVE':
            return False
        if not old.get('base_sha'):
            return False  # pre-upgrade observations cannot prove base-only
        root = self.ctx['target']
        old_base = git(root, 'merge-base', old['base_sha'], old['head'])
        previous = change(root, old['head'], old_base)
        base = git(root, 'merge-base', pr['base']['sha'], pr['head']['sha'])
        current = source_binding(task, pr['head']['sha'], base, BIN.parent)
        if previous['patch'] != current['patch']:
            # Worker edits belong to fm-run's review loop.
            return False
        record = rows[-1]
        if not record.get('signature'):
            return True  # gate 7 refuses pre-T-138 unsigned legacy approvals
        binding = record.get('binding') or {}
        # A different approved change is not this base-only carry case.
        if record.get('patch') != current['patch'] or binding.get('patch') != current['patch']:
            return False
        return any(current[k] != binding.get(k) for k in
                   ('spec_sha256', 'contract_sha256', 'conventions_sha256'))

    def launch_review(self, task, pr):
        # fm-review owns visibility, identity, sandbox and final provenance.
        # Never invoke an adapter directly from supervision.
        logfile = open(self.directory / (task + '-review.log'), 'ab')
        try:
            child = life.start(self.script('fm-review.sh', '--task', task, '--branch', pr['head']['sha'],
                                           '--pr', pr['number']), owner=os.getpid(),
                               stdin=subprocess.DEVNULL, stdout=logfile, stderr=logfile)
        finally:
            logfile.close()
        def completed():
            result = child.wait()
            # The launcher emits the canonical final event. If it refuses
            # before allocating a round, still push an observable failure.
            if result:
                try:
                    self.emit('worker_crashed', task, 'Review launcher failed; inspect its log.',
                              '審查啟動失敗；請檢查紀錄。')
                except (RuntimeError, OSError, subprocess.SubprocessError) as error:
                    print('autopilot: review failure event unavailable: ' + str(error), file=sys.stderr)
        threading.Thread(target=completed, daemon=True).start()

    def prepare_head(self, pr):
        """Fetch immutable objects, never reset or move a local task branch."""
        target = self.ctx['target']
        repository = self.ctx['repository']
        self.command(['git', '-C', target, 'fetch', '--no-tags', 'https://github.com/' + repository + '.git',
                      'refs/pull/' + str(pr['number']) + '/head'])
        fetched = self.command(['git', '-C', target, 'rev-parse', 'FETCH_HEAD']).strip()
        if fetched != pr['head']['sha']:
            raise ValueError('PR head moved while fetching review objects')
        from urllib.parse import quote
        base = self.api('branches/' + quote(pr['base']['ref'], safe=''))
        if base['commit']['sha'] != pr['base']['sha']:
            raise ValueError('PR base moved while preparing review')
        self.command(['git', '-C', target, 'fetch', '--no-tags', 'https://github.com/' + repository + '.git',
                      'refs/heads/' + pr['base']['ref']])
        current = json.loads(self.command(self.gh('pr', 'view', str(pr['number']), '--repo', repository,
                                                   '--json', 'headRefOid,baseRefOid,state')))
        if (current['headRefOid'], current['baseRefOid'], current['state']) != (pr['head']['sha'], pr['base']['sha'], 'OPEN'):
            raise ValueError('PR changed during review preparation')

    def recheck(self, task, pr, reviews):
        names = self.policy.get('reviewers', [])
        for name in names:
            prior = [r for r in reviews if r.get('user', {}).get('login', '').lower() == name.lower()]
            if not prior or any(r.get('commit_id') == pr['head']['sha'] for r in prior):
                continue
            identity = ['recheck', pr['number'], pr['head']['sha'], name]
            if self.policy['post'] == 'local':
                self.queue(key(identity), task, 'Reviewer re-check needed: ' + name,
                           '需要審查者重新檢查：' + name)
                continue
            def request(name=name):
                # Request a review, not a fabricated approval or public round
                # log. Repository and reviewer are structured REST fields.
                self.command(self.gh('api', 'repos/' + self.ctx['repository'] + '/pulls/' + str(pr['number']) +
                                     '/requested_reviewers', '--method', 'POST', '-f', 'reviewers[]=' + name))
            self.once(identity, task, request)

    def restack(self, pr, parent):
        task = self.task(pr)
        if not task or not parent.get('merged_at'):
            return
        if self.policy['stacking'] != 'allowed' or self.policy['force_with_lease'] is not True:
            self.queue('restack-held-' + str(pr['number']), task, 'Merged stack base needs confirmed restack policy',
                       '堆疊基底已合併；需確認重設基底政策')
            return
        self.once(['restack', pr['number'], pr['head']['sha'], parent['number']], task,
                  lambda: self.command(self.script('lib/fm-restack.sh', '--pr', pr['number'],
                                                   '--parent', parent['number'], '--expected-head', pr['head']['sha'])))

    def pull(self, pr, reviews, comments, runs, statuses):
        task = self.task(pr)
        if not task or pr['state'] != 'open' or self.policy_error or pr['head']['ref'] == self.ctx['base']:
            return
        number, head = str(pr['number']), pr['head']['sha']
        old = self.data['pulls'].get(number)
        if old and old.get('head') and old['head'] != head:
            if self.policy['review'] in ('fm', 'both'):
                def review():
                    self.prepare_head(pr)
                    if self.needs_base_review(task, pr, old): self.launch_review(task, pr)
                self.once(['review', number, head], task, review)
            self.recheck(task, pr, reviews)
        self.data['pulls'][number] = dict(head=head, branch=pr['head']['ref'], base=pr['base']['ref'], base_sha=pr['base']['sha'])
        latest = {}
        for row in runs:
            if row.get('head_sha') == head:
                name = ('check', row['name'])
                if row['id'] > latest.get(name, {}).get('id', -1): latest[name] = row
        for row in statuses:
            name = ('status', row['context'])
            if row['id'] > latest.get(name, {}).get('id', -1): latest[name] = row
        for (kind, name), row in latest.items():
            failed = row.get('state') in ('failure', 'error') if kind == 'status' else row.get('conclusion') in ('failure','timed_out','cancelled','action_required','startup_failure')
            if failed:
                self.queue(key([number, head, kind, name, row['id']]), task,
                           f'CI failed: {task} #{number} {name} {head}', f'CI 失敗：{task} #{number} {name}')
        for kind, rows in (('review', reviews), ('finding', comments)):
            for row in rows:
                if kind == 'review' and row.get('state') not in ('CHANGES_REQUESTED','COMMENTED'):
                    continue
                if kind == 'review' and row.get('state') == 'COMMENTED' and not row.get('body'):
                    continue
                token = key([number, kind, row.get('_source'), row.get('id'), row.get('updated_at'),
                             row.get('state'), row.get('body'), row.get('commit_id')])
                if token in self.data['seen']: continue
                self.data['seen'][token] = True
                reviewer = row.get('user', {}).get('login', 'unknown')
                batchkey = number + ':' + reviewer
                batch = self.data['batches'].setdefault(batchkey, dict(task=task, lines=[]))
                batch['lines'].append(f"{task} #{number} {reviewer}: {row.get('state') or kind} {row.get('html_url') or row.get('id')}")
                batch['due'] = self.clock() + self.policy['debounce_seconds']
        # REST mergeable=True is gh's MERGEABLE; unknown/null never authorizes.
        if pr.get('mergeable') is True and pr.get('mergeable_state') == 'behind' and not pr.get('draft'):
            def update():
                current = json.loads(self.command(self.gh('pr', 'view', number, '--repo', self.ctx['repository'],
                                                          '--json', 'headRefOid,mergeable,mergeStateStatus')))
                if current != dict(headRefOid=head, mergeable='MERGEABLE', mergeStateStatus='BEHIND'):
                    raise ValueError('branch update head or mergeability changed; reassess')
                self.command(self.gh('pr', 'update-branch', number, '--repo', self.ctx['repository']))
            self.once(['update', number, head], task, update)
        self.save()

    def poll(self):
        if self.policy_error:
            self.data['next_poll'] = self.clock() + self.policy['watch_seconds']
            return
        try:
            pulls = self.pages('pulls?state=open')
            open_numbers = {str(item['number']) for item in pulls}
            for number, previous in list(self.data['pulls'].items()):
                if number not in open_numbers and not previous.get('terminal'):
                    self.closed_pull(self.api('pulls/' + number))
            for item in pulls:
                number = item['number']
                pr = self.api('pulls/' + str(number))
                head = pr['head']['sha']
                reviews = self.pages(f'pulls/{number}/reviews')
                comments = [dict(row, _source='review-comment') for row in self.pages(f'pulls/{number}/comments')]
                names = {name.lower() for name in self.policy.get('reviewers', [])}
                if names:
                    comments += [dict(row, _source='issue-comment') for row in self.pages(f'issues/{number}/comments')
                                 if row.get('user', {}).get('login', '').lower() in names]
                runs = self.api(f'commits/{head}/check-runs?per_page=100')
                statuses = self.api(f'commits/{head}/status?per_page=100')
                if statuses.get('sha') != head or runs.get('total_count', 0) > 100 or statuses.get('total_count', 0) > 100:
                    raise ValueError('incomplete or stale check/status response')
                self.pull(pr, reviews, comments, runs['check_runs'], statuses['statuses'])
                if pr['base']['ref'] != self.ctx['base'] and self.task(pr):
                    from urllib.parse import quote
                    parents = self.pages('pulls?state=closed&head=' + quote(self.ctx['repository'].split('/')[0] + ':' + pr['base']['ref'], safe=''))
                    for parent in parents:
                        if parent['head']['ref'] == pr['base']['ref'] and parent.get('merged_at'):
                            self.restack(pr, parent)
                            break
            self.network_success()
            self.inspect_policy()
        except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
            self.network_failure(str(error))

    def closed_pull(self, pr):
        if pr.get('state') != 'closed': return
        task = self.task(pr)
        if task and pr.get('merged_at'):
            self.once(['observed-merge', pr['number'], pr['head']['sha']], task,
                      lambda: self.emit('merged', task, f'GitHub reports #{pr["number"]} merged',
                                        f'GitHub 回報 #{pr["number"]} 已合併', pr['number']))
        elif task:
            self.queue('closed-' + str(pr['number']), task,
                       f'PR #{pr["number"]} closed without merging; task needs judgment',
                       f'PR #{pr["number"]} 已關閉但未合併；任務需要判斷')
        self.data['pulls'].setdefault(str(pr['number']), {})['terminal'] = True
        self.save()

    def inspect_policy(self):
        if not self.ctx['external'] or self.clock() < self.data.get('next_inspection', 0): return
        self.data['next_inspection'] = self.clock() + self.policy['reinspect_seconds']
        from urllib.parse import quote
        repo = self.api('')
        try:
            protection = self.api('branches/' + quote(self.ctx['base'], safe='') + '/protection/required_status_checks')
            checks = sorted(set(protection.get('contexts', []) + [r['context'] for r in protection.get('checks', [])]))
        except (RuntimeError, ValueError):
            checks = None  # private protection can be unknown, never permissive
        observed = dict(checks=checks, methods=dict(squash=repo.get('allow_squash_merge'),
                        merge=repo.get('allow_merge_commit'), rebase=repo.get('allow_rebase_merge')),
                        delete_branch=repo.get('delete_branch_on_merge'), base=repo.get('default_branch'))
        previous = self.data.get('observed_policy')
        confirmed = set(self.policy['required_checks'])
        mismatch = checks is not None and not set(checks).issubset(confirmed)
        method = self.policy['merge_method']
        mismatch = mismatch or observed['methods'].get(method) is False
        if mismatch or (previous is not None and previous != observed):
            self.queue('policy-drift-' + key(observed), '', 'Repository policy changed; review confirmed conventions',
                       '儲存庫政策已變更；請檢查已確認的專案慣例')
        self.data['observed_policy'] = observed
        self.save()

    def event(self, event, identity):
        if event.get('project') not in (None, self.ctx['project']): return
        kind = event.get('type')
        task = event.get('task', '')
        data = event.get('data') or {}
        pr = event.get('pr')
        if task and isinstance(pr, int) and pr > 0 and (Path(self.ctx['tasks']) / (task + '.json')).is_file():
            tracked = self.data['pulls'].setdefault(str(pr), dict(task=task))
            if kind == 'merged': tracked['terminal'] = True
        reasons = dict(worker_crashed='Worker round failed', agent_lost='Round lost',
                       review_failed='Review requires judgment', conventions_drift='Conventions drift',
                       gate_failed='Gate failed')
        reason = reasons.get(kind)
        if kind == 'agent_finished' and data.get('result') not in (None, 'ok', 'success'):
            reason = 'Round failed'
        if kind == 'decision_made' and (data.get('chosen') or data.get('answer')) in ('B','C'):
            reason = 'Captain answered ' + (data.get('chosen') or data.get('answer'))
        if reason:
            self.queue('event-' + identity, task, reason + ': ' + task, '需要 firstmate 判斷：' + task)

    def read_lines(self, path, cursor, consume):
        try:
            with path.open('rb') as stream:
                if stream.seek(0, 2) < self.data[cursor]: self.data[cursor] = 0
                stream.seek(self.data[cursor]); raw = stream.read()
        except FileNotFoundError:
            return
        end = raw.rfind(b'\n') + 1
        offset = self.data[cursor]
        for line in raw[:end].splitlines(keepends=True):
            try:
                row = json.loads(line)
                if isinstance(row, dict): consume(row, str(offset))
            except json.JSONDecodeError:
                self.queue('malformed-' + cursor + str(offset), '', 'Unreadable local event; inspect the source log',
                           '本機事件無法讀取；請檢查來源紀錄')
            offset += len(line)
        self.data[cursor] += end

    def local(self):
        self.reload_policy()
        self.read_lines(self.state / 'events.jsonl', 'offset', self.event)
        def wake(item, offset):
            # The board pushes decisions here, even if its event has no answer.
            if item.get('reason') == 'answered':
                decision = item.get('decision') or {}
                self.event(dict(type='decision_made', task=decision.get('task', ''),
                                data=decision), 'wake-' + offset)
            elif item.get('reason') in ('conventions_drift', 'conventions_unknown'):
                self.queue('conventions-wake-' + offset, '', item.get('line', 'Conventions need judgment'),
                           '專案慣例需要判斷')
        self.read_lines(self.state / 'session/wake.jsonl', 'wake_offset', wake)
        self.save()

    def ready(self):
        if self.policy_error: return
        rows = self.command(self.script('fm-ready.sh', 'list'))
        for row in rows.splitlines():
            task, state, _, title = row.split('\t', 3)
            if state != 'unjudged' or not re.fullmatch(r'T-[0-9]+', task): continue
            # Readiness is a judgment, not a mechanical card template. The
            # episode record deduplicates this request until readiness changes.
            record = read_json(self.state / 'ready' / (task + '.json'))
            self.queue(key(['intent', task, record]), task,
                       f'{task} ready: readiness card needed',
                       f'{task} 已就緒：需要 firstmate 判斷並建立就緒決策卡')

    def delay(self):
        deadlines = [self.data['next_poll']]
        deadlines += [b['due'] for b in self.data['batches'].values()]
        deadlines += [w['created'] + max(300, self.policy['debounce_seconds'] * 2)
                      for w in self.data['wakes'].values() if not w['notified']]
        return max(0.1, min(deadlines) - self.clock())


def live(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'service.lock').open('a') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return True
    return False


def ensure(ctx, owner):
    directory = Path(ctx['state']) / 'autopilot'
    directory.mkdir(parents=True, exist_ok=True)
    with Locked(directory / 'start.lock'):
        if live(directory): return
        save_json(directory / 'owner.json', dict(owner=owner, requested=time.time(), pid=None))
        with (directory / 'service.log').open('ab') as log:
            child = life.start([sys.executable, str(Path(__file__).resolve()), 'serve'], owner=owner,
                               env={**os.environ, 'FM_AUTOPILOT_OWNED':'1'},
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log)
        threading.Thread(target=child.wait, daemon=True).start()
        ready, _, _ = select.select([child.stdout], [], [], 30)
        line = child.stdout.readline() if ready else b''
        child.stdout.close()
        if line != b'ready\n': raise RuntimeError('autopilot did not become ready; inspect service.log')


def serve(ctx):
    if os.environ.get('FM_AUTOPILOT_OWNED') != '1':
        raise ValueError('use ensure to start autopilot through the session lifeline')
    owner = life.session_owner()
    pilot = Pilot(ctx)
    with (pilot.directory / 'service.lock').open('a') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: return 0
        with life.Doorbell(pilot.root, channel='autopilot.d') as bell:
            save_json(pilot.directory / 'owner.json', dict(pid=os.getpid(), owner=owner, started=time.time()))
            print('ready', flush=True)
            os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
            pilot.recover()
            pushed = True
            while True:
                if pushed:
                    pilot.local()
                    try: pilot.ready()
                    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
                        pilot.queue('ready-error', '', 'Intent card needs attention: ' + str(error), '意圖卡需要處理')
                if pilot.clock() >= pilot.data['next_poll']: pilot.poll()
                pilot.flush()
                pushed = bell.wait(pilot.delay())


def main():
    ctx = context()
    mode = sys.argv[1]
    if mode == 'context': print(json.dumps(ctx))
    elif mode == 'running': return 0 if live(Path(ctx['state']) / 'autopilot') else 1
    elif mode == 'status':
        directory = Path(ctx['state']) / 'autopilot'
        print(json.dumps(dict(running=live(directory), **read_json(directory / 'owner.json'))))
    elif mode == 'ensure': ensure(ctx, life.session_owner())
    elif mode == 'serve': return serve(ctx)
    else: raise ValueError('unknown autopilot mode')
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('fm-autopilot: ' + str(error), file=sys.stderr)
        sys.exit(70)
