"""Private, data-only project policy. No shell evaluation or inferred permission."""
import argparse
import json
from pathlib import Path
import re
import sys

ENUMS = {'land': {'card', 'handoff'}, 'review': {'fm', 'external', 'both'},
         'post': {'local', 'summary', 'check', 'threads', 'comments'},
         'merge_method': {'squash', 'merge', 'rebase'}, 'stacking': {'hold', 'allowed'}}


def validate(policy, repository=None, base=None):
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
    policy = {}
    for line in lines[1:lines.index('---', 1)]:
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
        value = p[args.field] if args.field else p
        print(value if isinstance(value, str) else json.dumps(value))
    except (ValueError, KeyError) as error:
        print('fm-conventions: ' + str(error), file=sys.stderr)
        return 65
    return 0


if __name__ == '__main__':
    sys.exit(main())
