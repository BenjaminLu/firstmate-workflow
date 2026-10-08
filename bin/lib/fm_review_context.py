#!/usr/bin/env python3
"""Bound the stock review prompt, without summarizing acceptance or verdicts.

512 KiB UTF-8 is below the observed 1,048,576-character vendor limit, with
room for adapter instructions. This is an input-size bound, not a token promise.
Small prompts retain their exact bytes. Unique closed-list comments are never
truncated: an unrepresentable list fails closed before a vendor is invoked.
"""
import hashlib
import json
from pathlib import Path
import re
import sys
import shutil
import tempfile
import argparse
import os
import secrets

CAP = 512 * 1024
QUOTE_CAP = 16 * 1024
PARTS = ('intro', 'history', 'evidence', 'diff', 'outro')


def prepare_experiments(directory, mode, checkout, head, base, code):
    from fm_evidence import Store
    store = Store(os.environ['FM_STATE_DIR'], os.environ.get('FM_EVIDENCE_PROJECT')
                  or os.environ.get('FM_PROJECT') or 'self', os.environ['FM_TASK'])
    records, unavailable = store.experiments(head, base, code)
    text, index, count = '', '', 0
    if records or unavailable:
        from fm_experimental_evidence import attach
        text, index, count = attach(store, records, unavailable, mode, checkout)
    standard = directory / 'evidence-standard.md'
    if not standard.exists():
        standard.write_bytes((directory/'evidence.md').read_bytes())
    (directory/'evidence.md').write_bytes(standard.read_bytes() + text.encode())
    (directory/'experiment-status.json').write_text(json.dumps(dict(
        has_experiments=bool(count), experiment_count=count, provenance_level='unverified', index=index,
        requires_context_refresh=bool(records or unavailable))))


def verify_effective_experiment_policy(args):
    # The marker is a location, never an authority token or extra read grant.
    # This fixed mode is invoked only after the final adapter policy/launch exist.
    from fm_experimental_evidence import canonical_directory, regular_bytes, digest, PROVENANCE
    root = canonical_directory(args.tree)
    temporary = canonical_directory(args.tmp)
    control = canonical_directory(args.ctl)
    if (args.outer_os not in ('darwin', 'linux') or args.unsandboxed
            or args.outer_os != ('darwin' if sys.platform == 'darwin' else 'linux' if sys.platform.startswith('linux') else '')):
        raise ValueError('experimental review requires supported effective outer OS confinement')
    tool_name = 'sandbox-exec' if args.outer_os == 'darwin' else 'bwrap'
    trusted_tool = shutil.which(tool_name, path=os.defpath)
    effective_tool = shutil.which(os.environ.get('FM_SANDBOX_TOOL') or tool_name)
    if (not trusted_tool or not effective_tool
            or Path(trusted_tool).resolve() != Path(effective_tool).resolve()
            or os.environ.get('FM_SANDBOX_OS', args.outer_os) != args.outer_os):
        raise ValueError('experimental review requires the actual trusted OS sandbox tool')
    policy_path = Path(args.policy)
    if policy_path != control/'review-policy.json':
        raise ValueError('experimental review requires private final reviewer policy')
    raw = regular_bytes(control, policy_path.name, 64*1024)
    policy = json.loads(raw)
    if (digest(raw) != args.policy_sha256 or policy.get('role') != 'reviewer'
            or policy.get('write') != ['{root}', '{tmp}']
            or policy.get('review_git_readonly') is not True):
        raise ValueError('experimental review effective policy changed or lacks readonly metadata')
    if (root == temporary or root in temporary.parents or temporary in root.parents
            or control == root or root in control.parents or control in root.parents
            or control == temporary or temporary in control.parents or control in temporary.parents):
        raise ValueError('experimental review roots must be separate')
    engine = Path(__file__).resolve().parents[2]
    launch = args.launch
    if launch[:1] == ['--']:
        launch = launch[1:]
    if (len(launch) < 3 or launch[0] != str(engine/'bin/fm-sandbox.sh')
            or launch[1] != 'run' or launch[-1] != '--'):
        raise ValueError('experimental review final launcher is unconfined or unsupported')
    values = {}
    for word in launch[2:-1]:
        if not word.startswith('--') or '=' not in word:
            raise ValueError('experimental review launcher has malformed arguments')
        key, value = word[2:].split('=', 1)
        if key not in ('policy', 'root', 'tmp', 'vendor', 'started', 'ctl', 'shed', 'blocked'):
            raise ValueError('experimental review launcher grants unsupported capability')
        if key in values and key != 'shed':
            raise ValueError('experimental review launcher has duplicate capability')
        values[key] = value
    for key, expected in (('policy', str(policy_path)), ('root', str(root)), ('tmp', str(temporary)),
                          ('vendor', 'codex'), ('ctl', str(control)), ('started', str(control/'started'))):
        if values.get(key) != expected:
            raise ValueError('experimental review final launcher binding differs')
    git = root/'.git'
    index = Path(args.index)
    if (not git.is_dir() or git.is_symlink() or git.resolve() != git
            or index.name != 'index.json' or index.parent.parent != git
            or not re.fullmatch(r'\.fm-review-experiments-[A-Za-z0-9_-]+', index.parent.name)):
        raise ValueError('experimental index must be in the fresh checkout own readonly metadata')
    directory = canonical_directory(str(index.parent))
    retained = json.loads(regular_bytes(directory, index.name, 128*1024))
    if retained.get('version') != 1 or retained.get('provenance') != PROVENANCE or not retained.get('records'):
        raise ValueError('experimental review index is unsupported')
    for record in retained['records']:
        for experiment in record['experiments']:
            for artifact in experiment['artifacts']:
                if digest(regular_bytes(directory, artifact['sha256'], 256*1024)) != artifact['sha256']:
                    raise ValueError('experimental readonly copy integrity failure')
    # No producer, model, credential helper or subprocess is used here. Policy
    # bytes are private outside both model write roots until the launcher reads.


def read(path):
    return path.read_bytes().decode("utf-8")


def size(text):
    return len(text.encode('utf-8'))


def provenance(path, text):
    return f'{path} ({size(text)} bytes, sha256={hashlib.sha256(text.encode()).hexdigest()})'


def compact_history(text, path):
    # Keep first and last occurrence of every distinct body, including all
    # text outside the numbered list. Thus original criteria, changed item
    # dispositions, regression explanations, and the latest list stay verbatim.
    pattern = re.compile(
        r'(?m)^## Closed list (\d+) of (\d+), verbatim from the pull request\n\n'
        r'----- begin comment ([0-9a-f]+) -----\n(.*?)'
        r'^----- end comment \3 -----\n', re.S | re.M)
    matches = list(pattern.finditer(text))
    occurrences = {}
    for match in matches:
        occurrences.setdefault(match[4], []).append(match[1])
    first = {body: positions[0] for body, positions in occurrences.items()}
    last = {body: positions[-1] for body, positions in occurrences.items()}

    def replace(match):
        body, number = match[4], match[1]
        if number in (first[body], last[body]):
            return match[0]
        return (f'## Closed list {number} of {match[2]}: exact repeat of closed list '
                f'{first[body]}; body OMITTED, no item or verdict change.\n')

    result = pattern.sub(replace, text)
    # T-135 local records have their own provenance header and nonce, rather
    # than the historical comment envelope. Preserve every header, including
    # round/head/reviewer/provenance, even when its body is an exact repeat.
    local_pattern = re.compile(
        r'(?m)^(Local review round [^\n]+\n)'
        r'----- begin ([0-9a-f]+) -----\n(.*?)'
        r'^----- end \2 -----(?=\n|$)', re.S | re.M)
    local_matches = list(local_pattern.finditer(result))
    positions = {}
    for index, match in enumerate(local_matches):
        positions.setdefault(match[3], []).append(index)
    indexes = {match.start(): index for index, match in enumerate(local_matches)}

    def replace_local(match):
        index = indexes[match.start()]
        repeats = positions[match[3]]
        if index in (repeats[0], repeats[-1]):
            return match[0]
        return (match[1] + f'exact repeat of local review record {repeats[0] + 1}; '
                'body OMITTED, no item or verdict change.')

    result = local_pattern.sub(replace_local, result)
    if result != text:
        result += ('\nHistory compaction: only exact repeated bodies omitted; first and last '
                   'occurrences remain verbatim and chronological. A stale re-issued list is '
                   'not permission to drop an original acceptance item. Report conflicts to '
                   'firstmate; no REJECT has been converted into APPROVE.\n'
                   f'Full selected review history: {provenance(path, text)}\n')
    return result


def compact_evidence(text, path):
    # Only quote payloads can shrink. Job names/results/URLs and all prose
    # saying evidence was unavailable remain intact. Both ends are disclosed
    # as excerpts, never as a complete CI or fail-first result.
    pattern = re.compile(
        r'(?m)^(----- begin (log|fail-first report|gate summary) ([0-9a-f]+) -----\n)'
        r'(.*?)(^----- end \2 \3 -----\n)', re.S | re.M)

    def replace(match):
        body = match[4]
        if size(body) <= QUOTE_CAP:
            return match[0]
        raw = body.encode('utf-8')
        prefix = raw[:QUOTE_CAP // 2].decode('utf-8', errors='ignore')
        suffix = raw[-QUOTE_CAP // 2:].decode('utf-8', errors='ignore')
        return (match[1] + prefix + '\n[OMITTED CI evidence bytes; this quote is an excerpt, '
                'not a complete report. Do not infer success or full coverage from it. '
                f'Full evidence: {provenance(path, text)}]\n' + suffix + match[5])

    return pattern.sub(replace, text)


def compose(directory, mode, checkout):
    output = directory / 'prompt.md'
    # A failed second assembly must not leave an earlier launchable prompt.
    output.unlink(missing_ok=True)
    parts = {name: read(directory / (name + '.md')) for name in PARTS}
    original = ''.join(parts.values())
    if size(original) <= CAP:
        output.write_bytes(original.encode())
        return
    pins = json.loads(read(directory / 'pins.json'))
    sources = directory
    if mode == 'run':
        # The clone's own git directory is inside the authorized read root
        # and read-only in managed review policy. Evidence is metadata, not
        # an untracked worktree change: keep strict fresh-tree admission intact.
        # Never follow a worktree gitfile or symlink outside that read root.
        git_dir = Path(checkout) / '.git'
        if not git_dir.is_dir() or git_dir.is_symlink():
            raise ValueError('context evidence requires the checkout own git directory')
        sources = Path(tempfile.mkdtemp(prefix='.fm-review-context-', dir=git_dir))
        for name in PARTS:
            shutil.copyfile(directory / (name + '.md'), sources / (name + '.md'))
        shutil.copyfile(directory / 'pins.json', sources / 'pins.json')
        (directory / 'evidence-path.txt').write_text(str(sources))
    parts['history'] = compact_history(parts['history'], sources / 'history.md')
    parts['evidence'] = compact_evidence(parts['evidence'], sources / 'evidence.md')
    notice = (f'\n# Bounded review context\nOriginal assembled input: {size(original)} UTF-8 bytes. '
              f'Limit: {CAP} bytes. Any omissions are disclosed below; full source components '
              f'are retained in {sources}. Those paths are evidence, not permission to bypass '
              'the sandbox; report any evidence you cannot read.\n'
              f'Pinned head={pins["head"]} base={pins["base"]} patch={pins["patch"]}\n')
    if size(notice + ''.join(parts.values())) > CAP and mode == 'run':
        # The exact commits, not moving branch names, identify both sides.
        if not all(re.fullmatch(r'[0-9a-f]{40,64}', pins[k]) for k in ('head', 'base', 'patch')):
            raise ValueError('cannot represent oversized diff without complete pinned identities')
        parts['diff'] = (
            '\n---\n\n# The diff under review\n\n'
            'OMITTED entire inline patch; no truncated patch is presented as complete. '
            'Review coverage requires inspecting the actual diff in the pinned checkout '
            f'{checkout}. Read every changed path and hunk, including deletions and binary '
            'changes; disclose anything you could not inspect. Do not approve from this index alone.\n'
            f'Run `git diff --no-ext-diff --no-textconv --no-renames {pins["base"]} {pins["head"]}` '
            'locally; append `-- <path>` to read a file, and use its @@ hunk ranges for line references.\n'
            f'Changed paths (JSON): {json.dumps(pins["files"], ensure_ascii=True)}\n'
            f'Full inline patch source: {provenance(sources / "diff.md", read(directory / "diff.md"))}\n')
    result = notice + ''.join(parts.values())
    if size(result) > CAP:
        raise ValueError(f'cannot represent review context within {CAP} bytes in {mode} mode; '
                         'unique criteria, required instructions, or complete diff exceed budget. '
                         f'No model called. Full components: {directory}')
    output.write_bytes(result.encode())


def main():
    try:
        if sys.argv[1:] == ['opaque-experiment-reference']:
            print('experiment-review-' + secrets.token_hex(12))
            return 0
        if sys.argv[1:2] == ['prepare-experiments']:
            _, directory, mode, checkout, head, base, code = sys.argv[1:]
            prepare_experiments(Path(directory), mode, checkout, head, base, code)
            return 0
        if sys.argv[1:2] == ['verify-effective-experiment-policy']:
            parser = argparse.ArgumentParser()
            for key in ('policy', 'policy-sha256', 'outer-os', 'unsandboxed', 'tree', 'tmp', 'ctl', 'index'):
                parser.add_argument('--'+key, required=True)
            parser.add_argument('launch', nargs=argparse.REMAINDER)
            verify_effective_experiment_policy(parser.parse_args(sys.argv[2:]))
            return 0
        directory, mode, checkout = sys.argv[1:]
        if mode not in ('run', 'diff'):
            raise ValueError('invalid review mode')
        compose(Path(directory), mode, checkout)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f'fm-review: {error}', file=sys.stderr)
        return 65
    return 0


if __name__ == '__main__':
    sys.exit(main())
