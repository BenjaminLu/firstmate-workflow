"""Private, data-only project policy. No shell evaluation or inferred permission."""
import argparse
import json
from pathlib import Path
import re
import sys

ENUMS = {'land': {'card', 'handoff'}, 'review': {'fm', 'external', 'both'},
         'post': {'local', 'summary', 'check', 'threads', 'comments'},
         'merge_method': {'squash', 'merge', 'rebase'}, 'stacking': {'hold', 'allowed'}}


PR_DEFAULTS = {'pr_title': 'plain', 'pr_sections': [], 'pr_language': 'en'}


def validate_pr_format(policy):
    for field, choices in (('pr_title', ('conventional', 'plain')),
                           ('pr_language', ('en', 'zh-TW', 'zh-CN', 'auto'))):
        if field in policy and policy[field] not in choices:
            raise ValueError('invalid conventions ' + field)
    if 'pr_sections' in policy:
        sections = policy['pr_sections']
        if (not isinstance(sections, list) or len(sections) > 12
                or any(not isinstance(x, str) or not x.strip() or len(x) > 80
                       or any(c in x for c in '#\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029')
                       for x in sections)
                or len(set(sections)) != len(sections)):
            raise ValueError('invalid conventions pr_sections')


def parse_fields(lines):
    """The data-only line grammar shared by conventions and owner defaults."""
    policy = {}
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = re.fullmatch(r'([a-z_]+): (.+)', line)
        if not match or match[1] in policy:
            raise ValueError('invalid or duplicate conventions field')
        key, raw = match.groups()
        try:
            value = json.loads(raw)
        except ValueError:
            if not re.fullmatch(r'[a-z][a-z0-9_-]*', raw):
                raise ValueError('quote conventions string as JSON: ' + key) from None
            value = raw
        policy[key] = value
    return policy


def owner_defaults(policy, conventions_path):
    """Resolve current private owner defaults per field, only in project layout."""
    defaults = {}
    path = Path(conventions_path).resolve()
    if path.name == 'CONVENTIONS.md' and path.parent.parent.name == 'projects':
        owner = policy['repository'].split('/')[0]
        owner_path = path.parent.parent.parent / 'owners' / (owner + '.yaml')
        if owner_path.is_symlink():
            raise ValueError('owner PR format must not be a symlink')
        try:
            # stat also distinguishes an absent default from an unreadable one.
            info = owner_path.stat()
        except FileNotFoundError:
            info = None
        except OSError as error:
            raise ValueError('unreadable owner PR format: ' + str(error)) from error
        if info is not None:
            try:
                if not info.st_mode & 0o444:
                    raise ValueError('unreadable owner PR format')
                defaults = parse_fields(owner_path.read_text().splitlines())
            except OSError as error:
                raise ValueError('unreadable owner PR format: ' + str(error)) from error
            if set(defaults) - (set(PR_DEFAULTS) | {'branch_prefix'}):
                raise ValueError('unknown owner PR format field')
            validate_pr_format(defaults)
            validate_branch_format(defaults)
    return defaults


def pr_format(policy, conventions_path):
    defaults = owner_defaults(policy, conventions_path)
    validate_pr_format(policy)
    return {field: policy.get(field, defaults.get(field, value))
            for field, value in PR_DEFAULTS.items()}


def branch_format(policy, conventions_path):
    defaults = owner_defaults(policy, conventions_path)
    validate_branch_format(policy)
    return dict(prefix=policy.get('branch_prefix', defaults.get('branch_prefix', '')),
                patterns=policy.get('ci_branch_patterns'),
                pull_request=policy.get('ci_pull_request', False))


def validate_branch_format(policy):
    if 'branch_prefix' in policy and (not isinstance(policy['branch_prefix'], str)
            or not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,30}/', policy['branch_prefix'])):
        raise ValueError('invalid conventions branch_prefix')
    if 'ci_branch_patterns' in policy:
        patterns = policy['ci_branch_patterns']
        if (not isinstance(patterns, list) or not 1 <= len(patterns) <= 30
                or any(not isinstance(x, str) or not x.strip() for x in patterns)):
            raise ValueError('invalid conventions ci_branch_patterns')
    if 'ci_pull_request' in policy and type(policy['ci_pull_request']) is not bool:
        raise ValueError('invalid conventions ci_pull_request')

def request_reviewers(policy):
    """An explicit empty list disables requests; omission uses recorded reviewers."""
    return policy.get('request_reviewers', policy.get('reviewers', []))


def validate(policy, repository=None, base=None):
    validate_pr_format(policy)
    validate_branch_format(policy)

    if 'request_reviewers' in policy:
        names = policy['request_reviewers']
        if (not isinstance(names, list) or len(names) > 15
                or any(not isinstance(n, str) or not re.fullmatch(
                    r'[A-Za-z0-9][A-Za-z0-9_-]*(?:\[bot\])?', n) for n in names)
                or len({n.lower() for n in names}) != len(names)):
            raise ValueError('invalid conventions request_reviewers')
    for key, choices in ENUMS.items():
        if policy.get(key) not in choices:
            raise ValueError('invalid or missing conventions ' + key)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', policy.get('repository', '')):
        raise ValueError('conventions must name repository')
    if not policy.get('base') or policy['base'].startswith('-'):
        raise ValueError('conventions must name base')
    if repository and policy['repository'] != repository or base and policy['base'] != base:
        raise ValueError('conventions repository/base binding mismatch')
    for key in ('confirmed', 'policy_confirmed'):
        if policy.get(key) is not True:
            raise ValueError('require captain-confirmed checks and policy')
    for key in ('delete_branch', 'force_with_lease'):
        if type(policy.get(key)) is not bool:
            raise ValueError('conventions must confirm ' + key)
    checks = policy.get('required_checks')
    if not isinstance(checks, list) or not checks or any(not isinstance(x, str) or not x.strip() for x in checks):
        raise ValueError('require captain-confirmed project checks/statuses')
    analysers = policy.get('analysers', [])
    if not isinstance(analysers, list) or any(not isinstance(x, str) or not x.strip() for x in analysers):
        raise ValueError('conventions analysers must name check/status contexts')
    for key in ('captain', 'intent', 'confirmed_at', 'product'):
        if not isinstance(policy.get(key), str) or not policy[key].strip():
            raise ValueError('missing dated captain intent/product: ' + key)
    for key in ('watch_seconds', 'debounce_seconds', 'reinspect_seconds'):
        if type(policy.get(key)) is not int or not 1 <= policy[key] <= 2592000:
            raise ValueError('invalid conventions ' + key)
    return policy


def read_policy(path, repository=None, base=None):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('conventions must not be a symlink')
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise ValueError('readable CONVENTIONS.md required: ' + str(error)) from error
    if not lines or lines[0] != '---' or '---' not in lines[1:]:
        raise ValueError('conventions front matter required')
    policy = parse_fields(lines[1:lines.index('---', 1)])
    return validate(policy, repository, base)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('path')
    parser.add_argument('--repository')
    parser.add_argument('--base')
    parser.add_argument('--field')
    args = parser.parse_args()
    try:
        p = read_policy(args.path, args.repository, args.base)
        if args.field == 'pr_format':
            value = pr_format(p, args.path)
        elif args.field == 'branch_format':
            value = branch_format(p, args.path)
        else:
            value = p[args.field] if args.field else p
        print(value if isinstance(value, str) else json.dumps(value))
    except (ValueError, KeyError) as error:
        print('fm-conventions: ' + str(error), file=sys.stderr)
        return 65
    return 0


if __name__ == '__main__':
    sys.exit(main())
