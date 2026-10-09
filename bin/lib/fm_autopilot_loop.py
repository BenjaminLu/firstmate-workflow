"""PR advancement owned by the session autopilot (T-175).

Jobs have durable write-ahead identities. Their lifeline-owned children write
completion receipts and ring the supervisor; neither jobs nor receipts poll.
Gate 6, not event text or a cached APPROVE, authorizes a merge card.
"""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading

sys.dont_write_bytecode = True
import fm_lifeline as life
from fm_watch import Locked, read_json, save_json
from fm_autopilot_branches import ERRORS

BIN = Path(__file__).resolve().parents[1]


class MechanicalLoop:
    def rows(self):
        if getattr(self, '_poll_rows', None) is not None:
            return self._poll_rows
        try:
            lines = (self.state / 'events.jsonl').read_text().splitlines()
        except FileNotFoundError:
            return []
        rows = []
        for line in lines:
            try: row = json.loads(line)
            except json.JSONDecodeError: continue
            if isinstance(row, dict) and (row.get('project') or self.ctx.get('default_project', self.ctx['project'])) == self.ctx['project']:
                rows.append(row)
        return rows

    def landed(self, task, pr):
        """Local terminal evidence also covers a captain merge still running."""
        from fm_merge_outcome import merge_outcome
        number, head = str(pr['number']), pr['head']['sha']
        if any(row.get('type') == 'merged' and str(row.get('pr')) == number
               for row in self.rows()):
            return True
        for folder in ('pending', 'decisions'):
            for path in (self.state / folder).glob('*.json'):
                record = read_json(path)
                if (record.get('kind') == 'merge' and record.get('task') == task
                        and str(record.get('pr')) == number
                        and record.get('expected_head') == head
                        and record.get('chosen') == 'A'
                        and merge_outcome(record) in ('running', 'merged')):
                    return True
        return False

    def failed_card_evidence(self, task, pr):
        """Read-only historical eligibility, never an approval or current readiness.

        Board-owned files/events supply retained local captain provenance, not
        a cryptographic captain signature. Store verifies the old gate binding.
        Return (evidence, hold): empty evidence preserves ordinary scheduling.
        """
        from fm_binding import sha
        from fm_evidence import Store
        from fm_merge_outcome import merge_outcome
        owner = self.ctx['project'] or 'firstmate-workflow'
        prefix = 'D-' + owner + '-' + task.replace('-', '') + '-'
        history = []
        try:
            for folder in ('pending', 'decisions'):
                for path in sorted((self.state / folder).glob('*.json')):
                    record = read_json(path)
                    relevant = path.stem.startswith(prefix) or (
                        record.get('kind') == 'merge' and record.get('task') == task
                        and record.get('project', self.ctx.get('default_project', owner)) == owner)
                    if not relevant: continue
                    nonmerge = record.get('kind') == 'choice' or (
                        'kind' not in record and record.get('purpose') == 'dispatch')
                    if nonmerge:
                        # Intent cannot erase outcome/binding or retained merge
                        # events. Canonical optional nulls carry no merge evidence;
                        # every non-null value contradicts either exemption.
                        merge_keys = ('merge', 'merged', 'merge_settled', 'merge_reason',
                                      'merge_started', 'binding')
                        if (record.get('purpose') == 'merge' or record.get('effect') == 'merge'
                                or any(k in record and record[k] is not None for k in merge_keys)):
                            return [], 'unverified identity'
                        event_path = self.state / 'events.jsonl'
                        for line in event_path.read_text().splitlines() if event_path.exists() else []:
                            row = json.loads(line)
                            if not isinstance(row, dict): return [], 'unverified settlement'
                            data = row.get('data', {})
                            if (row.get('type') == 'decision_made' and isinstance(data, dict)
                                    and isinstance(data.get('decision'), str)
                                    and data['decision'] in (path.stem, record.get('id'))
                                    and (data.get('effect') == 'merge' or data.get('purpose') == 'merge'
                                         or any(k in data and data[k] is not None for k in merge_keys))):
                                return [], 'unverified identity'
                        continue
                    if record.get('kind') != 'merge' or record.get('purpose') == 'dispatch':
                        return [], 'unverified identity'
                    if folder == 'pending': return [], 'outstanding card'
                    ident = record.get('id')
                    if (not isinstance(ident, str) or path.stem != ident
                            or not re.fullmatch(re.escape(prefix) + r'[1-9][0-9]*', ident)
                            or record.get('identity') != 'decision:' + ident
                            or record.get('project', self.ctx.get('default_project', owner)) != owner
                            or record.get('task') != task or str(record.get('pr')) != str(pr['number'])):
                        return [], 'unverified identity'
                    if (record.get('chosen') != 'A' or record.get('merge') != 'failed'
                            or merge_outcome(record) != 'failed'):
                        return [], 'final or unknown answer'
                    old_head = sha(record.get('expected_head'))
                    settled = record.get('merge_settled')
                    when = datetime.datetime.fromisoformat(settled.replace('Z', '+00:00'))
                    if when.tzinfo is None: return [], 'unverified settlement'
                    history.append((ident, old_head, settled, record))
            if not history: return [], ''
            if self.policy['land'] != 'card' or pr.get('state') != 'open':
                return [], 'not an open card candidate'
            head = sha(pr['head']['sha'])
            if any(head == old_head for _, old_head, _, _ in history):
                return [], 'same failed head'
            # Read disk again under merge-turn.lock; a poll's cached event rows
            # must not hide a newly visible settlement or conflicting record.
            events = []
            for line in (self.state / 'events.jsonl').read_text().splitlines():
                row = json.loads(line)
                if not isinstance(row, dict): return [], 'unverified settlement'
                events.append(row)
            records = Store(str(self.state), self.ctx['evidence_project'], task,
                            external=self.ctx['external']).records()
            evidence = []
            for ident, old_head, settled, record in history:
                matches = []
                for row in events:
                    data = row.get('data', {})
                    if not isinstance(data, dict): continue
                    if row.get('type') != 'decision_made' or data.get('decision') != ident: continue
                    # The initial running-answer event is not a settlement.
                    if (row.get('actor') == 'captain' and row.get('task') == task
                            and row.get('project', self.ctx.get('default_project', owner)) == owner
                            and data.get('chosen') == 'A' and data.get('effect') == 'merge'
                            and data.get('outcome') == 'running' and 'merge' not in data): continue
                    if (row.get('actor') != 'captain'
                            or row.get('project', self.ctx.get('default_project', owner)) != owner
                            or row.get('task') != task or data.get('chosen') != 'A'
                            or data.get('merge') != 'failed' or data.get('outcome') != 'failed'
                            or data.get('expected_head') != old_head
                            or ('pr' in row and str(row['pr']) != str(pr['number']))):
                        return [], 'unverified settlement'
                    stamp = datetime.datetime.fromisoformat(row['ts'].replace('Z', '+00:00'))
                    when = datetime.datetime.fromisoformat(settled.replace('Z', '+00:00'))
                    # The stock emitter truncates to seconds: its timestamp
                    # denotes [stamp, stamp + 1s), not proven subsecond order.
                    whole_second = re.fullmatch(
                        r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})', row['ts'])
                    if (stamp.tzinfo is None or (stamp < when and not (
                            whole_second and when < stamp + datetime.timedelta(seconds=1)))):
                        return [], 'unverified settlement'
                    matches.append(row['ts'])
                if not matches: return [], 'unverified settlement'
                binding = record.get('binding')
                signature = binding.get('signature') if isinstance(binding, dict) else None
                if not signature or not any(
                        r.get('kind') == 'readiness' and r.get('signature') == signature
                        and r.get('head') == old_head and str(r.get('pr')) == str(pr['number'])
                        and r.get('repository') == self.ctx['repository'] and binding == r for r in records):
                    return [], 'unverified old readiness'
                evidence.append([ident, old_head, settled, sorted(set(matches))])
            return ['failed-card-replacement-v1', head, sorted(evidence)], ''
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            return [], 'unverified failed history'

    def failed_card_hold(self, task, pr, reason):
        # Fixed categories only: never project private reasons/details/evidence.
        translations = {'outstanding card': '已有待處理決策卡',
            'unverified identity': '身分無法驗證', 'final or unknown answer': '回答已定案或結果未知',
            'unverified settlement': '結算紀錄無法驗證', 'same failed head': '仍是失敗的版本',
            'not an open card candidate': '不是可提出決策卡的開啟 PR',
            'unverified old readiness': '舊關卡證據無法驗證',
            'unverified failed history': '失敗歷史無法驗證'}
        self.attention('failed-card-' + reason, task, pr,
            f'{task} #{pr["number"]} replacement held: {reason}',
            f'{task} #{pr["number"]} 新決策卡暫緩：{translations[reason]}')

    def adoption_env(self):
        return dict(FM_ENGINE_ROOT=str(self.root), FM_TARGET_ROOT=self.ctx['target'],
                    FM_STATE_DIR=str(self.state), FM_TASKS_DIR=self.ctx['tasks'],
                    FM_PROJECT=self.ctx['project'], FM_BASE=self.ctx['base'],
                    FM_EXTERNAL='1' if self.ctx['external'] else '0',
                    FM_DESIGN=self.ctx.get('design') or str(self.state.parent / 'design.md'
                              if self.ctx['external'] else self.root / 'design/design.md'))

    def adoptions(self):
        import fm_adopt
        single, duplicates, errors = fm_adopt.scan(self.adoption_env())
        for task, reason in errors.items():
            self.queue('adopt-error-' + task, task,
                       'Cannot read PR adoption: ' + reason, '無法讀取 PR 接手設定：' + reason)
        return single, duplicates

    def pr_task(self, pr):
        self._adopt_reason = ''
        if self.ctx['external']:
            import fm_adopt
            single, duplicates = self.adoptions()
            if pr['number'] in duplicates:
                self._adopt_reason = fm_adopt.duplicate_reason(duplicates[pr['number']])
                return ''
            if pr['number'] in single:
                return single[pr['number']]
        # Call the canonical shell grammar, including legacy t004 branches,
        # title fallback and the deliberate exclusion of Revert titles.
        result = subprocess.run(['bash', '-c', '. "$1"; fm_task_of_pr "$2" "$3" || true',
                                 '_', str(BIN / 'fm-emit.sh'), pr['head']['ref'], pr.get('title', '')],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                timeout=120, check=True)
        return result.stdout.strip()

    def observe_pr(self, pr):
        if pr.get('state') not in ('open', 'closed'): return
        kind = 'merged' if pr.get('merged_at') else 'closed' if pr['state'] == 'closed' else 'pr_opened'
        token = f'event-{kind}:{pr["number"]}:{pr["head"]["sha"]}'
        if any(r.get('type') == kind and r.get('pr') == pr['number'] for r in self.rows()):
            self.data['retries'].pop(token, None)
            return
        if not self.retry_due(token):
            return
        task = self.pr_task(pr)
        en, tw = {'merged':('merged','已合併'), 'closed':('closed','已關閉'),
                  'pr_opened':('opened','已開啟')}[kind]
        try:
            self.emit(kind, task,
                f'#{pr["number"]} {en}: {pr.get("title", "")}',
                f'#{pr["number"]} {tw}：{pr.get("title", "")}', pr['number'], actor='github')
            self.data['retries'].pop(token, None)
            if getattr(self, '_poll_rows', None) is not None:
                self._poll_rows.append(dict(type=kind, pr=pr['number'], task=task))
        except ERRORS as error:
            self.branch_failure('event-' + kind, pr['number'], pr['head']['sha'], task, str(error))

    def verdict(self, task):
        from fm_evidence import Store
        rows = Store(str(self.state), self.ctx['evidence_project'], task, external=self.ctx['external']).verdicts()
        return rows[-1] if rows else {}

    def attention(self, reason, task, pr, en, tw):
        self.queue(f'{reason}-{pr["number"]}-{pr["head"]["sha"]}', task, en, tw)

    def prepare_head(self, pr):
        """Fetch immutable objects, never reset or move a local task branch."""
        target = self.ctx['target']
        repository = self.ctx['repository']
        from fm_binding import fetch_ref
        fetched = fetch_ref(target, 'https://github.com/' + repository + '.git',
                            'refs/pull/' + str(pr['number']) + '/head', runner=self.command)
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

    def authoritative_head(self, task, pr):
        # Use the same verified remote/fetched/local-ref binding as the old
        # turn, and keep the actual branch name (a SHA alone hides stale refs).
        return self.command(['bash', '-c',
            '. "$1/fm-config.sh"; fm_storage_init "$2" || exit 65; '
            'fm_binding head --task "$3" --pr "$4" --branch "$5"',
            '_', str(BIN), str(self.root), task, str(pr['number']), pr['head']['ref']]).strip()

    def base_tip(self):
        return self.command(['git', '-C', self.ctx['target'], 'rev-parse',
                             self.ctx['base'] + '^{commit}']).strip()

    def busy(self, task):
        return any(job['task'] == task and job['state'] == 'running'
                   for job in self.data.setdefault('jobs', {}).values())

    def settled_checks(self, pr, runs, statuses):
        """Return only latest required conclusions; None means CI is pending.

        Branch protection and confirmed external policy supply the names, as
        in gate 5. This is scheduling evidence, never gate authorization.
        """
        from urllib.parse import quote
        names = set(self.policy.get('required_checks', []))
        names.update(self.policy.get('analysers', []))
        try:
            protection = self.api('branches/' + quote(pr['base']['ref'], safe='') +
                                  '/protection/required_status_checks')
            names.update(protection.get('contexts', []))
            names.update(row['context'] for row in protection.get('checks', []))
        except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
            if not names: raise
        if not names:
            raise ValueError('required checks unknown: no confirmed names')
        conclusions = []
        for name in sorted(names):
            sources = [('check', [r for r in runs if r.get('name') == name and
                                  r.get('head_sha') == pr['head']['sha']]),
                       ('status', [r for r in statuses if r.get('context') == name])]
            if not any(rows for _, rows in sources): return None
            for source, rows in sources:
                if not rows: continue
                latest = max(rows, key=lambda r: r.get('id', 0))
                if source == 'check':
                    if latest.get('status') != 'completed' or not latest.get('conclusion'): return None
                    conclusion = latest['conclusion']
                else:
                    conclusion = latest.get('state')
                    if conclusion not in ('success', 'failure', 'error'): return None
                conclusions.append((name, source, latest.get('id'), conclusion))
        return conclusions

    def refresh_pr_testing(self, pr, checks, task):
        """Best-effort public CI evidence; never a gate or merge prerequisite."""
        from fm_autopilot import key
        from fm_pr_format import refresh_testing, START, END
        if not self.ctx['external'] or pr.get('state') != 'open':
            return
        body = pr.get('body') or ''
        if START not in body or END not in body:
            return
        number, head = str(pr['number']), pr['head']['sha']
        try:
            single, duplicates = self.adoptions()
            if pr['number'] in single or pr['number'] in duplicates:
                return
            states = {}
            if checks is None:
                states = {name: 'pending' for name in
                          self.policy.get('required_checks', []) + self.policy.get('analysers', [])}
                fingerprint = head + '-pending'
            else:
                rank = {'passed': 0, 'pending': 1, 'failed': 2}
                for name, _source, _id, conclusion in checks:
                    state = ('passed' if conclusion in ('success', 'neutral', 'skipped') else
                             'failed' if conclusion in ('failure', 'error', 'cancelled', 'timed_out', 'action_required')
                             else 'pending')
                    if name not in states or rank[state] > rank[states[name]]:
                        states[name] = state
                fingerprint = head + '-' + key(checks)
            updated = refresh_testing(body, states)
            testing = self.data.setdefault('testing', {})
            if updated is None or updated == body or testing.get(number) == fingerprint:
                return
            rc, stdout, stderr = self.probe(self.gh('api', '-X', 'PATCH',
                f'repos/{self.ctx["repository"]}/pulls/{number}', '-f', 'body=' + updated, '--include'))
            codes = re.findall(r'^HTTP/\S+ (\d{3})\b', stdout, re.M)
            if rc or not codes or codes[-1] != '200':
                raise RuntimeError(stderr.strip() or 'PR testing PATCH did not return HTTP 200')
            testing[number] = fingerprint
            self.save()
        except Exception as error:
            # Even an unavailable failure recorder must not block advancement.
            try:
                self.branch_failure('testing-refresh', number, head, task, str(error))
            except Exception:
                pass

    def advance(self, pr, runs, statuses):
        from fm_autopilot import key
        self.data['pulls'].get(str(pr['number']), {}).pop('merge_evidence', None)
        if pr['state'] != 'open' or self.policy_error: return
        task = self.task(pr)
        if not task: return
        if self.landed(task, pr): return
        if self.busy(task): return
        # Do not gate a branch still being written by its worker.
        from fm_concurrent import live_rounds
        if any(r.get('task') == task for r in live_rounds([dict(state=str(self.state), name=self.ctx['project'])])):
            return
        replacement, hold = self.failed_card_evidence(task, pr)
        if hold:
            self.failed_card_hold(task, pr, hold)
            return
        if replacement and any(job.get('task') == task
                and job.get('state') in ('running', 'consuming', 'uncertain')
                for job in self.data.get('jobs', {}).values()): return
        verdict = self.verdict(task)
        head = pr['head']['sha']
        if verdict.get('verdict') == 'REJECT' and verdict.get('head') == head:
            self.attention('reject', task, pr, f'{task} REJECT: brief needed', f'{task} 審查拒絕：需要 firstmate 撰寫工作簡報')
            return
        from fm_evidence import Store
        records = Store(str(self.state), self.ctx['evidence_project'], task, external=self.ctx['external']).records()
        asks = []
        for record in records:
            # A later authorized brief answers/supersedes earlier questions for
            # this task, even if the launcher has since advanced its head.
            if (record.get('kind') == 'brief' and record.get('authorized') is True
                    and record.get('actor') == 'firstmate'):
                asks.clear()
            if record.get('kind') != 'ask' or record.get('head') != head:
                continue
            try:
                written = datetime.datetime.fromisoformat(record['time'].replace('Z', '+00:00'))
                fresh = written.tzinfo is not None and written.timestamp() > self.data['tracking_started']
            except (KeyError, AttributeError, ValueError, TypeError):
                fresh = False
            if fresh:
                asks.append(record)
        if asks:
            ask = asks[-1]
            legacy = 'autopilot-' + key([self.ctx['project'], f'ask-{pr["number"]}-{head}'])
            if legacy in self.data['wakes'] and key(ask) in self.data['legacy_ask_records']:
                return
            # Dedupe by the question, so another question at the same head can
            # wake after the first was answered, but a restart cannot replay it.
            self.queue(f'ask-{pr["number"]}-{key(ask)}', task,
                       f'{task} SCOPE-BLOCKED/ASK: ' + ask.get('text', ''),
                       f'{task} 工作範圍或問題需要 firstmate 判斷')
            return
        if pr.get('draft'):
            self.queue(f'draft-{pr["number"]}-{head}', task,
                       f'{task} #{pr["number"]} is a draft at {head[:12]}: the merge path waits; mark it ready',
                       f'{task} #{pr["number"]} 仍是草稿：合併流程在等待，請標成 ready')
            return
        # Reconsider only changed evidence: CI completion, a new bound verdict,
        # new authored details or release of a project's merge slot. A timer
        # seeing identical inputs never launches another gate or model.
        checks = self.settled_checks(pr, runs, statuses)
        self.refresh_pr_testing(pr, checks, task)
        # Reuse scheduling evidence already read here; reminders never fetch CI.
        self.data['pulls'].setdefault(str(pr['number']), dict(task=task, head=head))['merge_evidence'] = dict(
            head=head, approved=verdict.get('head') == head and verdict.get('verdict') == 'APPROVE',
            green=bool(checks) and all(row[-1] in ('success', 'neutral', 'skipped') for row in checks))
        if checks is None: return
        details = {p.name: json.loads(p.read_text()) for p in (self.state / 'decision-details').glob(
            'D-' + (self.ctx['project'] or 'firstmate-workflow') + '-' + task.replace('-', '') + '-*.json')}
        from fm_concurrent import merge_blocker
        # Acquisition or a pending -> running label is not a release. Keep a
        # durable generation so a later release can revisit identical evidence.
        blocked = bool(merge_blocker(self.state, self.ctx['project']))
        slot = self.data.setdefault('merge_slot', dict(blocked=False, release=0))
        if slot['blocked'] and not blocked: slot['release'] += 1
        slot['blocked'] = blocked
        self.save()
        bound = {field: verdict.get(field) for field in ('head', 'verdict', 'signature', 'round', 'actor')}
        if verdict.get('head') != head: bound = None
        inputs = [pr['number'], head, pr['base']['sha'], checks,
                  bound, details, slot['release']]
        replacement, hold = self.failed_card_evidence(task, pr)
        if hold:
            self.failed_card_hold(task, pr, hold)
            return
        if replacement:
            if any(job.get('task') == task and job.get('state') in ('running', 'consuming', 'uncertain')
                   for job in self.data.get('jobs', {}).values()): return
            # Preserve the exact seven-element ordinary input on upgrade.
            inputs.append(replacement)
        fingerprint = key(inputs)
        round_number = 1 + sum(r.get('type') == 'review_opened' and r.get('task') == task for r in self.rows())
        number = str(pr['number'])
        if self.data['advanced'].get(number, {}).get('fingerprint') == fingerprint:
            return
        token, variant = f'advance:{number}:{head}', fingerprint[:12]
        if not self.retry_due(token, variant=variant): return
        try:
            if self.authoritative_head(task, pr) != head:
                return  # A raced observation is reconsidered on the next poll.
            base = self.base_tip()
            kind = 'protocol' if round_number >= 3 else 'gate'
            argv = self.script('fm-protocol.sh', 'check', '--task', task, '--pr', pr['number'],
                               '--round', round_number) if kind == 'protocol' else self.gate_command(task, pr)
            self.start_job(kind, task, pr, argv, base=base, round=round_number)
        except Exception as error:
            self.branch_failure('advance', number, head, task, str(error), variant=variant)
            return
        # Act, then mark: a crash here may repeat a read-only gate, never lose it.
        self.data['retries'].pop(token, None)
        self.data['advanced'][number] = dict(head=head, fingerprint=fingerprint)
        self.save()

    def gate_command(self, task, pr):
        return self.script('fm-gate.sh', '--task', task, '--branch', pr['head']['ref'], '--pr', pr['number'])

    def start_job(self, kind, task, pr, argv, **extra):
        from fm_autopilot import key
        identity = key([kind, task, pr, extra, argv, len(self.data.setdefault('jobs', {}))])
        jobs = self.data.setdefault('jobs', {})
        if identity in jobs: return
        path = self.directory / 'jobs' / (identity + '.json')
        path.parent.mkdir(exist_ok=True)
        packet = dict(kind=kind, task=task, pr=pr, argv=argv, state=str(self.state), **extra)
        save_json(path, packet)
        jobs[identity] = dict(kind=kind, task=task, number=pr['number'], head=pr['head']['sha'],
                              state='running', path=str(path))
        self.save()
        with path.with_suffix('.log').open('ab') as log:
            child = life.start([sys.executable, str(BIN / 'lib/fm_autopilot_loop.py'), str(path)],
                owner=os.getpid(), stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        def completed():
            code = child.wait()
            receipt = path.with_suffix('.result.json')
            if not receipt.exists():
                save_json(receipt, dict(packet, code=code or 70, output='Mechanical child ended without a receipt; log is at ' + str(path.with_suffix('.log'))))
            life.ring_events(str(self.state), 'autopilot job completed')
        threading.Thread(target=completed, daemon=True).start()
        return child

    def consume_jobs(self):
        for job in list(self.data.setdefault('jobs', {}).values()):
            if job['state'] != 'running': continue
            receipt = Path(job['path']).with_suffix('.result.json')
            if not receipt.exists(): continue
            # Mark before acting; a crash here is reconciliation, never replay.
            job['state'] = 'consuming'; self.save()
            try:
                self.job_completed(read_json(receipt))
                job['state'] = 'done'
            except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
                job['state'] = 'uncertain'
                self.queue('job-' + receipt.stem, job['task'], str(error), '機械步驟需要 firstmate 核對')
            self.save()

    def recover_jobs(self):
        for ident, job in list(self.data.setdefault('jobs', {}).items()):
            if job['state'] == 'consuming' or (job['state'] == 'running' and
                    not Path(job['path']).with_suffix('.result.json').exists()):
                job['state'] = 'uncertain'
                self.queue('job-' + ident, job['task'], 'Autopilot stopped during a child; reconcile its log: ' + job['path'],
                           '自動駕駛於子程序執行中停止；請核對紀錄')
        self.save()
        self.consume_jobs()

    def job_for(self, kind, number, head):
        for job in self.data.get('jobs', {}).values():
            try:
                if 'kind' in job:
                    job_kind, job_number, job_head = job['kind'], job['number'], job['head']
                else:
                    packet = read_json(Path(job['path']))
                    job_kind = packet['kind']
                    job_number, job_head = packet['pr']['number'], packet['pr']['head']['sha']
                if job_kind == kind and int(job_number) == int(number) and job_head == head:
                    return job
            except (OSError, ValueError, KeyError, TypeError):
                continue
        return None

    def launch_review(self, task, pr, round_number=1):
        from fm_autopilot import key
        number, head = pr['number'], pr['head']['sha']
        if self.job_for('review', number, head) is not None:
            return
        try:
            verdict_before = key(self.verdict(task))
            self.start_job('review', task, pr,
                self.script('fm-review.sh', '--task', task, '--branch', pr['head']['ref'],
                            '--pr', number, '--round', round_number), verdict_before=verdict_before)
        except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
            job = self.job_for('review', number, head)
            if job is None:
                self.data.setdefault('jobs', {})[key(['review-launch', number, head])] = dict(
                    kind='review', task=task, number=number, head=head, state='uncertain', path='')
            elif (job['state'] == 'running' and job.get('path')
                    and not Path(job['path']).with_suffix('.result.json').exists()):
                job['state'] = 'uncertain'
            self.queue(f'review-launch-{number}-{head}', task,
                       f'Review launch failed at {head[:12]}: {error}; launch it by hand or fix the cause',
                       f'審查啟動失敗：{error}；請手動啟動或排除原因')
            self.save()

    def job_completed(self, result):
        task, pr, code = result['task'], result['pr'], result['code']
        kind, output = result['kind'], result.get('output', '')
        if kind in ('gate', 'protocol', 'review') and self.landed(task, pr): return
        said = [line for line in output.splitlines() if 'log is at' in line or 'no adapter' in line]
        suffix = ' (' + said[-1] + ')' if said else ''
        if kind == 'protocol':
            if code:
                self.attention('protocol', task, pr, f'{task}: protocol violation in round {result["round"]}' + suffix,
                               f'{task}：審查協定違規，需要 firstmate 處理')
            else:
                self.start_job('gate', task, pr, self.gate_command(task, pr), base=result['base'], round=result['round'])
        elif kind == 'gate':
            if code == 6:
                if self.policy['review'] not in ('fm', 'both'):
                    self.attention('external-review', task, pr, f'{task}: external review required', f'{task}：需要外部審查')
                    return
                if self.authoritative_head(task, pr) != pr['head']['sha']:
                    self.attention('head', task, pr, f'{task}: authoritative head changed; regate', f'{task}：遠端版本已變更，需要重新檢查關卡')
                    return
                self.launch_review(task, pr, result['round'])
            elif code == 0:
                self.merge_card(task, pr, result['base'])
            elif 1 <= code <= 5:
                from fm_binding import gate_list
                try:
                    name = next(g['name'] for g in gate_list()['gates'] if g['n'] == code)
                except (ValueError, StopIteration):
                    name = 'gate list unavailable'
                self.attention('gate', task, pr, f'{task}: stopped at gate {code} ({name})' + suffix,
                               f'{task}：關卡 {code}（{name}）失敗，需要 firstmate 處理')
            else:
                self.attention('gate', task, pr, f'{task}: gate run failed (exit {code})' + suffix,
                               f'{task}：關卡執行失敗（exit {code}）')
        elif kind == 'review':
            verdict = self.verdict(task)
            from fm_autopilot import key
            unchanged = result.get('verdict_before') == key(verdict)
            if code or not verdict or unchanged or verdict.get('head') != pr['head']['sha']:
                reason = {2:'no reviewer engine was available', 3:'the reviewer produced no verdict',
                          65:'review configuration failed'}.get(code, 'the review round failed' if code else 'the reviewer produced no verdict')
                self.attention('review', task, pr, f'{task}: {reason}' + suffix,
                               f'{task}：審查未完成，需要 firstmate 檢查紀錄' + suffix)
            elif verdict.get('verdict') == 'REJECT':
                self.attention('reject', task, pr, f'{task} REJECT: brief needed', f'{task} 審查拒絕：需要 firstmate 撰寫工作簡報')
            self.data['next_poll'] = 0

    def merge_card(self, task, pr, gated_base):
        from fm_concurrent import merge_blocker
        if self.policy['land'] != 'card':
            self.attention('handoff', task, pr, f'{task} ready: team handoff needed', f'{task} 已就緒：需要交由團隊合併')
            return
        owner = self.ctx['project'] or 'firstmate-workflow'
        head = pr['head']['sha']
        # Identical critical section to merge-turn: one outstanding merge per
        # project, with the captured base checked while holding the lock.
        with Locked(self.state / 'merge-turn.lock'):
            if self.base_tip() != gated_base:
                self.attention('base', task, pr, f'{task}: regate on the new base', f'{task}：基底已更新，需要重新檢查關卡')
                return
            if self.authoritative_head(task, pr) != head:
                self.attention('head', task, pr, f'{task}: authoritative head changed; regate', f'{task}：遠端版本已變更，需要重新檢查關卡')
                return
            if merge_blocker(self.state, self.ctx['project']): return
            prefix = 'D-' + owner + '-' + task.replace('-', '') + '-'
            replacement, hold = self.failed_card_evidence(task, pr)
            if hold:
                self.failed_card_hold(task, pr, hold)
                return
            candidates = []
            for path in (self.state / 'decision-ids' / owner / task.replace('-', '')).glob('*.json'):
                if not re.fullmatch(r'[1-9][0-9]*', path.stem) or read_json(path).get('kind') != 'merge': continue
                ident = prefix + path.stem
                if any((self.state / folder / (ident + '.json')).exists() for folder in
                       ('pending', 'decisions', 'runtime/archived-pending')): continue
                candidates.append((int(path.stem), ident))
            ident = min(candidates)[1] if candidates else self.command(self.script('fm-decide.sh', '--allocate',
                '--task', task, '--project', owner, '--kind', 'merge')).strip()
            if not re.fullmatch(re.escape(prefix) + r'[1-9][0-9]*', ident):
                raise ValueError('invalid allocated merge card id')
            details = self.state / 'decision-details' / (ident + '.json')
            if not details.is_file():
                from fm_merge_details import build
                try:
                    if self.ctx['external']:
                        raise ValueError('external project: author the details')
                    content = build(self.state, owner, task, pr['number'])
                    # Built output is not an input to advance's fingerprint.
                    details = self.state / 'decision-details-built' / (ident + '.json')
                    details.parent.mkdir(exist_ok=True)
                    save_json(details, content)
                except ValueError as error:
                    reason = 'external project: author the details' if self.ctx['external'] else str(error)
                    reason_tw = '外部專案：請撰寫決策卡內容' if self.ctx['external'] else str(error)
                    self.attention('details', task, pr,
                                   f'{task} ready: merge card details needed ({ident}): {reason}',
                                   f'{task} 已就緒：需要 firstmate 撰寫合併決策卡內容（{ident}）：{reason_tw}')
                    return
            if replacement:
                # Cooperating writers share this lock. Independently visible
                # mutations during details preparation are checked once more;
                # request/candidate and final match-head still own later races.
                if self.base_tip() != gated_base:
                    self.attention('base', task, pr, f'{task}: regate on the new base',
                                   f'{task}：基底已更新，需要重新檢查關卡')
                    return
                if self.authoritative_head(task, pr) != head:
                    self.attention('head', task, pr, f'{task}: authoritative head changed; regate',
                                   f'{task}：遠端版本已變更，需要重新檢查關卡')
                    return
                if merge_blocker(self.state, self.ctx['project']): return
                replacement, hold = self.failed_card_evidence(task, pr)
                if hold or not replacement:
                    self.failed_card_hold(task, pr, hold or 'unverified failed history')
                    return
            # fm-decide validates the content and current signed gate readiness
            # again; deriving details never substitutes for those checks.
            try:
                self.command(self.script('fm-decide.sh', '--request', ident, '--task', task, '--project', owner,
                    '--kind', 'merge', '--pr', pr['number'], '--expected-head', head, '--details', details))
            except ERRORS:
                if not (replacement and self.ctx['external']): raise
                # The child error may contain authored text or private paths.
                # Retain uncertain-job reconciliation, with a bounded wake.
                raise ValueError(f'{task} #{pr["number"]}: replacement request refused; verify current evidence and details') from None


def run_job(path):
    packet = read_json(path)
    try:
        # Foreground command lives inside this job's lifeline process group.
        result = subprocess.run(packet['argv'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=86400)
        code, output = result.returncode, result.stdout
    except (OSError, subprocess.SubprocessError) as error:
        code, output = 70, str(error)
    save_json(path.with_suffix('.result.json'), dict(packet, code=code, output=output))
    life.ring_events(packet['state'], 'autopilot job completed')


if __name__ == '__main__': run_job(Path(sys.argv[1]))
