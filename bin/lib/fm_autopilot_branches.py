"""Predicate-driven branch updates and safe local synchronization (T-190)."""
import re
import json
import subprocess

from fm_binding import fetch_ref


ERRORS = (ValueError, RuntimeError, OSError, subprocess.SubprocessError)


class BranchUpdates:
    def prune_branches(self, number, head=None, *, keep=None):
        """Drop only this PR's obsolete observations; None means terminal."""
        for token in list(self.data['retries']):
            kind, pr, sha = token.split(':', 2)
            if token != keep and pr == number and (head is None or sha != head):
                del self.data['retries'][token]
        for name in ('holds', 'updates', 'advanced', 'rechecked'):
            item = self.data[name].get(number)
            keep_rebase = (name == 'updates' and self.ctx['external'] and item
                           and item.get('method') == 'rebase' and head is not None)
            if item and not keep_rebase and (head is None or item['head'] != head):
                del self.data[name][number]
        item = self.data['restacks'].get(number)
        if item and (head is None or (item['head'] != head and item['outcome'] not in ('published', 'started'))):
            del self.data['restacks'][number]

    def round_live(self, task):
        from fm_concurrent import live_rounds
        return any(r.get('task') == task for r in
                   live_rounds([dict(state=str(self.state), name=self.ctx['project'])]))

    def retry_due(self, token, *, variant=''):
        record = self.data['retries'].get(token, {})
        if variant and record.get('variant') != variant:
            return True
        return record.get('count', 0) < 3 and record.get('due_seq', 0) <= self.data['poll_seq']

    def branch_failure(self, kind, number, head, task, error, *, variant=''):
        token = f'{kind}:{number}:{head}'
        record = self.data['retries'].get(token, {})
        if variant and record.get('variant') != variant:
            record = {}
        count = record.get('count', 0) + 1
        self.data['retries'][token] = dict(count=count, due_seq=self.data['poll_seq'] + count)
        if variant:
            self.data['retries'][token]['variant'] = variant
        if count == 3:
            identity = f'{kind}-{number}-{head}' + (f'-{variant}' if variant else '')
            self.queue(identity, task,
                       f'{task} #{number} {kind} failed after 3 attempts: {error}',
                       f'{task} #{number} {kind} 已失敗 3 次：{error}')
        self.save()

    @staticmethod
    def probe_error(argv, stderr):
        last = next((line.strip() for line in reversed(stderr.splitlines()) if line.strip()), 'command failed')
        return ValueError(f'{argv!r}: {last}')

    def sync_branch(self, pr, task):
        number, head = str(pr['number']), pr['head']['sha']
        token = f'sync:{number}:{head}'
        ref = 'refs/heads/' + pr['head']['ref']
        git = ['git', '-C', self.ctx['target']]
        try:
            argv = [*git, 'rev-parse', '--verify', '--quiet', ref]
            rc, out, err = self.probe(argv)
            if rc == 0:
                local = out.strip()
                if not local:
                    raise ValueError('local ref lookup returned no SHA')
            elif rc == 1 and not out.strip() and not err.strip():
                local = ''
            else:
                raise self.probe_error(argv, err)
            # A manual repair takes precedence over even an exhausted retry.
            if local == head:
                self.data['retries'].pop(token, None)
                self.data['holds'].pop(number, None)
                return True
            if not self.retry_due(token):
                return False
            fetched = fetch_ref(self.ctx['target'], 'https://github.com/' + self.ctx['repository'] + '.git',
                                'refs/pull/' + number + '/head', runner=self.checked)
            if fetched != head:
                return False
            rebased = False
            if local:
                argv = [*git, 'merge-base', '--is-ancestor', local, head]
                rc, out, err = self.probe(argv)
                pending = self.data['updates'].get(number, {})
                rebased = (rc == 1 and self.ctx['external']
                           and pending.get('method') == 'rebase' and pending.get('head') == local)
                if rc == 1 and not rebased:
                    self.data['retries'].pop(token, None)
                    self.data['holds'].pop(number, None)
                    return True  # Binding still refuses unpublished local work.
                if rc not in (0, 1):
                    raise self.probe_error(argv, err)
                # Active work takes precedence over a dirty worktree.
                if self.round_live(task) or self.busy(task):
                    return False
                trees = self.checked([*git, 'worktree', 'list', '--porcelain'])
                worktree = None
                for block in trees.strip().split('\n\n'):
                    lines = block.splitlines()
                    if 'branch ' + ref in lines:
                        worktree = next((line[len('worktree '):] for line in lines
                                         if line.startswith('worktree ')), None)
                        if not worktree:
                            raise ValueError('task worktree has no path')
                        break
                if worktree:
                    dirty = self.checked(['git', '-C', worktree, 'status', '--porcelain', '--untracked-files=no'])
                    if dirty.strip():
                        hold = self.data['holds'].setdefault(number, dict(head=head, count=0))
                        hold['count'] += 1
                        if hold['count'] == 3:
                            self.queue(f'ffhold-{number}-{head}', task,
                                       f'{task} #{number}: dirty task worktree holds fast-forward: {worktree}',
                                       f'{task} #{number}：任務工作樹尚有變更，暫停快轉：{worktree}')
                        return False
                    if rebased:
                        self.checked(['git', '-C', worktree, 'reset', '-q', '--keep', head])
                    else:
                        self.checked(['git', '-C', worktree, 'merge', '--ff-only', head])
                else:
                    self.checked([*git, 'update-ref', ref, head, local])
            else:
                self.checked([*git, 'update-ref', ref, head, ''])
            if rebased:
                self.data['updates'].pop(number, None)
            self.data['retries'].pop(token, None)
            self.data['holds'].pop(number, None)
            return True
        except ERRORS as error:
            if self.retry_due(token):
                self.branch_failure('sync', number, head, task, str(error))
            return False

    def update_branch(self, pr, task):
        number, head = str(pr['number']), pr['head']['sha']
        token = f'update:{number}:{head}'
        if self.round_live(task) or self.busy(task):
            return
        pending = self.data['updates'].get(number)
        if pending and pending['head'] == head and self.data['poll_seq'] - pending['seq'] < 20:
            return
        if not self.retry_due(token):
            return
        try:
            rc, out, err = self.probe(self.gh('api', '-X', 'PUT',
                f"repos/{self.ctx['repository']}/pulls/{number}/update-branch",
                '-f', 'expected_head_sha=' + head, '--include'))
            normalized = out.replace('\r\n', '\n')
            status = re.match(r'^(HTTP/\S+ ([0-9]{3})[^\n]*)', normalized)
            line = status[1] if status else (err.strip().splitlines()[-1] if err.strip() else 'missing HTTP status line')
            code = int(status[2]) if status else None
            body = normalized.partition('\n\n')[2]
            if code == 202:
                self.data['updates'][number] = dict(head=head, seq=self.data['poll_seq'])
                self.data['retries'].pop(token, None)
                return
            if code == 422 and 'expected head sha' in body.lower():
                self.data['retries'].pop(token, None)
                return
        except ERRORS as error:
            line = str(error)
        # No ETag cache: distinguish a raced head from a failed operation.
        try:
            current = json.loads(self.command(self.gh('pr', 'view', number, '--repo',
                self.ctx['repository'], '--json', 'headRefOid,mergeable,mergeStateStatus')))
            if current['headRefOid'] != head:
                self.data['retries'].pop(token, None)
                return
        except ERRORS + (KeyError,):
            pass
        self.branch_failure('update', number, head, task, line)

    def external_behind(self, pr):
        """Use freshly fetched ancestry; REST base.sha can lag the base tip."""
        try:
            url = 'https://github.com/' + self.ctx['repository'] + '.git'
            head = fetch_ref(self.ctx['target'], url, 'refs/pull/' + str(pr['number']) + '/head',
                             runner=self.checked)
            if head != pr['head']['sha']:
                return 'unknown'
            base = fetch_ref(self.ctx['target'], url, 'refs/heads/' + pr['base']['ref'],
                             runner=self.checked)
            rc, _, _ = self.probe(['git', '-C', self.ctx['target'], 'merge-base',
                                   '--is-ancestor', base, head])
            return {0: 'current', 1: 'behind'}.get(rc, 'unknown')
        except ERRORS:
            return 'unknown'

    def update_external_branch(self, pr, task):
        number, head = str(pr['number']), pr['head']['sha']
        token = f'update:{number}:{head}'
        if self.round_live(task) or self.busy(task):
            return
        pending = self.data['updates'].get(number)
        if pending and pending['head'] == head and self.data['poll_seq'] - pending['seq'] < 20:
            return
        if not self.retry_due(token):
            return
        if self.policy.get('force_with_lease') is not True:
            if self.policy.get('merge_method') == 'merge':
                self.update_branch(pr, task)
            else:
                base = pr['base']['ref']
                self.queue(f'behind-held-{number}-{head}', task,
                           f'{task} #{number} is behind {base}: conventions allow neither force_with_lease nor merge updates',
                           f'{task} #{number} 落後 {base}：慣例不允許 force_with_lease 也不允許 merge 更新')
            return
        try:
            rc, out, err = self.probe(self.gh('api', 'graphql', '-f',
                'query=mutation($id:ID!,$head:GitObjectID!){updatePullRequestBranch(input:{pullRequestId:$id,expectedHeadOid:$head,updateMethod:REBASE}){pullRequest{number}}}',
                '-f', 'id=' + pr['node_id'], '-f', 'head=' + head))
            if rc == 0:
                self.data['updates'][number] = dict(head=head, seq=self.data['poll_seq'], method='rebase')
                self.data['retries'].pop(token, None)
                return
            line = err.strip() or out.strip() or 'GraphQL branch update failed'
        except ERRORS as error:
            line = str(error)
        # The failed mutation may have raced a new remote head.
        try:
            current = json.loads(self.command(self.gh('pr', 'view', number, '--repo',
                self.ctx['repository'], '--json', 'headRefOid,mergeable,mergeStateStatus')))
            if current['headRefOid'] != head:
                self.data['retries'].pop(token, None)
                return
        except ERRORS + (KeyError,):
            pass
        self.branch_failure('update', number, head, task, line)
