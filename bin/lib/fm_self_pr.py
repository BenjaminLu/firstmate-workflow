"""Data-only self PR authoring. Intent indices are zero-based acceptance indices.

Stock Pins owns source/approval validation. Envelopes add publication prose;
they are neither pins, signatures, nor readiness evidence. No network writes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

VERBS = {'Add', 'Fix', 'Update', 'Remove', 'Preserve', 'Prevent', 'Record', 'Show',
         'Refresh', 'Support', 'Validate', 'Bound', 'Use', 'Keep', 'Replace',
         'Improve', 'Allow', 'Reject', 'Restore'}
SOURCE_NAMES = {'spec', 'design', 'contract', 'conventions'}


def pin_digest(pin):
    return hashlib.sha256(json.dumps(pin, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=False).encode('utf-8')).hexdigest()


def source_digests(snapshots):
    return {key: dict(sha256=snapshot['sha256'],
                      absent=snapshot.get('absent', False) or snapshot.get('source') == 'absent')
            for key, snapshot in snapshots.items()}


def prose(value, name):
    if not isinstance(value, str) or not value.strip() or len(value) > 6000:
        raise ValueError(name + ': meaningful authored prose required')
    if any(ord(c) < 32 and c not in '\n\t' for c in value):
        raise ValueError(name + ': control character')
    return value


def validate(draft, spec, sources, approval=None):
    if type(draft.get('schema')) is not int or draft.get('schema') != 1 or draft.get('task') != spec.get('id'):
        raise ValueError('authoring schema/task mismatch')
    if draft.get('sources') != sources or set(sources) != SOURCE_NAMES:
        raise ValueError('authoring source digest mismatch; firstmate must correct the draft')
    for source in sources.values():
        if (set(source) != {'sha256', 'absent'} or type(source['absent']) is not bool
                or not (source['sha256'] is None and source['absent']
                        or isinstance(source['sha256'], str) and re.fullmatch('[0-9a-f]{64}', source['sha256']))):
            raise ValueError('invalid source digest/sentinel')
    subject = draft.get('subject')
    if (not isinstance(subject, str) or not 1 <= len(subject) <= 70
            or any(not 32 <= ord(c) <= 126 for c in subject)
            or len(subject.split()) > 12 or subject != subject.strip()):
        raise ValueError('subject requires one line of 1-70 printable ASCII characters and at most 12 words')
    words = subject.split()
    if len(words) < 2 or words[0] not in VERBS:
        raise ValueError('subject requires an allowed verb and named object')
    if (subject in ('Update task', 'Project work', 'Update ' + spec['id'])
            or re.search(r'[/\\]|\b(?:FM_HOME|FM_STATE_DIR|FM_PINNED_DIR)\b|T-\d+:', subject)
            or spec['id'] in subject or len(spec['id'] + ': ' + subject) > 85):
        raise ValueError('subject is generic, repeats the task, references local state, or exceeds final title length')
    if draft.get('size') not in ('small', 'complex'):
        raise ValueError('size must be authored small or complex')
    for field in ('problem', 'expected_result', 'approach'):
        prose(draft.get(field), field)
    notes = draft.get('intent_notes')
    if not isinstance(notes, list) or not notes:
        raise ValueError('intent_notes requires indexed authored purpose')
    intents = spec.get('acceptance', [])
    seen = set()
    for note in notes:
        index = note.get('index') if isinstance(note, dict) else None
        if type(index) is not int or not 0 <= index < len(intents) or index in seen:
            raise ValueError('intent index must be a unique zero-based acceptance index')
        seen.add(index); prose(note.get('note'), 'intent note')
    reference = draft.get('dispatch_reference')
    if reference is not None and (not approval or reference != approval.get('decision')):
        raise ValueError('dispatch reference does not match retained stock approval')
    door = draft.get('door')
    if door is not None:
        if not isinstance(door, dict) or door.get('kind') not in ('two-way', 'one-way', 'mixed', 'not-recorded'):
            raise ValueError('invalid door')
        prose(door.get('reason'), 'door reason')
    rollback = draft.get('rollback')
    if rollback not in (None, 'not-recorded'):
        if not isinstance(rollback, dict): raise ValueError('invalid rollback')
        for field in ('trigger', 'action', 'owner', 'limits'): prose(rollback.get(field), 'rollback '+field)
    return draft


def state_path(state, relative):
    """Reject symlink ancestors and any escape, including on output paths."""
    state = Path(state).absolute()
    target = state / relative
    if target != state and state not in target.parents:
        raise ValueError('authoring outside real state')
    for path in (state, *state.parents, target, *target.parents):
        if path.is_symlink(): raise ValueError('authoring state/path must not be a symlink')
    if state.resolve() != state or not target.resolve().is_relative_to(state):
        raise ValueError('authoring outside real state')
    return target


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as out:
        temporary = Path(out.name)
        json.dump(data, out, ensure_ascii=False, indent=2)
        out.write('\n'); out.flush(); os.fsync(out.fileno())
    try: os.replace(temporary, path)
    finally: temporary.unlink(missing_ok=True)


def authority(task, evidence_project, prospective=False):
    """Obtain stock approved snapshots, or narrowly classified legacy sources.

    For legacy mode re-run stock creation's source collector. Only absence of
    required design or gate contract may explain inability to pin; all other
    collector errors refuse. Spec bytes follow stock's exact legacy preflight.
    """
    from fm_spec_pins import Pins, contract, digest, git
    state_path(os.environ['FM_STATE_DIR'], 'pr-authoring/'+task+'.json')
    pins = Pins(os.environ, task)
    if pins.external: raise ValueError('self authoring cannot consume external records')
    pin = pins.resolve(if_present=True)
    if pin:
        pins.preflight(evidence_project)
        return pins, pin, pin['snapshots'], pin['approval'], None
    pins.preflight(evidence_project)
    approval = pins.approval(None)
    if not approval and not prospective: raise ValueError('legacy publication requires retained stock dispatch authorization')
    try:
        _, _, prospective_snapshots, _ = pins.collect()
    except (ValueError, OSError) as error:
        failure = str(error)
    else:
        if prospective: return pins, None, prospective_snapshots, approval, None
        raise ValueError('unexpected pin failure: approved required sources are available')
    head = git(pins.engine, 'rev-parse', pins.engine_base+'^{commit}').strip()
    snapshots = {}
    spec_text = (pins.tasks/(task+'.json')).read_bytes().decode('utf-8')
    legacy_spec = json.loads(spec_text)
    if (legacy_spec.get('id') != task or not isinstance(legacy_spec.get('scope'), list)
            or not legacy_spec['scope'] or not all(isinstance(s, str) and s and '\n' not in s
                                                   for s in legacy_spec['scope'])):
        raise ValueError('invalid approved task scope; not solely missing required contract/design')
    snapshots['spec'] = dict(text=spec_text, sha256=digest(spec_text), source='legacy-preflight')
    design_path = str(pins.design.relative_to(pins.engine))
    try:
        snapshots['design'] = pins.snapshot(pins.design, head)
    except ValueError:
        # A failing git show is absence only if the approved tree lacks that
        # path. Permission, mock, object, or corrupt-tree errors cannot qualify.
        listing = git(pins.engine, 'ls-tree', '--name-only', head, '--', design_path)
        if listing.strip(): raise ValueError('unexpected design source failure')
        snapshots['design'] = dict(text='', sha256=None, source='absent')
    snapshots['conventions'] = pins.snapshot(pins.engine/'CONVENTIONS.md', head, optional=True)
    snapshots['contract'] = pins.snapshot(pins.engine/'config.yaml', head)
    missing_contract = False
    try: contract(snapshots['contract']['text'], pins.project)
    except ValueError as error:
        if str(error) != 'no approved gate contract': raise
        missing_contract = True
    missing_design = snapshots['design']['source'] == 'absent'
    if not (missing_contract or missing_design): raise ValueError('unsupported pin-unavailable cause')
    if not (failure == 'no approved gate contract' or (missing_design and
            (failure == 'git source unavailable: show '+head+':'+design_path
             or failure == 'missing approved source: '+str(pins.design)))):
        raise ValueError('unexpected pin failure; publication refused')
    # Config bytes are available even when they contain no contract. Preserve
    # their digest and label absent contract separately, never invent a hash.
    snapshots['contract']['absent'] = missing_contract
    from fm_evidence import Store
    from fm_spec_preflight import require_ok
    exact_spec = (pins.tasks/(task+'.json')).read_bytes()
    if exact_spec != snapshots['spec']['text'].encode():
        raise ValueError('legacy stock preflight source mismatch')
    require_ok(Store(pins.state, evidence_project, task), exact_spec)
    reason = dict(missing_sources=[name for name, missing in
                                   (('contract', missing_contract), ('design', missing_design)) if missing],
                  stock_reason=failure)
    return pins, None, snapshots, approval, reason


def dispatch_approval(pins, pin, draft, current):
    # resolve() already authenticated every history record. Retained dispatch
    # differs from a later semantic repin; prose may cite that original receipt.
    if not pin: return current
    history = [json.loads((pins.directory/(str(version)+'.json')).read_text())['approval']
               for version in range(1, pin['version']+1)]
    reference = draft.get('dispatch_reference')
    if reference is None: return history[0]
    return next((approval for approval in history if approval['decision'] == reference), current)


def seal(task, evidence_project, expected_mode=None, expected_digest=None):
    pins, pin, snapshots, approval, reason = authority(task, evidence_project)
    mode = 'pin-backed' if pin else 'unsealed-legacy'
    if (expected_mode is not None and expected_mode != mode
            or expected_digest is not None and (not pin or pin_digest(pin) != expected_digest)):
        raise ValueError('stock returned pin changed before publication sealing')
    path = state_path(pins.state, 'pr-authoring/'+task+'.json')
    if not path.is_file():
        raise ValueError('authoring-required: firstmate must author state/pr-authoring/'+task+'.json before dispatch')
    draft = json.loads(path.read_text())
    sources = source_digests(snapshots)
    approval = dispatch_approval(pins, pin, draft, approval)
    validate(draft, json.loads(snapshots['spec']['text']), sources, approval)
    envelope = dict(schema=1, project=pins.project, task=task, sources=sources, draft=draft,
                    dispatch_reference=approval.get('decision') if approval else None,
                    mode='pin-backed' if pin else 'unsealed-legacy')
    if pin:
        envelope['pin'] = dict(version=pin['version'])
        envelope['pin_sha256'] = pin_digest(pin)
    else: envelope['pin_unavailable_reason'] = reason
    output = state_path(pins.state, 'pr-authoring/envelopes/'+task+'.json')
    save(output, envelope)
    return envelope


def repository_identity(repository, origin=''):
    grammar = r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'
    if re.fullmatch(grammar, repository or ''): return repository
    match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?', origin)
    return match.group(1) if match else ''


def render(envelope, spec, head, files, repository='', created_at=None, question=None):
    if not re.fullmatch(r'[0-9a-f]{40,64}', head): raise ValueError('invalid exact head')
    if question not in (None, 'scope', 'acceptance', 'implementation'): raise ValueError('invalid question purpose')
    draft = envelope['draft']
    subject = draft['subject']
    title = spec['id']+': '+('Ask about '+subject.split(' ', 1)[1] if question else subject)
    if len(title) > 85: raise ValueError('final title exceeds 85 characters')
    stamp = created_at or datetime.now(timezone.utc).isoformat()
    status = (f'Status at PR creation ({stamp}) for exact head `{head}`: '
              'Required CI: pending/not collected; Review: pending/not collected; six gates: pending/not collected. '
              'Local validation: not recorded. These creation-time entries require a current readiness check at the PR.')
    repository = repository_identity(repository)
    evidence = ('Check current CI and review at this PR. '
                + (f'[Exact head](https://github.com/{repository}/commit/{head}).' if repository
                   else 'Links omitted; current evidence unavailable.'))
    decision = 'Dispatch decision reference: '+(envelope.get('dispatch_reference') or 'not recorded')+'.'
    mode = ('Publication metadata is unsealed legacy: publication pin unavailable; scope gate not authorized '
            'by this envelope.'
            if envelope['mode'] == 'unsealed-legacy' else
            'Publication prose is bound to the approved pin; it grants no approval or gate authority.')
    expected = 'Expected result: '+draft['expected_result']
    if question:
        body = '\n\n'.join([f'Draft awaiting {question} clarification for approved task {spec["id"]}.',
                            expected, status, evidence, decision, mode])
    else:
        approach = 'Proposed approach (until firstmate verifies it): '+draft['approach']
        if files is None:
            scope = 'Observed scope at this exact head: not collected.'
        else:
            if not isinstance(files, list) or not all(isinstance(f, str) and f and not f.startswith('/')
                                                      and '\n' not in f for f in files):
                raise ValueError('invalid observed diff paths')
            scope = 'Observed scope at this exact head: '+(', '.join('`'+f.replace('`', '\\`')+'`' for f in files)
                                                           or 'no changed files')+'.'
        door = draft.get('door', spec.get('door'))
        if isinstance(door, str) and door in ('two-way', 'one-way', 'mixed', 'not-recorded'):
            door = dict(kind=door, reason='not recorded')
        if not (isinstance(door, dict) and door.get('kind') in ('two-way', 'one-way', 'mixed', 'not-recorded')
                and isinstance(door.get('reason'), str)):
            door = None
        door_text = 'Door: '+(door['kind']+' — '+door['reason'] if door else 'not recorded')+'.'
        rollback = draft.get('rollback', spec.get('rollback'))
        rollback_text = 'Rollback: '+('; '.join(k+': '+(rollback[k] if isinstance(rollback.get(k), str) else 'not recorded') for k in ('trigger','action','owner','limits'))
                                     if isinstance(rollback, dict) else 'not recorded')+'.'
        intents = ['| Approved purpose (zero-based acceptance index) | Creation-time evidence |', '|---|---|']
        for note in draft['intent_notes']:
            safe = note['note'].replace('|', '\\|').replace('\n', ' ')
            intents.append(f'| {note["index"]}: {safe} | Pending/not collected |')
        if draft['size'] == 'complex':
            body = '\n\n'.join(['## Problem and result', 'Approved task: '+spec['id']+'. Project: '+envelope.get('project', 'not recorded')+'.\n\n'+draft['problem']+'\n\n'+expected,
                                 '## Approach and scope', approach+'\n\n'+scope,
                                 '## Approved intent and evidence', '\n'.join(intents), status, evidence,
                                 '## Decision, migration and rollback', decision, mode,
                                 'Migration: new self PRs only; existing and adopted metadata is preserved.',
                                 door_text, rollback_text])
        else:
            purpose = 'Approved purpose: '+'; '.join(note['note'] for note in draft['intent_notes'])+'.'
            body = '\n\n'.join(['Approved task: '+spec['id']+'. Project: '+envelope.get('project', 'not recorded')+'.\n\n'+draft['problem']+'\n\n'+expected, approach, scope, purpose,
                                 status, evidence, decision, mode, door_text, rollback_text])
    return dict(title=title, body=body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate', 'seal', 'render', 'preview'])
    parser.add_argument('--task', required=True)
    parser.add_argument('--evidence-project', default='self')
    parser.add_argument('--head')
    parser.add_argument('--repository', default='')
    parser.add_argument('--origin', default='')
    parser.add_argument('--files')
    parser.add_argument('--publication-mode', choices=['pin-backed', 'unsealed-legacy'])
    parser.add_argument('--pin-sha256')
    parser.add_argument('--question', choices=['scope', 'acceptance', 'implementation'])
    parser.add_argument('--pr', type=int)
    parser.add_argument('--old-title-sha256')
    parser.add_argument('--old-body-sha256')
    args = parser.parse_args()
    try:
        if args.command in ('validate', 'seal'):
            # validate writes no derivative; seal is exclusively the outer launcher.
            if args.command == 'seal': result = seal(args.task, args.evidence_project, args.publication_mode, args.pin_sha256)
            else:
                pins, pin, snapshots, approval, _ = authority(args.task, args.evidence_project, prospective=True)
                draft = json.loads(state_path(pins.state, 'pr-authoring/'+args.task+'.json').read_text())
                approval = dispatch_approval(pins, pin, draft, approval)
                result = validate(draft, json.loads(snapshots['spec']['text']), source_digests(snapshots), approval)
        else:
            pins, pin, snapshots, approval, reason = authority(args.task, args.evidence_project)
            envelope = json.loads(state_path(pins.state, 'pr-authoring/envelopes/'+args.task+'.json').read_text())
            sources = source_digests(snapshots)
            approval = dispatch_approval(pins, pin, envelope['draft'], approval)
            validate(envelope['draft'], json.loads(snapshots['spec']['text']), sources, approval)
            expected_pin = dict(version=pin['version']) if pin else None
            expected_digest = pin_digest(pin) if pin else None
            if (envelope.get('schema') != 1 or envelope.get('project') != pins.project
                    or envelope.get('task') != args.task or envelope.get('sources') != sources
                    or envelope.get('pin') != expected_pin
                    or envelope.get('pin_sha256') != expected_digest
                    or args.publication_mode is not None and args.publication_mode != envelope.get('mode')
                    or args.pin_sha256 is not None and args.pin_sha256 != expected_digest
                    or envelope.get('mode') != ('pin-backed' if pin else 'unsealed-legacy')
                    or envelope.get('dispatch_reference') != (approval.get('decision') if approval else None)
                    or envelope.get('pin_unavailable_reason') != reason):
                raise ValueError('sealed publication digest/mode mismatch')
            files = json.loads(Path(args.files).read_text()) if args.files else None
            result = render(envelope, json.loads(snapshots['spec']['text']), args.head, files,
                            repository_identity(args.repository, args.origin), question=args.question)
            if args.command == 'preview':
                if args.pr is None or args.pr <= 0 or not all(re.fullmatch('[0-9a-f]{64}', x or '') for x in
                                          (args.old_title_sha256, args.old_body_sha256)):
                    raise ValueError('preview requires exact PR/head and current title/body hashes')
                result = dict(repository=repository_identity(args.repository, args.origin), task=args.task,
                              pr=args.pr, head=args.head, old_title_sha256=args.old_title_sha256,
                              old_body_sha256=args.old_body_sha256, proposed=result)
            else:
                save(state_path(pins.state, 'pr-authoring/previews/'+args.task+'-'+args.head+'.json'), result)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print('fm-self-pr: '+str(error), file=sys.stderr)
        return 65


if __name__ == '__main__': sys.exit(main())
