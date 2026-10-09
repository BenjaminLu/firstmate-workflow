"""Session-owned event supervisor (T-141).

Local event cursors advance at subscription/startup and on pushed doorbells.
GitHub deadlines use conditional requests; observed PRs bind local evidence
and authored card details before advancing. Timers also close
already observed reviewer batches and report overdue judgment; no idle timer
starts a model. Branch updates re-decide GitHub state with REST compare-and-swap;
local task refs fast-forward before advance when no round/job or dirty worktree
holds them. No write-ahead action ledger remains: each step is re-decided from
per-PR records and observed state, and only owned jobs interrupted mid-run are
left for firstmate to reconcile.
"""
import datetime
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
from fm_conventions import read_policy, request_reviewers
from fm_watch import Locked, read_json, save_json, notify
from fm_autopilot_loop import MechanicalLoop
from fm_autopilot_branches import BranchUpdates, ERRORS
import fm_merge_authorization as merge_authorization

BIN = Path(__file__).resolve().parents[1]
DEFAULTS = dict(watch_seconds=60, debounce_seconds=180, reinspect_seconds=86400,
                post='comments', land='card', review='fm', stacking='hold',
                force_with_lease=False, reviewers=[])


def context():
    return dict(engine=os.environ['FM_ENGINE_ROOT'], state=os.environ['FM_STATE_DIR'],
                target=os.environ['FM_TARGET_ROOT'], tasks=os.environ['FM_TASKS_DIR'], design=os.environ.get('FM_DESIGN'),
                project=os.environ.get('FM_PROJECT', ''), default_project=os.environ.get('FM_AUTOPILOT_DEFAULT_PROJECT', ''), repository=os.environ['FM_AUTOPILOT_REPOSITORY'],
                base=os.environ.get('FM_BASE') or 'main', external=os.environ['FM_EXTERNAL'] == '1',
                evidence_project=os.environ['FM_EVIDENCE_PROJECT'])


def key(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:32]


class Pilot(BranchUpdates, MechanicalLoop):
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
        for name, default in dict(offset=0, wake_offset=0, seen={}, batches={},
                                  wakes={}, pulls={}, cache={}, failures=0, next_poll=0,
                                  poll_seq=0, retries={}, holds={}, updates={}, advanced={}, rechecked={}, restacks={}).items():
            self.data.setdefault(name, default)
        if not self.data.get('migrated_t205'):
            for token, action in self.data.get('actions', {}).items():
                identity = action.get('identity') or []
                kind = identity[0] if identity else None
                status = action.get('state')
                wake = 'autopilot-' + key([ctx['project'], 'action-' + token])
                if kind == 'pr-event' and status != 'done' and len(identity) == 3 and identity[2] in ('merged', 'closed'):
                    previous = self.data['pulls'].get(str(identity[1]), {})
                    if previous.get('terminal'):
                        previous['event_pending'] = identity[2]
                if kind in ('update', 'advance', 'restack', 'recheck', 'observed-merge', 'pr-event') or status == 'done':
                    if not self.data['wakes'].get(wake, {}).get('pushed'):
                        self.data['wakes'].pop(wake, None)
                elif status == 'started' and wake not in self.data['wakes']:
                    self.queue('action-' + token, action.get('task', ''),
                               'Autopilot stopped during an action; reconcile its outcome',
                               '自動駕駛於步驟執行中停止；請核對結果')
                # Preserve the old one-review-per-head hold even if launch never
                # reached start_job. Legacy jobs match through their packet.
                if (kind == 'launch-review' and status in ('started', 'uncertain')
                        and len(identity) == 3 and type(identity[1]) is int
                        and isinstance(identity[2], str) and re.fullmatch(r'[0-9a-fA-F]{40}', identity[2])
                        and self.job_for('review', identity[1], identity[2]) is None):
                    number, head = identity[1:]
                    self.data.setdefault('jobs', {})[key(['review-launch', number, head])] = dict(
                        kind='review', task=action.get('task', ''), number=number, head=head,
                        state='uncertain', path='')
            self.data.pop('actions', None)
            self.data['migrated_t205'] = True
        # Existing installations establish the remote boundary on upgrade.
        self.data.setdefault('tracking_started', self.clock())
        if 'legacy_ask_records' not in self.data:
            from fm_evidence import Store
            # Legacy wake keys are hashed, so retain the existing ASK identities
            # for their tasks once, before polling. At use time the legacy key
            # must also match the PR and head. Do not extend this snapshot on
            # restart: later questions at the same head need their own wake.
            tasks = {wake.get('task') for wake in self.data['wakes'].values() if wake.get('task')}
            self.data['legacy_ask_records'] = sorted({key(record) for task in tasks
                for record in Store(str(self.state), ctx['evidence_project'], task,
                                    external=ctx['external']).records()
                if record.get('kind') == 'ask'})
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
        merge_authorization.refresh(self)

    def save(self):
        save_json(self.path, self.data)

    def refresh_queue(self):
        """Lazy loading preserves legacy frozen and isolated engine fixtures."""
        self.queue_mode, self.queue_policy = 'off', None
        path = self.directory / 'queue-policy.json'
        if not path.exists() and not path.is_symlink() and 'self_queue' not in self.data:
            return
        try:
            import fm_autopilot_queue as Q
        except ImportError:
            try:
                value = json.loads(path.read_text())
                if (not path.is_symlink() and not any(p.is_symlink() for p in path.parents)
                        and isinstance(value, dict) and value.get('enabled') is False
                        and 'self_queue' not in self.data):
                    return
            except (OSError, ValueError):
                pass
            self.queue_mode = 'off' if self.ctx['external'] else 'hold'
            self.queue('queue-helper-missing', '', 'Queue helper unavailable; reload supported code',
                       '佇列輔助程式無法使用；請重載受支援的程式')
            return
        policy, error = Q.load_policy(self.state, self.ctx['repository'], self.ctx['base'],
                                     self.ctx['project'] or 'firstmate-workflow', self.ctx['external'])
        if error:
            self.queue('queue-' + error, '', 'Self queue held: ' + error + '; validate policy and captain record',
                       '自身佇列暫緩：' + error + '；請驗證政策與船長紀錄')
        if self.ctx['external']: return
        q = self.data.get('self_queue')
        if q is not None:
            try: Q.validate_queue(q, self.ctx['repository'], self.ctx['base'])
            except (ValueError, TypeError):
                self.queue_mode = 'hold'
                self.queue('queue-state-invalid', '', 'Self queue state invalid; reconcile without resetting it',
                           '自身佇列狀態無法驗證；請核對，勿重設')
                return
        if error:
            self.queue_mode = 'hold'
            return
        self.queue_policy = policy
        if policy and policy['enabled'] and not getattr(self, '_queue_service_owned', False):
            # Only the owned resident service may acquire or mutate the queue.
            self.queue_mode = 'hold'
            return
        if policy and policy['enabled']:
            self.queue_mode = 'enabled'
            if q is None:
                self.data['self_queue'] = Q.new_queue(policy)
                self.save()
            elif q['policy_digest'] != Q.policy_digest(policy):
                # A live turn cannot be replaced by a different approved cohort.
                if q['front'] is not None:
                    self.queue_mode = 'hold'
                else:
                    q['policy_digest'] = Q.policy_digest(policy)
                    for m in q['members'].values():
                        m['attempt_generation'] += 1
            self.data['self_queue']['enabled'] = True
        elif q and (q['front'] is not None or self.queue_reservation()
                    or any(m['state'] == 'uncertain' for m in q['members'].values())
                    or any(j.get('state') in ('running', 'consuming', 'uncertain')
                           for j in self.data.get('jobs', {}).values())):
            q['enabled'] = False
            self.queue_mode = 'drain'
        elif q:
            q['enabled'] = False
        self.save()

    def queue_reservation(self):
        import fm_autopilot_queue as Q
        from fm_merge_outcome import merge_outcome
        project = self.ctx['project'] or 'firstmate-workflow'
        try:
            if list((self.state / 'merging').glob('*.json')): return True
            for folder in ('pending', 'decisions'):
                for path in (self.state / folder).glob('*.json'):
                    r = Q.read(path)
                    if r.get('project') not in (None, '', project): continue
                    if r.get('kind') not in ('merge', 'merge-untracked'): continue
                    if folder == 'pending': return True
                    if (Q.effect(r, r.get('chosen')) == 'merge'
                            and merge_outcome(r) not in ('merged', 'failed')): return True
            return False
        except (ValueError, OSError, AttributeError, TypeError):
            return True

    def queue_release(self, number):
        if self.queue_reservation(): return
        import fm_autopilot_queue as Q
        m = self.data['self_queue']['members'][number]
        if m['request'] and m['request']['state'] != 'settled': return
        Q.release(self.data['self_queue'], number, self.clock())

    def queue_eligible(self, pr):
        """Use the stock approved-pin resolver, including supported legacy pins."""
        task = self.task(pr)
        if not task: return '', 'untracked'
        if pr.get('state') != 'open': return task, 'closed'
        if pr.get('draft'): return task, 'draft'
        if pr['base']['ref'] != self.ctx['base']: return task, 'stack-on-task'
        if pr['head'].get('repo', {}).get('full_name') != self.ctx['repository']:
            return task, 'ownership'
        if self.round_live(task): return task, 'live-worker'
        from fm_spec_pins import Pins
        try:
            pins = Pins(self.adoption_env(), task)
            pin = pins.resolve()
            spec = json.loads(pin['snapshots']['spec']['text'])
        except (OSError, ValueError, TypeError, KeyError):
            return task, 'approved-pin-unavailable'
        if not any(r.get('task') == task and r.get('type') in ('dispatched', 'worker_started', 'agent_started', 'commit_pushed')
                   for r in self.rows()):
            return task, 'dispatch-provenance-unavailable'
        merged = {r.get('task') for r in self.rows() if r.get('type') == 'merged'}
        if any(dep not in merged for dep in spec.get('depends_on', [])):
            return task, 'dependencies-unresolved'
        return task, ''

    def queue_snapshot(self, snapshots, base):
        import fm_autopilot_queue as Q
        if not getattr(self, '_queue_service_owned', False):
            self.queue_mode = 'hold'
            self.queue('queue-owner-unverified', '', 'Self queue owner is unverified; use the owned resident service',
                       '自身佇列擁有者無法驗證；請使用受管理的常駐服務')
            return
        if self.queue_mode == 'hold': return
        q = self.data['self_queue']; now = self.clock()
        # Legacy jobs are never adopted by an activation. They finish under
        # their original owner, but their results cannot launch a continuation.
        outstanding = any(j.get('state') in ('running', 'consuming', 'uncertain') and not j.get('queue_binding')
                          for j in self.data.get('jobs', {}).values())
        if outstanding:
            self._queue_snapshot_ready = False
            self.queue('queue-activation-drain', '', 'Self queue observes legacy jobs; reconcile owners before activation',
                       '自身佇列正觀察既有工作；啟用前請核對擁有者')
            return
        if q['front'] is None and self.queue_reservation():
            self._queue_snapshot_ready = False
            self.queue('queue-activation-card-drain', '', 'Self queue observes an existing merge reservation; reconcile its outcome',
                       '自身佇列正觀察既有合併保留；請核對結果')
            return
        for number in sorted(snapshots, key=int):
            pr, reviews, comments, runs, statuses = snapshots[number]
            task, reason = self.queue_eligible(pr)
            if not task:
                if number in q['members']:
                    Q.transition(q, number, 'uncertain', 'task-ownership-unreconciled', now)
                continue
            m = q['members'].get(number)
            if m is None:
                m = dict(task=task, admission_sequence=q['next_sequence'], head=pr['head']['sha'],
                         base_sha=base, state='observed', reason='', attempt_generation=0,
                         failed_fingerprint=None, resume_decision=None, request=None, jobs=[], card_id=None,
                         timestamps={})
                q['members'][number] = m; q['next_sequence'] += 1
            elif m['task'] != task:
                Q.transition(q, number, 'uncertain', 'task-ownership-changed', now)
                continue
            if pr.get('merged_at'):
                if any(r.get('type') == 'merged' and str(r.get('pr')) == number for r in self.rows()):
                    identity = 'landing:' + number
                    if identity not in q['accounted']:
                        q['accounted'].append(identity)
                        q['counters']['completed_landings'] += 1
                    if m['request']:
                        m['request'].update(state='settled', outcome='authoritative-merge-reconciled')
                    Q.transition(q, number, 'landed', 'authoritative-merge-reconciled', now)
                    Q.release(q, number, now)
                else: Q.transition(q, number, 'uncertain', 'merge-event-unreconciled', now)
                continue
            owned_jobs = [self.data.get('jobs', {}).get(ident, {}) for ident in m['jobs']]
            if any(j.get('state') in ('consuming', 'uncertain') for j in owned_jobs):
                Q.transition(q, number, 'uncertain', 'owned-job-unreconciled', now)
                continue
            if m['card_id']:
                card = m['card_id']
                pending = self.state / 'pending' / (card + '.json')
                answered = self.state / 'decisions' / (card + '.json')
                from fm_merge_outcome import merge_outcome
                if pending.exists():
                    Q.transition(q, number, 'waiting-captain', 'pending-captain-card', now)
                elif answered.exists():
                    record = Q.read(answered)
                    outcome = merge_outcome(record)
                    if outcome == 'running':
                        if not self.queue_carry_active(task, pr):
                            Q.transition(q, number, 'uncertain', 'merge-helper-owner-unreconciled', now)
                            continue
                        Q.transition(q, number, 'merging', 'captain-merge-running', now)
                    elif outcome == 'failed':
                        events = [r for r in self.rows() if r.get('actor') == 'captain'
                                  and r.get('type') == 'decision_made' and r.get('task') == task
                                  and r.get('data', {}).get('decision') == card
                                  and r.get('data', {}).get('merge') == 'failed'
                                  and r.get('data', {}).get('outcome') == 'failed']
                        if not events or list((self.state / 'merging').glob('*.json')):
                            Q.transition(q, number, 'uncertain', 'merge-failure-unreconciled', now)
                            continue
                        elif record.get('expected_head') != pr['head']['sha']:
                            m['card_id'] = None
                        else:
                            m['failed_fingerprint'] = key(['merge-failed', card, m['head'], record.get('merge_settled')])
                            Q.transition(q, number, 'blocked', 'failed-captain-merge', now)
                            self.queue_release(number)
                            continue
                    elif outcome not in ('merged', 'failed') and not Q.cancelled_card(
                            self.state, self.ctx['project'] or 'firstmate-workflow', card, task):
                        Q.transition(q, number, 'uncertain', 'captain-answer-unreconciled', now)
                        continue
                else:
                    Q.transition(q, number, 'uncertain', 'card-request-outcome-unreconciled', now)
                    continue
            parks = [r for r in self.rows() if r.get('task') == task and r.get('type') in ('parked', 'unparked')]
            if parks and parks[-1]['type'] == 'parked':
                if m['card_id'] and not Q.cancelled_card(self.state, self.ctx['project'] or 'firstmate-workflow',
                                                       m['card_id'], task):
                    continue
                if list((self.state / 'merging').glob('*.json')):
                    Q.transition(q, number, 'uncertain', 'merge-owner-unreconciled', now)
                    continue
                if m['request'] and m['request']['state'] != 'settled':
                    Q.transition(q, number, 'uncertain', 'park-awaits-update-reconciliation', now)
                    continue
                Q.transition(q, number, 'parked', 'captain-parked', now)
                Q.release(q, number, now)
                continue
            changed_head = m['head'] != pr['head']['sha']
            request = m['request']
            if request and request['state'] != 'settled':
                # A response lost after PUT is never retried on a timer. The
                # supervisor must verify the actual update's ancestry first.
                if changed_head:
                    try:
                        self.prepare_head(pr)
                        git = ['git', '-C', self.ctx['target']]
                        self.checked([*git, 'merge-base', '--is-ancestor', request['H'], pr['head']['sha']])
                        self.checked([*git, 'merge-base', '--is-ancestor', request['B'], pr['head']['sha']])
                        commits = self.checked([*git, 'rev-list', '--first-parent',
                                               request['H'] + '..' + pr['head']['sha']]).splitlines()
                        if not commits or self.task(pr) != m['task']:
                            raise ValueError('update ancestry unavailable')
                        for commit in commits:
                            parents = self.checked([*git, 'show', '-s', '--format=%P', commit]).split()
                            if len(parents) != 2: raise ValueError('unrelated worker push')
                            self.checked([*git, 'merge-base', '--is-ancestor', parents[1], request['B']])
                        from fm_binding import change
                        ancestor = self.checked([*git, 'merge-base', request['H'], request['B']]).strip()
                        before = change(self.ctx['target'], request['H'], ancestor)
                        after = change(self.ctx['target'], pr['head']['sha'], request['B'])
                        if any(before[k] != after[k] for k in ('patch', 'files')):
                            raise ValueError('update changed task patch')
                        request.update(state='settled', outcome='verified-base-update')
                    except (KeyError, ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
                        if isinstance(error, ValueError) and str(error) in ('unrelated worker push', 'update changed task patch'):
                            request.update(state='settled', outcome='candidate-invalidated')
                        else:
                            Q.transition(q, number, 'uncertain', 'update-ancestry-unreconciled', now)
                            continue
                else:
                    Q.transition(q, number, 'updating' if request['state'] == 'accepted' else 'uncertain',
                                 'update-outcome-unreconciled', now)
                    continue
            if changed_head or m['base_sha'] != base:
                m.update(head=pr['head']['sha'], base_sha=base, attempt_generation=m['attempt_generation'] + 1,
                         request=None)
                if changed_head: m.update(failed_fingerprint=None, resume_decision=None)
            if m['failed_fingerprint'] and not changed_head:
                resume = m.get('resume_decision')
                note = f'Queue resume: PR {number} head {m["head"]} failed fingerprint {m["failed_fingerprint"]}'
                if not resume:
                    for path in sorted((self.state / 'decisions').glob('*.json')):
                        cause = f'resume:{path.stem}:{number}:{m["failed_fingerprint"]}'
                        if (cause not in q['accounted'] and Q.decision_authority(
                                self.state, self.ctx['project'] or 'firstmate-workflow', path.stem, note)):
                            resume = path.stem
                            m['resume_decision'] = resume
                            break
                cause = f'resume:{resume}:{number}:{m["failed_fingerprint"]}'
                if (cause in q['accounted'] or not Q.decision_authority(
                        self.state, self.ctx['project'] or 'firstmate-workflow', resume, note)):
                    Q.transition(q, number, 'blocked', 'failed-attempt-needs-approved-resume', now)
                    self.queue_release(number)
                    continue
                q['accounted'].append(cause)
                m.update(failed_fingerprint=None, attempt_generation=m['attempt_generation'] + 1)
            if reason:
                Q.transition(q, number, 'blocked', reason, now)
                continue
            checks = self.settled_checks(pr, runs, statuses)
            verdict = self.verdict(task)
            failed = checks is not None and any(c[-1] not in ('success', 'neutral', 'skipped') for c in checks)
            rejected = verdict.get('head') == m['head'] and verdict.get('verdict') == 'REJECT'
            if failed or rejected:
                m['failed_fingerprint'] = key([m['head'], checks, verdict if rejected else None])
                Q.transition(q, number, 'blocked', 'rejected-review' if rejected else 'failed-ci', now)
                self.queue_release(number)
            elif q['front'] != number:
                Q.transition(q, number, 'queued', 'waiting-for-front', now)
            elif checks is None:
                Q.transition(q, number, 'waiting-ci', 'required-checks-pending', now)
        if q['front'] is None and self.queue_mode == 'enabled' and not self.queue_reservation():
            eligible = [n for n,m in q['members'].items() if n in snapshots and m['state'] == 'queued'
                        and not m['failed_fingerprint'] and int(n) in self.queue_policy['cohort']]
            if eligible:
                n = min(eligible, key=lambda n:q['members'][n]['admission_sequence'])
                q['front'] = n; q['members'][n]['timestamps']['acquired'] = now
                Q.transition(q, n, 'front', 'front-acquired', now)
                if self.settled_checks(snapshots[n][0], snapshots[n][3], snapshots[n][4]) is None:
                    Q.transition(q, n, 'waiting-ci', 'required-checks-pending', now)
        self._queue_snapshot_ready = True
        for number, m in q['members'].items():
            stamp = m['timestamps'].get('transition', 0)
            self.queue(f'queue-transition-{number}-{m["attempt_generation"]}-{stamp}', m['task'],
                       f'{m["task"]} #{number}: {m["state"]}; {m["reason"]}; H={m["head"]} B={m["base_sha"]}; generation={m["attempt_generation"]}; next: observe or reconcile',
                       f'{m["task"]} #{number}：{m["state"]}；{m["reason"]}；H={m["head"]} B={m["base_sha"]}；世代={m["attempt_generation"]}；下一步：觀察或核對')
        self.save()

    def queue_guard(self, pr, packet=None, *, update=False):
        packet = packet if packet is not None else getattr(self, '_queue_continuation', None)
        self.refresh_queue()
        mode = getattr(self, 'queue_mode', 'off')
        if mode == 'off': return True
        if mode == 'hold': return False
        if not getattr(self, '_queue_service_owned', False): return False
        if packet is None and not getattr(self, '_queue_snapshot_ready', False): return False
        import fm_autopilot_queue as Q
        q = self.data['self_queue']; number = str(pr['number'])
        m = q['members'].get(number)
        if (q['front'] != number or not m or m['state'] in ('blocked', 'parked', 'uncertain', 'landed')
                or m['head'] != pr['head']['sha'] or m['base_sha'] != pr['base']['sha']): return False
        request = m['request']
        if request and request['state'] != 'settled' and not (update and request['state'] == 'planned'):
            return False
        if packet is not None and packet.get('queue_binding') != Q.binding(q, m): return False
        current = self.api('pulls/' + number)
        from urllib.parse import quote
        base = self.api('branches/' + quote(self.ctx['base'], safe=''))['commit']['sha']
        if (current.get('state') != 'open' or current.get('draft') or current['head']['sha'] != m['head']
                or base != m['base_sha'] or current['base']['ref'] != self.ctx['base']
                or self.task(current) != m['task'] or self.round_live(m['task'])): return False
        return True

    def queue_carry_active(self, task, pr):
        """Recognize only a bound, running stock merge keeper for this front."""
        if getattr(self, 'queue_mode', 'off') not in ('enabled', 'drain'): return False
        q = self.data['self_queue']; number = str(pr['number'])
        if q['front'] != number: return False
        m = q['members'][number]
        if not m.get('card_id'): return False
        try:
            import fm_autopilot_queue as Q
            record = Q.read(self.state / 'decisions' / (m['card_id'] + '.json'))
            marker = Q.read(self.state / 'merging' / ((self.ctx['project'] or '_default') + '.json'))
            if (record.get('merge') != 'running' or record.get('effect') != 'merge'
                    or record.get('task') != task or record.get('pr') != pr['number']
                    or not record.get('binding', {}).get('signature')
                    or marker.get('decision') != m['card_id'] or marker.get('task') != task
                    or marker.get('pr') != pr['number'] or not Q.integer(marker.get('pid'), 2)):
                return False
            pid = str(marker['pid'])
            started = self.checked(['ps', '-p', pid, '-o', 'lstart=']).strip()
            if ' '.join(started.split()) != marker.get('started'): return False
            command = self.checked(['ps', '-p', pid, '-o', 'command='])
            import shlex
            argv = shlex.split(command)
            if not any(a.endswith('/fm_lifeline.py') for a in argv) or 'keep' not in argv:
                return False
            if not any(a.endswith('/fm-merge.sh') for a in argv): return False
            for flag, value in (('--pr', number), ('--task', task), ('--expected-head', record['expected_head']),
                                ('--bound-signature', record['binding']['signature'])):
                if flag not in argv or argv[argv.index(flag) + 1] != value: return False
            owner = int(argv[argv.index('--pid') + 1])
            life.ProcessExit(owner).close()
            return True
        except (OSError, ValueError, TypeError, AttributeError, KeyError, IndexError, RuntimeError, subprocess.SubprocessError):
            return False

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

    def probe(self, argv):
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, text=True,
                                capture_output=True, timeout=120)
        return result.returncode, result.stdout, result.stderr

    def checked(self, argv):
        rc, stdout, stderr = self.probe(argv)
        if rc:
            raise self.probe_error(argv, stderr)
        return stdout

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
        # Execute the endpoint so its shebang selects the interpreter, as
        # the retired turn did for gates, protocol, review and decisions.
        return [str(BIN / name), *map(str, args), '--repo', str(self.root),
                *(['--project', self.ctx['project']] if self.ctx['project'] else [])]

    def gh(self, *args):
        return [os.environ.get('FM_GH', 'gh'), *map(str, args)]

    def emit(self, kind, task, en, tw, pr=None, actor='autopilot'):
        self.command(['bash', str(BIN / 'fm-emit.sh'), '--actor', actor, '--type', kind,
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
        merge_authorization.tick(self, key)
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

    def recover(self):
        for number, record in self.data['restacks'].items():
            if record['outcome'] == 'started':
                self.restack_interrupted(number, record)

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
        task = self.pr_task(pr)
        reason = getattr(self, '_adopt_reason', '') or 'branch/title does not identify a task'
        if task:
            try:
                spec = self.read_head_spec(pr, task)
                if not isinstance(spec, dict) or spec.get('id') != task:
                    raise ValueError('committed task spec identity mismatch')
                return task
            except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
                reason = str(error)
            try:
                from fm_spec_pins import Pins
                env = self.adoption_env()
                pin = Pins(env, task).resolve(if_present=True)
                if pin is not None:
                    return task
                reason += '; no authorized pin'
            except (ValueError, OSError, KeyError, TypeError) as error:
                reason += '; ' + str(error)
        # Retain the diagnostic without creating a wake on every poll. Retry
        # resolution next time: a missing object or pin can become available.
        record = self.data['pulls'].setdefault(str(pr['number']), {})
        unresolved = dict(head=pr['head']['sha'], branch=pr['head']['ref'], reason=reason)
        if any(record.get(k) != v for k, v in unresolved.items()):
            record.pop('task', None)
            record.update(unresolved)
            self.save()
        return ''

    def read_head_spec(self, pr, task):
        from fm_binding import sha, fetch_ref
        head = sha(pr['head']['sha'])
        prefix = ['git', '-C', self.ctx['target']]
        # Local reads do not enter the side-effect command channel. Fetch only
        # when the immutable head object is missing, without moving task refs.
        available = subprocess.run([*prefix, 'cat-file', '-e', head + '^{commit}'],
                                   capture_output=True, timeout=120)
        if available.returncode:
            fetched = fetch_ref(self.ctx['target'], 'https://github.com/' + self.ctx['repository'] + '.git',
                                'refs/pull/' + str(pr['number']) + '/head', runner=self.command)
            if fetched != head:
                raise ValueError('PR head moved while resolving task')
        result = subprocess.run([*prefix, 'show', head + ':design/tasks/' + task + '.json'],
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise ValueError('committed task spec unavailable at PR head')
        return json.loads(result.stdout)

    def recheck(self, task, pr, reviews):
        number, head = str(pr['number']), pr['head']['sha']
        names = self.data['rechecked'][number]['names']
        requested = {r.get('login', '').lower() for r in pr.get('requested_reviewers', [])}
        for name in list(names):
            kind = 'recheck-' + name.lower()
            token = f'{kind}:{number}:{head}'
            if self.policy['post'] == 'local' and not self.ctx['external']:
                self.queue(key(['recheck', pr['number'], head, name]), task,
                           'Reviewer re-check needed: ' + name, '需要審查者重新檢查：' + name)
                names.remove(name)
                self.data['retries'].pop(token, None)
                continue
            if name.lower() in requested or any(
                    r.get('user', {}).get('login', '').lower() == name.lower()
                    and r.get('commit_id') == head for r in reviews):
                names.remove(name)
                self.data['retries'].pop(token, None)
                continue
            if not self.retry_due(token):
                continue
            try:
                rc, out, err = self.probe(self.gh('api', '-X', 'POST',
                    f"repos/{self.ctx['repository']}/pulls/{number}/requested_reviewers",
                    '-f', 'reviewers[]=' + name, '--include'))
                normalized = out.replace('\r\n', '\n')
                status = re.match(r'^(HTTP/\S+ ([0-9]{3})[^\n]*)', normalized)
                line = status[1] if status else (err.strip().splitlines()[-1] if err.strip() else 'missing HTTP status line')
                code = int(status[2]) if status else None
                if code == 201:
                    names.remove(name)
                    self.data['retries'].pop(token, None)
                    continue
                if code == 422:
                    message = json.loads(normalized.partition('\n\n')[2])['message']
                    names.remove(name)
                    self.data['retries'].pop(token, None)
                    self.queue(f'recheck-refused-{number}-{head}-{name}', task,
                               f'{task} #{number} reviewer re-check refused: {name}: {message}',
                               f'{task} #{number} 審查者重新檢查請求遭拒：{name}：{message}')
                    continue
            except ERRORS as error:
                line = str(error)
            self.branch_failure(kind, number, head, task, line)

    def restack(self, pr, parent):
        task = self.task(pr)
        if not task or not parent.get('merged_at'):
            return
        if self.policy['stacking'] != 'allowed' or self.policy['force_with_lease'] is not True:
            self.queue('restack-held-' + str(pr['number']), task, 'Merged stack base needs confirmed restack policy',
                       '堆疊基底已合併；需確認重設基底政策')
            return
        number, head = str(pr['number']), pr['head']['sha']
        record = self.data['restacks'].get(number, {})
        if record.get('parent') == parent['number']:
            if record.get('outcome') == 'published':
                return
            if record.get('outcome') == 'started':
                self.restack_interrupted(number, record)
                return
            if record.get('head') == head:
                return
        if self.round_live(task) or self.busy(task):
            return
        token = f'restack:{number}:{head}'
        if not self.retry_due(token):
            return
        record = dict(head=head, parent=parent['number'], task=task, outcome='started')
        self.data['restacks'][number] = record
        self.save()
        try:
            rc, out, err = self.probe(self.script('lib/fm-restack.sh', '--pr', number,
                                                '--parent', parent['number'], '--expected-head', head))
            line = next((line.strip() for line in reversed(err.splitlines()) if line.strip()), 'command failed')
        except subprocess.TimeoutExpired:
            self.restack_interrupted(number, record)
            return
        except Exception as error:
            # Failure to start has no helper-side effect and may be retried.
            rc, line = 65, str(error)
        if rc not in (0, 64, 65, 66, 67, 68, 69, 70, 75):
            self.restack_interrupted(number, record)
            return
        if rc == 75:
            del self.data['restacks'][number]
            self.save()
            return
        outcome = {0: 'done', 66: 'conflict', 69: 'published'}.get(rc)
        if rc == 67:
            try:
                fresh = json.loads(self.command(self.gh('pr', 'view', number, '--repo',
                                                       self.ctx['repository'], '--json', 'headRefOid')))
                if fresh['headRefOid'] != head:
                    outcome = 'moved'
            except (ValueError, KeyError, TypeError, RuntimeError, OSError, subprocess.SubprocessError):
                pass
        if outcome:
            record['outcome'] = outcome
            self.data['retries'].pop(token, None)
            if rc == 66:
                self.queue(f'restack-conflict-{number}-{head}', task,
                           f'{task} #{number} restack hit a rebase conflict; resolve by hand: {line}',
                           f'{task} #{number} 重新堆疊遇到 rebase 衝突；需手動處理：{line}')
            elif rc == 69:
                self.queue(f'restack-published-{number}-{head}', task,
                           f'{task} #{number} restack published but did not finish; synchronize and finish before review: {line}',
                           f'{task} #{number} 重新堆疊已發布但未完成；請同步並完成後再審查：{line}')
            self.save()
            return
        del self.data['restacks'][number]
        self.branch_failure('restack', number, head, task, line)

    def restack_interrupted(self, number, record):
        task, head = record['task'], record['head']
        self.queue(f'restack-interrupted-{number}-{head}', task,
                   f'{task} #{number} restack outcome unknown (timed out or interrupted); reconcile before review',
                   f'{task} #{number} 重新堆疊結果不明（逾時或中斷）；審查前請先核對')

    def external_evidence(self, task, pr):
        """Refresh the existing private store; retain only bounded wake metadata."""
        failure = None
        try:
            output = self.command(self.script('fm-external.sh', 'collect', '--task', task,
                '--pr', str(pr['number']), '--branch', pr['head']['ref']))
        except Exception:
            failure = 'command'
        if failure is None:
            try:
                record = json.loads(output)
                if not isinstance(record, dict):
                    failure = 'json'
            except (ValueError, TypeError):
                failure = 'json'
        if failure is None:
            if (not isinstance(record.get('head'), str)
                    or not re.fullmatch(r'[0-9a-fA-F]{40}', record['head'])
                    or type(record.get('ready')) is not bool
                    or not isinstance(record.get('findings'), list)):
                failure = 'fields'
            elif record['head'] != pr['head']['sha']:
                failure = 'stale-head'
        if failure:
            self.attention('external-evidence-' + failure, task, pr,
                           'external evidence refresh failed: ' + failure,
                           '外部證據更新失敗：' + failure)
            return None
        return dict(ready=record['ready'], head=record['head'], count=len(record['findings']))

    def pull(self, pr, reviews, comments, runs, statuses):
        if pr['state'] != 'open' or self.policy_error or pr['head']['ref'] == self.ctx['base']:
            return
        number, head = str(pr['number']), pr['head']['sha']
        self.prune_branches(number, head)
        task = self.task(pr)
        if not task: return
        old = self.data['pulls'].get(number)
        if self.ctx['external']:
            record = self.data['rechecked'].get(number, {})
            if record.get('head') != head or record.get('rule') != 'external-request':
                author = (pr.get('user') or {}).get('login', '').lower()
                names = [name for name in request_reviewers(self.policy) if name.lower() != author]
                self.data['rechecked'][number] = dict(head=head, names=names, rule='external-request')
        elif old and old.get('head') and old['head'] != head:
            names = []
            for name in self.policy.get('reviewers', []):
                prior = [r for r in reviews if r.get('user', {}).get('login', '').lower() == name.lower()]
                if prior and not any(r.get('commit_id') == head for r in prior):
                    names.append(name)
            self.data['rechecked'][number] = dict(head=head, names=names)
        if self.data['rechecked'].get(number, {}).get('head') == head:
            self.recheck(task, pr, reviews)
        self.data['pulls'][number] = dict(task=task, head=head, branch=pr['head']['ref'], base=pr['base']['ref'], base_sha=pr['base']['sha'])
        try:
            queue_mode = getattr(self, 'queue_mode', 'off')
            behind_front = (queue_mode in ('enabled', 'drain') and pr.get('mergeable') is True
                            and pr.get('mergeable_state') == 'behind')
            if (queue_mode == 'off' or (not behind_front and self.queue_guard(pr))) and self.sync_branch(pr, task):
                self.advance(pr, runs, statuses)
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
            self.attention('advance-error', task, pr, f'{task}: advancement needs reconciliation: {error}',
                           f'{task}：機械流程需要 firstmate 核對')
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
        external_reviews = self.ctx['external'] and self.policy['review'] in ('external', 'both')
        named_reviewers = {name.lower() for name in self.policy.get('reviewers', [])}
        refreshed, evidence = False, None
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
                line = f"{task} #{number} {reviewer}: {row.get('state') or kind} {row.get('html_url') or row.get('id')}"
                if external_reviews and reviewer.lower() in named_reviewers:
                    if not refreshed:
                        evidence = self.external_evidence(task, pr)
                        refreshed = True
                    source = 'review' if kind == 'review' else row.get('_source') or 'comment'
                    batchkey += ':' + source + ':' + str(row.get('id'))
                    status = ('ready' if evidence['ready'] else 'blocked') if evidence else 'unknown'
                    count = f", {evidence['count']} finding(s)" if evidence else ''
                    label = row.get('state') if kind == 'review' else source
                    line = (f"{task} #{number} {reviewer} {label} {row.get('id')}: external evidence "
                            f"{status} at {head[:7]}{count}; read fm_external findings for the task")
                batch = self.data['batches'].setdefault(batchkey, dict(task=task, lines=[]))
                batch['lines'].append(line)
                batch['due'] = self.clock() + self.policy['debounce_seconds']
        # External repositories may never report BEHIND without protection.
        if self.ctx['external']:
            import fm_adopt
            adopted = self.adoptions()[0].get(pr['number']) == task
            can_update = not adopted or fm_adopt.pushed(self.rows(), task, pr['number'])
            if adopted:
                env = self.adoption_env()
                try:
                    fm_adopt.effective_base({'baseRefName': pr['base']['ref']},
                                            fm_adopt.adoption(env, task), env, task, self.ctx['repository'])
                except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
                    can_update = False
                    self.queue(f'adopt-base-{number}', task,
                               f'{task} #{number}: adopted base needs verified restack',
                               f'{task} #{number} 接手基底需要經驗證的 restack')
            if can_update and pr.get('mergeable') is not False and not pr.get('draft'):
                token = f'update:{number}:{head}'
                if self.retry_due(token):
                    try:
                        behind = self.external_behind(pr)
                        if behind == 'unknown':
                            self.branch_failure('update', number, head, task, 'could not determine base ancestry')
                        elif behind == 'behind':
                            self.update_external_branch(pr, task)
                    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
                        if self.retry_due(token):
                            self.branch_failure('update', number, head, task, str(error))
        # Self: REST mergeable=True is gh's MERGEABLE; unknown/null never authorizes.
        elif pr.get('mergeable') is True and pr.get('mergeable_state') == 'behind' and not pr.get('draft'):
            try:
                self.update_branch(pr, task)
            except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
                token = f'update:{number}:{head}'
                if self.retry_due(token):
                    self.branch_failure('update', number, head, task, str(error))
        self.save()

    def poll(self):
        self.data['poll_seq'] += 1
        self.refresh_queue()
        self._queue_snapshot_ready = False
        if self.policy_error:
            self.data['next_poll'] = self.clock() + self.policy['watch_seconds']
            return
        try:
            self._poll_rows = self.rows()
            if self.ctx['external']:
                self.adoptions()
            pulls = self.pages('pulls?state=open')
            queue_snapshots = {}
            if getattr(self, 'queue_mode', 'off') in ('enabled', 'drain'):
                from urllib.parse import quote
                base = self.api('branches/' + quote(self.ctx['base'], safe=''))['commit']['sha']
                cohort = (self.queue_policy['cohort'] if self.queue_policy and self.queue_policy['enabled']
                          else [int(n) for n in self.data['self_queue']['members']])
                for n in sorted(cohort):
                    pr = self.api('pulls/' + str(n))
                    head = pr['head']['sha']
                    reviews = self.pages(f'pulls/{n}/reviews')
                    comments = self.pages(f'pulls/{n}/comments')
                    runs = self.api(f'commits/{head}/check-runs?per_page=100')
                    statuses = self.api(f'commits/{head}/status?per_page=100')
                    if (statuses.get('sha') != head or runs.get('total_count', 0) > 100
                            or statuses.get('total_count', 0) > 100):
                        raise ValueError('incomplete queue snapshot')
                    queue_snapshots[str(n)] = (pr, reviews, comments, runs['check_runs'], statuses['statuses'])
                if self.api('branches/' + quote(self.ctx['base'], safe=''))['commit']['sha'] != base:
                    raise ValueError('base changed during queue preparation')
                self.queue_snapshot(queue_snapshots, base)
                # Settlement may have completed a disable drain. Refresh
                # before per-PR work so legacy resumes its original ordering.
                self.refresh_queue()
            for item in pulls:
                self.observe_pr(item)
                # Track even an unrecognized PR: its eventual terminal event
                # belongs in the log, without inventing a task or a wake.
                self.data['pulls'].setdefault(str(item['number']), {}).pop('terminal', None)
            recent = self.api('pulls?state=closed&sort=updated&direction=desc&per_page=50')
            if not isinstance(recent, list):
                raise ValueError('incomplete GitHub recent closure list')
            for item in recent:
                if self.observed_closure(item): self.closed_pull(item)
            open_numbers = {str(item['number']) for item in pulls}
            for number, previous in list(self.data['pulls'].items()):
                if number not in open_numbers and (not previous.get('terminal') or previous.get('event_pending')):
                    self.closed_pull(self.api('pulls/' + number))
            for item in pulls:
                number = item['number']
                snapshot = queue_snapshots.get(str(number))
                pr = snapshot[0] if snapshot else self.api('pulls/' + str(number))
                if pr.get('state') == 'closed':
                    self.closed_pull(pr)
                    continue
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
                adopted = self.ctx['external'] and pr['number'] in self.adoptions()[0]
                if pr['base']['ref'] != self.ctx['base'] and (self.pr_task(pr) if adopted else self.task(pr)):
                    from urllib.parse import quote
                    parents = self.pages('pulls?state=closed&head=' + quote(self.ctx['repository'].split('/')[0] + ':' + pr['base']['ref'], safe=''))
                    for parent in parents:
                        if parent['head']['ref'] == pr['base']['ref'] and parent.get('merged_at'):
                            if adopted:
                                import fm_adopt
                                task = self.pr_task(pr)
                                env = self.adoption_env()
                                dependencies = (fm_adopt.authorized_spec(env, task) or {}).get('depends_on', [])
                                if self.pr_task(parent) not in dependencies:
                                    break
                                if not fm_adopt.pinned_adoption(env, task) or not fm_adopt.pushed(self.rows(), task, number):
                                    self.queue(f'adopt-restack-{number}', task,
                                               f'{task} #{number}: run fm-restack.sh before catch-up',
                                               f'{task} #{number} 追趕前請執行 fm-restack.sh')
                                    break
                            self.restack(pr, parent)
                            break
            self.network_success()
            self.inspect_policy()
        except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
            self.network_failure(str(error))
        finally:
            self._poll_rows = None

    def observed_closure(self, pr):
        if str(pr['number']) in self.data['pulls']: return True
        # updated_at can change on ancient PRs (comments, labels). Only the
        # terminal transition's own timestamp can cross the startup boundary.
        terminal = pr.get('merged_at') or pr.get('closed_at')
        try:
            timestamp = datetime.datetime.fromisoformat(terminal.replace('Z', '+00:00')).timestamp()
        except (AttributeError, ValueError):
            return False
        return timestamp >= self.data['tracking_started']

    def closed_pull(self, pr):
        if pr.get('state') != 'closed' or not self.observed_closure(pr): return
        number = str(pr['number'])
        previous = self.data['pulls'].get(number, {})
        if previous.get('terminal') and not previous.get('event_pending'):
            return
        kind = 'merged' if pr.get('merged_at') else 'closed'
        token = f'event-{kind}:{number}:{pr["head"]["sha"]}'
        self.observe_pr(pr)
        retry = self.data['retries'].get(token)
        pending = retry is not None and retry['count'] < 3
        if previous.get('terminal'):
            if not pending:
                previous.pop('event_pending', None)
                self.prune_branches(number)
            self.save()
            return
        task = self.task(pr)
        if task and not pr.get('merged_at'):
            self.queue('closed-' + number, task,
                       f'PR #{pr["number"]} closed without merging; task needs judgment',
                       f'PR #{pr["number"]} 已關閉但未合併；任務需要判斷')
        previous = self.data['pulls'].setdefault(number, {})
        if pending:
            previous['event_pending'] = kind
        else:
            previous.pop('event_pending', None)
        self.prune_branches(number, keep=token if pending else None)
        previous['terminal'] = True
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
        if (event.get('project') or self.ctx.get('default_project', self.ctx['project'])) != self.ctx['project']: return
        kind = event.get('type')
        task = event.get('task', '')
        data = event.get('data') or {}
        pr = event.get('pr')
        if task and isinstance(pr, int) and pr > 0 and re.fullmatch(r'(?:T|SK)-[0-9]+', task):
            tracked = self.data['pulls'].setdefault(str(pr), dict(task=task))
            if kind == 'merged':
                tracked['terminal'] = True
                self.prune_branches(str(pr))
        if kind in ('agent_finished', 'commit_pushed', 'pr_opened', 'approved', 'review_failed'):
            self.data['next_poll'] = 0
        reasons = dict(worker_crashed='Worker round failed', agent_lost='Round lost',
                       worker_note_unsent='Worker note unsent; run bin/fm.sh unsent --post',
                       review_failed='Review requires judgment', conventions_drift='Conventions drift',
                       gate_failed='Gate failed')
        reason = reasons.get(kind)
        if kind == 'agent_finished' and data.get('result') not in (None, 'ok', 'success'):
            reason = 'Round failed'
        if kind == 'decision_made' and (data.get('chosen') or data.get('answer')) in ('B','C'):
            reason = 'Captain answered ' + (data.get('chosen') or data.get('answer'))
        if kind == 'review_failed' and task and not self.busy(task):
            try: record = self.verdict(task)
            except (ValueError, OSError): record = {}
            if record.get('verdict') == 'REJECT':
                # Poll the authoritative PR before attributing this rejection
                # to a head. The same head's poll owns its one brief wake.
                reason = None
        if kind == 'gate_failed':
            from fm_binding import gate_list, gate_entry
            try:
                gate = gate_entry(data.get('gate'), gate_list())
            except ValueError:
                gate = None
            if gate and gate['name'] == 'approval': reason = None
        # The managed child's receipt carries its actual exit and log line.
        if kind in ('gate_failed', 'review_failed', 'worker_crashed') and self.busy(task): reason = None
        # Any tagged event establishes the actor's mode, including after a
        # restart whose cursor is already past the start event. Alias spelling
        # is not a mode: an ordinary reviewer may be named zain-sp.
        if kind in ('agent_lost', 'agent_finished'):
            preflights = {row.get('actor') for row in self.rows()
                          if (row.get('data') or {}).get('mode') == 'spec-preflight'}
            if event.get('actor') in preflights or data.get('mode') == 'spec-preflight':
                reason = None
        if reason:
            head = data.get('head') or next((p.get('head') for p in self.data['pulls'].values()
                if p.get('task') == task), None)
            episode = str(pr or task) + '-' + str(head) if head else identity
            said = (event.get('summary') or {}).get('en', '')
            detail = ' (' + said + ')' if 'log is at' in said or 'no adapter' in said else ''
            self.queue('event-' + kind + '-' + episode, task, reason + ': ' + task + detail, '需要 firstmate 判斷：' + task + detail)

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
        merge_authorization.refresh(self)
        self.refresh_queue()
        self.consume_jobs()
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
        deadlines = [self.data['next_poll']] + merge_authorization.deadline(self, key)
        deadlines += [b['due'] for b in self.data['batches'].values()]
        deadlines += [w['created'] + max(300, self.policy['debounce_seconds'] * 2)
                      for w in self.data['wakes'].values() if not w['notified']]
        return max(0.1, min(deadlines) - self.clock())


def code_id(path, folders):
    """Identify only committed code trees; ignored runtime files are irrelevant."""
    path = Path(path).resolve()
    if not (path / '.git').exists(): return None
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
    try:
        trees = subprocess.run(['git', '--no-optional-locks', '-C', str(path),
                                'rev-parse', '--show-toplevel',
                                *('HEAD:' + folder for folder in folders)],
                               env=env, capture_output=True, text=True, check=True).stdout.splitlines()
        if len(trees) != len(folders) + 1 or Path(trees[0]).resolve() != path: return None
        status = subprocess.run(['git', '--no-optional-locks', '-C', str(path),
                                 'status', '--porcelain', '--untracked-files=all', '--', *folders],
                                env=env, capture_output=True, text=True, check=True)
        return dict(zip(folders, trees[1:]), dirty=bool(status.stdout))
    except (OSError, subprocess.SubprocessError): return None


def same_code(left, right):
    return bool(left and right and not left.get('dirty') and not right.get('dirty')
                and {k:v for k,v in left.items() if k != 'dirty'} ==
                    {k:v for k,v in right.items() if k != 'dirty'})


def short_code(code):
    if not code: return 'unknown'
    return '/'.join(str(v)[:7] for k,v in code.items() if k != 'dirty') + ('+dirty' if code.get('dirty') else '')


def read_reload(directory):
    record = read_json(directory / 'reload.json')
    for field, default in dict(request=None, outcome=None, failed_ids=[], dirty_seen=None, legacy_seen=None).items():
        record.setdefault(field, default)
    return record


def failed_code(code, reload):
    return any(same_code(code, failed) for failed in reload['failed_ids'])


def live(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'service.lock').open('a') as lock:
        try: fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError: return True
    return False


def running(ctx):
    directory = Path(ctx['state']) / 'autopilot'
    if not live(directory): return 1
    current = code_id(ctx['engine'], ('bin', 'skills'))
    with Locked(directory / 'start.lock'):
        owner = read_json(directory / 'owner.json')
        # New records always carry code; legacy holders never wrote started_ok.
        # A new holder must finish recovery before any operator changes its request.
        if owner.get('pid') is None or ('code' in owner and not owner.get('started_ok')): return 0
        reload = read_reload(directory)
        old = owner.get('code')
        if current is None or same_code(current, old):
            reload['request'] = None
        elif current['dirty']:
            reload['request'] = None
            if reload['dirty_seen'] != current:
                print('fm-autopilot: bin/ or skills/ has uncommitted changes; keeping the running code ' + short_code(old), file=sys.stderr)
                reload['dirty_seen'] = current
        elif 'code' not in owner:
            reload['request'] = None
            if reload['legacy_seen'] != owner['pid']:
                print('fm-autopilot: the running service predates self-reload (T-203); restart it by hand once, when no job is running', file=sys.stderr)
                reload['legacy_seen'] = owner['pid']
        elif not failed_code(current, reload):
            if not same_code((reload['request'] or {}).get('to'), current):
                reload['request'] = dict(to=current, **{'from':old}, requested=time.time())
                save_json(directory / 'reload.json', reload)
                life.ring_events(ctx['state'], 'autopilot reload requested')
                print(f'fm-autopilot: reload requested: {short_code(old)}->{short_code(current)}; it restarts when its running jobs finish', file=sys.stderr)
        outcome = reload['outcome']
        if outcome and not outcome.get('reported') and not os.environ.get('FM_AUTOPILOT_HANDOFF'):
            before, after = short_code(outcome['from']), short_code(outcome['to'])
            if outcome['kind'] == 'reloaded':
                print(f'fm-autopilot: reloaded: {before}->{after}', file=sys.stderr)
            else:
                print(f"fm-autopilot: reload to {after} failed ({outcome['error']}); running the previous code {before}; inspect service.log", file=sys.stderr)
            outcome['reported'] = True
        save_json(directory / 'reload.json', reload)
    return 0


def reload_due(pilot, own_code, reload):
    request = reload.get('request')
    return bool(request and not same_code(request['to'], own_code)
                and not failed_code(request['to'], reload)
                and not any(j.get('state') in ('running', 'consuming') for j in pilot.data['jobs'].values())
                and not pilot.data['batches']
                and all(w.get('pushed') for w in pilot.data['wakes'].values()))


def handoff_target(ctx, own_code, reload):
    current = code_id(ctx['engine'], ('bin', 'skills'))
    if current is None or current['dirty'] or same_code(current, own_code): return None
    return current


def ensure(ctx, owner):
    directory = Path(ctx['state']) / 'autopilot'
    directory.mkdir(parents=True, exist_ok=True)
    with Locked(directory / 'start.lock'):
        if live(directory): return
        code = code_id(ctx['engine'], ('bin', 'skills'))
        env = dict(os.environ, FM_AUTOPILOT_OWNED='1')
        env.pop('FM_AUTOPILOT_CODE', None)
        if code is not None: env['FM_AUTOPILOT_CODE'] = json.dumps(code)
        save_json(directory / 'owner.json', dict(owner=owner, requested=time.time(), pid=None, code=code))
        with (directory / 'service.log').open('ab') as log:
            child = life.start([sys.executable, str(Path(__file__).resolve()), 'serve'], owner=owner,
                               env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log)
        threading.Thread(target=child.wait, daemon=True).start()
        ready, _, _ = select.select([child.stdout], [], [], 30)
        line = child.stdout.readline() if ready else b''
        child.stdout.close()
        if line != b'ready\n': raise RuntimeError('autopilot did not become ready; inspect service.log')


def reload_outcome(kind, before, after, error=None):
    return dict(kind=kind, **{'from':before}, to=after, at=time.time(), error=error,
                reported=False, woken=False)


def started(pilot, record):
    """Only the exclusive service holder publishes recovery and failure wakes."""
    with Locked(pilot.directory / 'start.lock'):
        record['started_ok'] = True
        save_json(pilot.directory / 'owner.json', record)
        reload = read_reload(pilot.directory)
        request = reload['request']
        if request and not same_code(record['code'], request['from']):
            reload['outcome'] = reload_outcome('reloaded', request['from'], record['code'])
            reload['request'] = None
        outcome = reload['outcome']
        if outcome and outcome['kind'] == 'failed' and not outcome.get('woken'):
            before, after = short_code(outcome['from']), short_code(outcome['to'])
            pilot.queue('reload-failed-' + after, '',
                        f'Autopilot reload to {after} failed; running the previous code {before}; inspect service.log',
                        f'自動駕駛重載到 {after} 失敗；仍執行先前的程式 {before}；請檢查 service.log')
            outcome['woken'] = True
        save_json(pilot.directory / 'reload.json', reload)


def replacement(directory, own_code):
    record = read_json(directory / 'owner.json')
    if (record.get('pid') not in (None, os.getpid()) and live(directory)
            and not same_code(record.get('code'), own_code)):
        return record
    return None


def handoff(ctx, owner, own_code, target):
    """The old snapshot owns fallback; the candidate never owns our recovery."""
    directory = Path(ctx['state']) / 'autopilot'
    wait = float(os.environ.get('FM_AUTOPILOT_RELOAD_WAIT', '60'))
    deadline = time.monotonic() + wait
    env = dict(os.environ, FM_SESSION_PID=str(owner), FM_AUTOPILOT_HANDOFF='1')
    for name in ('FM_CODE_ROOT', 'FM_ENTRY_PID', 'FM_ENTRY_SCRIPT'): env.pop(name, None)
    argv = [str(Path(ctx['engine']) / 'bin/fm-autopilot.sh'), 'ensure', '--repo', ctx['engine']]
    if ctx.get('project'): argv += ['--project', ctx['project']]
    log_path = directory / 'service.log'
    offset = log_path.stat().st_size if log_path.exists() else 0
    child = None
    try:
        with log_path.open('ab') as log:
            child = life.start(argv, owner=owner, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        # Never compete for service.lock while ensure is still starting its child.
        child.wait(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        # Keep reaping this session-owned child without terminating it.
        threading.Thread(target=child.wait, daemon=True).start()
    except (OSError, RuntimeError):
        pass
    else:
        while time.monotonic() < deadline:
            record = replacement(directory, own_code)
            if record and record.get('started_ok'): return 0
            time.sleep(.1)
    # Re-read under start.lock before deciding failure. A slow live candidate
    # gets a second bound and can retain its request beyond that bound.
    with Locked(directory / 'start.lock'):
        record = replacement(directory, own_code)
    if record:
        pending_deadline = time.monotonic() + wait
        while time.monotonic() < pending_deadline:
            record = replacement(directory, own_code)
            if not record: break
            if record.get('started_ok'): return 0
            time.sleep(.1)
    with Locked(directory / 'start.lock'):
        if replacement(directory, own_code): return 0
        reload = read_reload(directory)
        target = (reload['request'] or {}).get('to', target)
        with log_path.open('rb') as log:
            log.seek(offset)
            lines = [line.strip() for line in log.read().decode(errors='replace').splitlines() if line.strip()]
        error = lines[-1] if lines else f'no new service within {wait:g} s'
        reload['outcome'] = reload_outcome('failed', own_code, target, error)
        if not failed_code(target, reload): reload['failed_ids'].append(target)
        reload['request'] = None
        save_json(directory / 'reload.json', reload)
    os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve()), 'serve'])


def serve(ctx):
    if os.environ.get('FM_AUTOPILOT_OWNED') != '1':
        raise ValueError('use ensure to start autopilot through the session lifeline')
    owner = life.session_owner()
    own_code = json.loads(os.environ.get('FM_AUTOPILOT_CODE', 'null'))
    pilot = Pilot(ctx)
    with (pilot.directory / 'service.lock').open('a') as lock:
        deadline = time.monotonic() + 2
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline: return 0
                time.sleep(.1)
        with life.Doorbell(pilot.root, channel='autopilot.d') as bell:
            record = dict(pid=os.getpid(), owner=owner, started=time.time(), code=own_code,
                          snapshot=os.environ.get('FM_CODE_ROOT'))
            save_json(pilot.directory / 'owner.json', record)
            print('ready', flush=True)
            os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
            pilot.refresh_queue()
            legacy_start = pilot.queue_mode == 'off'
            if legacy_start:
                pilot.recover()
                pilot.recover_jobs()
            started(pilot, record)
            # This node runs inside the exclusive service lock and lifeline.
            # Neither an owner pid nor an arbitrary JSON receipt reaches it.
            pilot._queue_service_owned = True
            pilot.refresh_queue()
            if pilot.data.get('self_queue') and pilot.queue_mode != 'hold':
                q = pilot.data['self_queue']
                receipt = {k: record.get(k) for k in ('owner', 'requested', 'pid', 'code', 'started_ok')}
                if receipt != q['owner_receipt']:
                    q['owner_generation'] += 1
                    q['owner_receipt'] = receipt
                    pilot.save()
            if not legacy_start:
                pilot.recover()
                pilot.recover_jobs()
            pushed = True
            while True:
                if pushed:
                    pilot.local()
                    try: pilot.ready()
                    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
                        pilot.queue('ready-error', '', 'Intent card needs attention: ' + str(error), '意圖卡需要處理')
                if pilot.clock() >= pilot.data['next_poll']: pilot.poll()
                pilot.flush()
                with Locked(pilot.directory / 'start.lock'):
                    reload = read_reload(pilot.directory)
                    if reload_due(pilot, own_code, reload):
                        target = handoff_target(ctx, own_code, reload)
                        if target is None or failed_code(target, reload):
                            reload['request'] = None
                        else:
                            reload['request']['to'] = target
                        save_json(pilot.directory / 'reload.json', reload)
                        if reload['request']: break
                pushed = bell.wait(pilot.delay())
    return handoff(ctx, owner, own_code, target)


def main():
    ctx = context()
    mode = sys.argv[1]
    if mode == 'context': print(json.dumps(ctx))
    elif mode == 'running': return running(ctx)
    elif mode == 'status':
        directory = Path(ctx['state']) / 'autopilot'
        reload = read_reload(directory)
        print(json.dumps(dict(running=live(directory), **read_json(directory / 'owner.json'),
                              reload={k:reload[k] for k in ('request', 'outcome', 'failed_ids')})))
    elif mode == 'ensure': ensure(ctx, life.session_owner())
    elif mode == 'serve': return serve(ctx)
    else: raise ValueError('unknown autopilot mode')
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('fm-autopilot: ' + str(error), file=sys.stderr)
        sys.exit(70)
