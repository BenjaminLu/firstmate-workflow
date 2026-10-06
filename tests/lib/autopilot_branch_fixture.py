"""Explicit git refs and HTTP responses for autopilot branch transitions."""
import json


def response(status='202 Accepted', message='Updating pull request branch.'):
    code = int(status.split()[0])
    body = dict(message=message, url='https://github.com/owner/repo/pull/12')
    if code == 422:
        body = dict(message=message, documentation_url=
                    'https://docs.github.com/rest/pulls/pulls#update-a-pull-request-branch', status='422')
    return (int(code >= 400), 'HTTP/2.0 ' + status +
            '\r\nContent-Type: application/json; charset=utf-8\r\n\r\n' + json.dumps(body),
            'gh: ' + status if code >= 400 else '')


def recheck_response(code, reason, body, message=''):
    """gh api --include keeps HTTP errors on stdout and diagnoses on stderr."""
    return (int(code >= 400), f'HTTP/2.0 {code} {reason}' +
            '\r\nContent-Type: application/json; charset=utf-8\r\n\r\n' + json.dumps(body),
            f'gh: {message} (HTTP {code})' if code >= 400 else '')


class BranchFixture:
    def branch_setup(self):
        self.local_refs = {}
        self.fetch_head = None
        self.ancestor = 0
        self.ancestry = {}
        self.base_tip = "b" * 40
        self.last_fetch = ""
        self.graphql_answer = (0, "{}", "")
        self.worktree = None
        self.dirty = False
        self.put_answer = response()
        self.git_error = None
        self.restack_answer = (0, json.dumps(dict(head="c" * 40)), "")

    def branch_probe(self, argv):
        if argv[1:3] == ['api', 'graphql']:
            return self.graphql_answer
        if argv[1:4] == ['api', '-X', 'PUT']:
            return self.put_answer
        if argv[0].endswith('lib/fm-restack.sh'):
            if isinstance(self.restack_answer, Exception):
                raise self.restack_answer
            return self.restack_answer
        assert argv[0] == 'git', argv
        args = argv[3:]
        if self.git_error and self.git_error[0] in args:
            return self.git_error[1:]
        if args[:3] == ['rev-parse', '--verify', '--quiet']:
            head = self.local_refs.get(args[3].removeprefix('refs/heads/'))
            return (0, head + '\n', '') if head else (1, '', '')
        if args[0] == 'fetch':
            assert args[1] == '--no-tags' and args[3].startswith(('+refs/pull/', '+refs/heads/')), argv
            self.last_fetch = args[3]
            return 0, '', ''
        if args[0] == 'rev-parse':
            assert args[1].startswith('refs/fm/fetch/'), argv
            return 0, (self.base_tip if self.last_fetch.startswith('+refs/heads/') else self.fetch_head) + '\n', ''
        if args[:2] == ['update-ref', '-d']:
            assert args[2].startswith('refs/fm/fetch/'), argv
            return 0, '', ''
        if args[:2] == ['merge-base', '--is-ancestor']:
            rc = self.ancestry.get(tuple(args[2:]), self.ancestor)
            return rc, '', 'fatal: Not a valid commit name' if rc == 128 else ''
        if args == ['worktree', 'list', '--porcelain']:
            return 0, (f'worktree {self.worktree}\nbranch refs/heads/{self.branch}\n\n'
                       if self.worktree else ''), ''
        if args == ['status', '--porcelain', '--untracked-files=no']:
            return 0, ' M tracked\n' if self.dirty else '', ''
        if args[:3] == ['reset', '-q', '--keep']:
            self.local_refs[self.branch] = args[3]
            return 0, '', ''
        if args[:2] == ['merge', '--ff-only']:
            self.local_refs[self.branch] = args[2]
            return 0, '', ''
        if args[0] == 'update-ref':
            branch = args[1].removeprefix('refs/heads/')
            if self.local_refs.get(branch, '') != args[3]:
                return 1, '', 'fatal: cannot lock ref: is at another head'
            self.local_refs[branch] = args[2]
            return 0, '', ''
        raise AssertionError(argv)

    def pull_at(self, pr, reviews=None, comments=None, runs=None, statuses=None, *, keep_local=False):
        if not keep_local:
            self.local_refs[pr['head']['ref']] = pr['head']['sha']
        self.fetch_head = pr['head']['sha']
        self.branch = pr['head']['ref']
        self.pilot.data['poll_seq'] = self.pilot.data.get('poll_seq', 0) + 1
        self.pilot.pull(pr, reviews or [], comments or [], runs or [], statuses or [])
