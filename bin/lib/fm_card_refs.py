"""Exact-head, read-only GitHub evidence for merge-card change points."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote, urlsplit

from fm_spec_preflight import repository_path


def read(argv, root):
    result = subprocess.run(argv, cwd=root, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError('reference read failed: ' + argv[0])
    return result.stdout.decode('utf-8', errors='strict')


def repository(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value):
        raise ValueError('repository discovery: valid owner/repository required')
    if any(part in ('.', '..') for part in value.split('/')):
        raise ValueError('repository discovery: invalid identity')
    return value


def discovery_identity(doc):
    if not isinstance(doc, dict):
        raise ValueError('repository discovery: repository object required')
    name = repository(doc.get('nameWithOwner'))
    raw = doc.get('url')
    if not isinstance(raw, str):
        raise ValueError('repository discovery: GitHub HTTPS URL required')
    url = urlsplit(raw)
    if (url.scheme != 'https' or url.netloc != 'github.com' or url.query or url.fragment
            or url.path not in ('/' + name, '/' + name + '/')):
        raise ValueError('repository discovery: GitHub URL and identity must match')
    return name


def blob_url(repo, head, file):
    return 'https://github.com/' + repository(repo) + '/blob/' + head + '/' + quote(repository_path(file), safe='/')


def git_path(raw):
    """Decode Git's byte-oriented C quoting, then require strict UTF-8."""
    if raw.startswith('"'):
        if not raw.endswith('"'):
            raise ValueError('invalid quoted diff path')
        raw = raw[1:-1]
        data = bytearray()
        i = 0
        escapes = {'a': 7, 'b': 8, 't': 9, 'n': 10, 'v': 11, 'f': 12, 'r': 13, '\\': 92, '"': 34}
        while i < len(raw):
            if raw[i] != '\\':
                data.extend(raw[i].encode('utf-8')); i += 1
                continue
            i += 1
            if i >= len(raw): raise ValueError('invalid diff escape')
            if raw[i] in '01234567':
                match = re.match(r'[0-7]{1,3}', raw[i:])
                value = int(match[0], 8)
                if value > 255: raise ValueError('invalid diff byte')
                data.append(value); i += len(match[0])
            elif raw[i] in escapes:
                data.append(escapes[raw[i]]); i += 1
            else: raise ValueError('invalid diff escape')
        raw = data.decode('utf-8', errors='strict')
    if raw == '/dev/null': return None
    if raw.startswith(('a/', 'b/')): raw = raw[2:]
    return repository_path(raw)


def header_paths(line):
    text = line[len('diff --git '):]
    if text.startswith('"'):
        match = re.fullmatch(r'("(?:[^"\\]|\\.)*") ("(?:[^"\\]|\\.)*"|b/.*)', text)
        if not match: raise ValueError('invalid diff header')
        return git_path(match[1]), git_path(match[2])
    # Git leaves spaces unquoted; the b/ prefix separates the two paths.
    parts = text.split(' b/', 1)
    if len(parts) != 2: raise ValueError('invalid diff header')
    return git_path(parts[0]), git_path('b/' + parts[1])


def parse_diff(diff, repo, pr):
    repository(repo)
    entries = []
    current = None
    hunk = None

    def finish_hunk():
        nonlocal hunk
        if hunk is None: return
        old, old_count, new, new_count, right, left = hunk
        side = 'right' if new_count else 'left'
        start, count, lines = (new, new_count, right) if new_count else (old, old_count, left)
        item = dict(file=current['new'] or current['old'], start=start,
                    end=start + max(0, count - 1), snippet='\n'.join(lines[:12]))
        if side == 'left': item['side'] = 'left'
        item['url'] = current['url'] + ('R' if side == 'right' else 'L') + str(start)
        current['code'].append(item)
        hunk = None

    def finish_file():
        finish_hunk()
        if current is None: return
        if not current['code']:
            kind = 'binary' if current['binary'] else 'rename' if current['old'] != current['new'] else None
            if kind is None: raise ValueError('diff has no supported hunks')
            current['code'].append(dict(file=current['new'] or current['old'], start=None,
                                        end=None, url=current['url'], snippet='', kind=kind))
        entries.append(current)

    for line in diff.splitlines():
        if line.startswith('diff --git '):
            finish_file()
            old, new = header_paths(line)
            path = new or old
            anchor = hashlib.sha256(path.encode('utf-8')).hexdigest()
            current = dict(old=old, new=new, code=[], binary=False,
                           url=f'https://github.com/{repo}/pull/{pr}/files#diff-{anchor}')
        elif current is not None:
            if line.startswith('@@ '):
                finish_hunk()
                match = re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', line)
                if not match: raise ValueError('invalid text hunk')
                hunk = (int(match[1]), int(match[2] or 1), int(match[3]), int(match[4] or 1), [], [])
            elif hunk is not None:
                if line.startswith((' ', '+')): hunk[4].append(line[1:])
                if line.startswith((' ', '-')): hunk[5].append(line[1:])
            elif line.startswith('--- '): current['old'] = git_path(line[4:].split('\t', 1)[0])
            elif line.startswith('+++ '): current['new'] = git_path(line[4:].split('\t', 1)[0])
            elif line.startswith(('Binary files ', 'GIT binary patch')): current['binary'] = True
    finish_file()
    return entries


def point_code(entries, files):
    paths = [repository_path(file) for file in files]
    if len(paths) != len(set(paths)): raise ValueError('duplicate code paths')
    selected = []
    for path in paths:
        matches = [entry for entry in entries if path in (entry['old'], entry['new'])]
        if not matches: raise ValueError('listed code file absent from diff: ' + path)
        for entry in matches:
            if not any(entry is previous for previous in selected): selected.append(entry)
    return [item for entry in selected for item in entry['code']]


def build_refs(spec, root, repo, pr, head, external, task):
    if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', head): raise ValueError('expected full head required')
    if not re.fullmatch(r'[1-9][0-9]*', str(pr)): raise ValueError('positive PR required')
    gh = os.environ.get('FM_GH', 'gh')
    if not repo:
        try: repo = discovery_identity(json.loads(read([gh, 'repo', 'view', '--json', 'nameWithOwner,url'], root)))
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            raise ValueError('repository discovery failed; confirm the clone GitHub repository') from error
    repository(repo)
    view = [gh, 'pr', 'view', str(pr), '--repo', repo, '--json', 'headRefOid']
    before = json.loads(read(view, root))
    if not isinstance(before, dict) or before.get('headRefOid') != head: raise ValueError('PR head differs before diff')
    diff = read([gh, 'pr', 'diff', str(pr), '--repo', repo], root)
    after = json.loads(read(view, root))
    if not isinstance(after, dict) or after.get('headRefOid') != head: raise ValueError('PR head differs after diff')
    entries = parse_diff(diff, repo, pr)
    points = []
    for ref in spec['change_refs']:
        code = point_code(entries, ref['files'])
        tests = []
        for test in ref['tests']:
            file = repository_path(test['file'])
            try:
                source = read(['git', 'show', head + ':' + file], root)
                line = next((n for n, text in enumerate(source.splitlines(), 1) if test['name'] in text), None)
            except (ValueError, OSError, subprocess.SubprocessError): line = None
            tests.append(dict(file=file, name=test['name'], line=line,
                              url=blob_url(repo, head, file) + '#L' + str(line) if line else None))
        point = dict(acceptance=ref['acceptance'], code=code[:20], tests=tests)
        if len(code) > 20: point['more'] = len(code) - 20
        points.append(point)
    return dict(spec_url=None if external else blob_url(repo, head, 'design/tasks/' + task + '.json'),
                acceptance=spec['acceptance'], points=points)


def prepare_details(spec, details):
    from copy import deepcopy
    from fm_spec_preflight import validate_change_refs
    validate_change_refs(spec)
    result = deepcopy(details)
    explain = spec.get('explain', {})
    points = explain.get('en', {}).get('change_points')
    fields = ('change_points', 'door', 'check')
    if not points:
        if any(field in result.get(lang, {}) for lang in ('en', 'zh-TW') for field in fields):
            raise ValueError('details walk fields mismatch: spec has no change_points')
        return result
    for lang in ('en', 'zh-TW'):
        loc = result.get(lang, {})
        source = explain[lang]
        if 'intent' not in loc:
            raise ValueError(lang + '.intent missing; author the intent card from the spec')
        if loc['intent'] != source['intent']:
            raise ValueError(lang + '.intent mismatch with spec')
        for field in fields:
            if field in loc and loc[field] != source.get(field):
                raise ValueError(lang + '.' + field + ' mismatch with spec')
            if field in source: loc[field] = source[field]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--spec', required=True)
    parser.add_argument('--root', required=True)
    parser.add_argument('--details')
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--repo', default='')
    parser.add_argument('--pr', required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--task', required=True)
    parser.add_argument('--external', action='store_true')
    args = parser.parse_args()
    try:
        spec = json.loads(Path(args.spec).read_text())
        if args.prepare:
            if not args.details: raise ValueError('authored details required')
            result = prepare_details(spec, json.loads(Path(args.details).read_text()))
        else:
            result = build_refs(spec, args.root, args.repo, args.pr, args.head, args.external, args.task)
        print(json.dumps(result, ensure_ascii=False))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('card refs: ' + str(error), file=sys.stderr)
        return 65
    return 0


if __name__ == '__main__': sys.exit(main())
