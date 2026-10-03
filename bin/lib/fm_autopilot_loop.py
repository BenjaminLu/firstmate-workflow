"""PR advancement owned by the session autopilot (T-175).

Jobs have durable write-ahead identities. Their lifeline-owned children write
completion receipts and ring the supervisor; neither jobs nor receipts poll.
Gate 7, not event text or a cached APPROVE, authorizes a merge card.
"""
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

BIN = Path(__file__).resolve().parents[1]


class MechanicalLoop:
    def rows(self):
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

    def pr_task(self, pr):
        # Call the canonical shell grammar, including legacy t004 branches,
        # title fallback and the deliberate exclusion of Revert titles.
        # This local read must not enter the write-ahead operation channel.
        result = subprocess.run(['bash', '-c', '. "$1"; fm_task_of_pr "$2" "$3" || true',
                                 '_', str(BIN / 'fm-emit.sh'), pr['head']['ref'], pr.get('title', '')],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                timeout=120, check=True)
        return result.stdout.strip()

    def observe_pr(self, pr):
        if pr.get('state') not in ('open', 'closed'): return
        kind = 'merged' if pr.get('merged_at') else 'closed' if pr['state'] == 'closed' else 'pr_opened'
        identity = ['pr-event', pr['number'], kind]
        if any(r.get('type') == kind and r.get('pr') == pr['number'] for r in self.rows()):
            return
        task = self.pr_task(pr)
        en, tw = {'merged':('merged','已合併'), 'closed':('closed','已關閉'),
                  'pr_opened':('opened','已開啟')}[kind]
        self.once(identity, task, lambda: self.emit(kind, task,
            f'#{pr["number"]} {en}: {pr.get("title", "")}',
            f'#{pr["number"]} {tw}：{pr.get("title", "")}', pr['number'], actor='github'))

    def verdict(self, task):
        from fm_evidence import Store
        rows = Store(str(self.state), self.ctx['evidence_project'], task, external=self.ctx['external']).verdicts()
        return rows[-1] if rows else {}

    def attention(self, reason, task, pr, en, tw):
        self.queue(f'{reason}-{pr["number"]}-{pr["head"]["sha"]}', task, en, tw)

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

    def advance(self, pr, runs, statuses):
        from fm_autopilot import key
        task = self.task(pr)
        if not task or pr['state'] != 'open' or self.policy_error:
            return
        if self.busy(task): return
        # Do not gate a branch still being written by its worker.
        from fm_concurrent import live_rounds
        if any(r.get('task') == task for r in live_rounds([dict(state=str(self.state), name=self.ctx['project'])])):
            return
        verdict = self.verdict(task)
        head = pr['head']['sha']
        if verdict.get('verdict') == 'REJECT' and verdict.get('head') == head:
            self.attention('reject', task, pr, f'{task} REJECT: brief needed', f'{task} 審查拒絕：需要 firstmate 撰寫工作簡報')
            return
        from fm_evidence import Store
        asks = [r for r in Store(str(self.state), self.ctx['evidence_project'], task, external=self.ctx['external']).records()
                if r.get('kind') == 'ask' and (r.get('head') == head or pr.get('draft'))]
        if asks:
            self.attention('ask', task, pr, f'{task} SCOPE-BLOCKED/ASK: ' + asks[-1].get('text', ''),
                           f'{task} 工作範圍或問題需要 firstmate 判斷')
            return
        if pr.get('draft'): return
        # Reconsider only changed evidence: CI completion, a new bound verdict,
        # new authored details or release of a project's merge slot. A timer
        # seeing identical inputs never launches another gate or model.
        details = {p.name: p.read_text() for p in (self.state / 'decision-details').glob(
            'D-' + (self.ctx['project'] or 'firstmate-workflow') + '-' + task.replace('-', '') + '-*.json')}
        from fm_concurrent import merge_blocker
        fingerprint = key([pr['number'], head, pr['base']['sha'], runs, statuses,
                           verdict, details, merge_blocker(self.state, self.ctx['project'])])
        round_number = 1 + sum(r.get('type') == 'review_opened' and r.get('task') == task for r in self.rows())
        def gate():
            if self.authoritative_head(task, pr) != head:
                raise ValueError('authoritative head changed; regate before accepting')
            base = self.base_tip()
            kind = 'protocol' if round_number >= 3 else 'gate'
            argv = self.script('fm-protocol.sh', 'check', '--task', task, '--pr', pr['number'],
                               '--round', round_number) if kind == 'protocol' else self.gate_command(task, pr)
            self.start_job(kind, task, pr, argv, base=base, round=round_number)
        self.once(['advance', fingerprint], task, gate)

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
        jobs[identity] = dict(task=task, state='running', path=str(path))
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

    def launch_review(self, task, pr, round_number=1):
        from fm_autopilot import key
        self.once(['launch-review', pr['number'], pr['head']['sha']], task,
            lambda: self.start_job('review', task, pr,
                self.script('fm-review.sh', '--task', task, '--branch', pr['head']['ref'],
                            '--pr', pr['number'], '--round', round_number), verdict_before=key(self.verdict(task))))

    def job_completed(self, result):
        task, pr, code = result['task'], result['pr'], result['code']
        kind, output = result['kind'], result.get('output', '')
        said = [line for line in output.splitlines() if 'log is at' in line or 'no adapter' in line]
        suffix = ' (' + said[-1] + ')' if said else ''
        if kind == 'protocol':
            if code:
                self.attention('protocol', task, pr, f'{task}: protocol violation in round {result["round"]}' + suffix,
                               f'{task}：審查協定違規，需要 firstmate 處理')
            else:
                self.start_job('gate', task, pr, self.gate_command(task, pr), base=result['base'], round=result['round'])
        elif kind == 'gate':
            if code == 7:
                if self.policy['review'] not in ('fm', 'both'):
                    self.attention('external-review', task, pr, f'{task}: external review required', f'{task}：需要外部審查')
                    return
                if self.authoritative_head(task, pr) != pr['head']['sha']:
                    self.attention('head', task, pr, f'{task}: authoritative head changed; regate', f'{task}：遠端版本已變更，需要重新檢查關卡')
                    return
                self.launch_review(task, pr, result['round'])
            elif code == 0:
                self.merge_card(task, pr, result['base'])
            else:
                self.attention('gate', task, pr, f'{task}: stopped at gate {code}' + suffix,
                               f'{task}：關卡 {code} 失敗，需要 firstmate 處理')
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
            for folder in ('pending', 'decisions'):
                for path in (self.state / folder).glob(prefix + '*.json'):
                    record = read_json(path)
                    if record.get('kind') == 'merge' and record.get('task') == task: return
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
                self.attention('details', task, pr, f'{task} ready: merge card details needed ({ident}): {details}',
                               f'{task} 已就緒：需要 firstmate 撰寫合併決策卡內容（{ident}）：{details}')
                return
            # fm-decide validates the authored content and current signed gate
            # readiness again. Nothing here manufactures a recommendation.
            self.command(self.script('fm-decide.sh', '--request', ident, '--task', task, '--project', owner,
                '--kind', 'merge', '--pr', pr['number'], '--expected-head', head, '--details', details))


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
