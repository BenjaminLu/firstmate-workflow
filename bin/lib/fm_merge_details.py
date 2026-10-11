"""Build checked self-project merge details from an answered dispatch card.

With a usable fm-merge-card block in the review that the readiness record
selected (T-270), its title, why, how, notes and glossary describe what the
reviewed head changed. Otherwise the dispatch card supplies them, with a
caution that nobody reviewed the result for readability.
"""
from copy import deepcopy
import hashlib
import os
from pathlib import Path
import re
import subprocess

from fm_ste import check_details
from fm_watch import read_json

INTENT_FIELDS = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes',
                 'before_nodes', 'after_nodes')
CAUTION = {'en': 'Not reviewed for readability.', 'zh-TW': '未經可讀性審查。'}


def _failures(report):
    lines = []
    for section in ('locales', 'labels'):
        for lang, entries in report.get(section, {}).items():
            for entry in entries:
                for issue in entry['issues']:
                    if issue['severity'] == 'fail':
                        lines.append('{} {}: {} -> {} {}'.format(
                            lang, entry['field'], entry['sentence'], issue['rule'], issue['detail']))
    return lines


def _spec_text(task, head, want, root, env):
    """The spec bytes whose SHA-256 the review bound, read like source_binding()."""
    candidates = []
    try:
        from fm_spec_pins import Pins
        pins_env = dict(env)
        pins_env.update(FM_ENGINE_ROOT=str(root), FM_STATE_DIR=str(Path(root) / 'state'),
                        FM_TASKS_DIR=str(Path(root) / 'design/tasks'),
                        FM_DESIGN=str(Path(root) / 'design/design.md'))
        pin = Pins(pins_env, task).resolve(if_present=True)
        if pin is not None:
            candidates.append(pin['snapshots']['spec']['text'].encode('utf-8'))
    except (ValueError, OSError, ImportError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        pass
    # T-256: the local spec file, never the branch commit, follows the pin.
    try:
        candidates.append((Path(root) / 'design/tasks' / (task + '.json')).read_bytes())
    except OSError:
        pass
    for data in candidates:
        if hashlib.sha256(data).hexdigest() == want:
            return data.decode('utf-8')
    raise ValueError('the spec the review bound is unavailable')


def reviewed_card(state, evidence_project, task, pr_number, readiness, head, root, env=None):
    """The merge_card of the verdict the readiness record selected, with the
    reviewed file list and spec text, or a reason it is unusable."""
    from fm_evidence import Store
    if not isinstance(readiness, dict) or readiness.get('kind') != 'readiness':
        return None, 'no readiness record'
    if (readiness.get('task') != task or readiness.get('project') != evidence_project
            or str(readiness.get('pr')) != str(pr_number) or readiness.get('head') != head):
        return None, 'readiness belongs to another task, project, pull request or head'
    verdicts = [r for r in Store(str(state), evidence_project, task).verdicts()
                if r.get('signature') == readiness.get('verdict_signature')]
    if not verdicts:
        return None, 'the readiness review is not in local evidence'
    verdict = verdicts[-1]
    # A carried approval keeps its own head; gate 6 accepted it for this one.
    if verdict.get('verdict') != 'APPROVE' or verdict.get('merge_card_status') != 'present':
        return None, 'the selected review has no usable merge card'
    binding = verdict.get('binding') or {}
    files = binding.get('files')
    if not isinstance(files, list):
        return None, 'the selected review has no file list'
    try:
        spec = _spec_text(task, verdict.get('head'), binding.get('spec_sha256'), root,
                          env if env is not None else os.environ)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        return None, str(error)
    card = verdict.get('merge_card')
    import fm_plain
    for lang in ('en', 'zh-TW'):
        loc = card.get(lang) if isinstance(card, dict) else None
        if not isinstance(loc, dict) or set(loc) != {'title', 'why', 'how', 'notes', 'glossary'}:
            return None, 'merge card needs title, why, how, notes and glossary in both locales'
        # Check every authored field's shape before any use: a malformed block
        # falls back to the dispatch card instead of failing the build.
        if not isinstance(loc['title'], str):
            return None, 'merge card title needs text'
        for field in ('why', 'how', 'notes'):
            items = loc[field]
            if not isinstance(items, list) or not all(
                    isinstance(item, dict) and isinstance(item.get('text'), str) for item in items):
                return None, 'merge card ' + field + ' needs a list of items with text'
        if not isinstance(loc['glossary'], list) or not all(isinstance(i, str) for i in loc['glossary']):
            return None, 'merge card glossary needs a list of glossary ids'
        texts = [loc['title']] + [item['text'] for field in ('why', 'how', 'notes') for item in loc[field]]
        for text in texts:
            spans = [m[1:-1] for m in re.findall(fm_plain.CODE, text)]
            paths = [re.sub(r':\d+(?:-\d+)?$', '', t.strip('()[]{}<>"\'.,;:!?'))
                     for t in re.sub(fm_plain.CODE, ' ', text).split() if fm_plain._path(t)]
            for token in spans + paths:
                if token not in files and token not in spec:
                    return None, 'merge card names ' + token + ', which is in neither the diff nor the spec'
    return card, ''


def build(state, project, task, pr_number, readiness=None, head=None, root=None,
          evidence_project=None, env=None):
    """Return checked details or raise ValueError with an actionable diagnostic.

    The caller resolves self/external project policy before calling this helper.
    Only answered dispatch A records in this project's task namespace qualify.
    """
    import fm_plain
    from fm_ste import check_plain
    owner = project or 'firstmate-workflow'
    prefix = 'D-' + owner + '-' + task.replace('-', '') + '-'
    candidates = []
    for path in (Path(state) / 'decisions').glob(prefix + '*.json'):
        match = re.fullmatch(re.escape(prefix) + r'([1-9][0-9]*)', path.stem)
        if not match:
            continue
        record = read_json(path)
        if (record.get('task') == task and record.get('project', owner) == owner
                and record.get('purpose') == 'dispatch' and record.get('chosen') == 'A'):
            candidates.append((int(match[1]), record))
    if not candidates:
        raise ValueError('no answered dispatch card')
    source = max(candidates, key=lambda item: item[0])[1].get('details')
    if not isinstance(source, dict):
        raise ValueError('details must be an object')
    card, _ = (reviewed_card(state, evidence_project or owner, task, pr_number, readiness, head,
                             root or Path(state).parent, env)
               if readiness is not None else (None, 'no readiness record'))
    glossary = fm_plain.load_glossary()

    result = {}
    for lang in ('en', 'zh-TW'):
        loc = source.get(lang)
        if not isinstance(loc, dict):
            loc = {}
        en = lang == 'en'
        reviewed = card[lang] if card else None
        title = reviewed['title'] if reviewed else loc.get('title')
        prefix = f'Dispatch {task}: ' if en else f'派工 {task}：'
        if isinstance(title, str):
            title = (f'MERGE CARD — merge PR #{pr_number}: ' if en else
                     f'【合併卡】合併 PR #{pr_number}：') + title.removeprefix(prefix)
        out = {field: deepcopy(loc[field]) for field in INTENT_FIELDS if field in loc}
        fixed = []
        if reviewed:
            out.update(why=deepcopy(reviewed['why']), how=deepcopy(reviewed['how']),
                       notes=deepcopy(reviewed['notes']))
            listed = list(fm_plain.ids_of(reviewed['glossary']))
        else:
            if 'how' in loc:
                out['how'] = deepcopy(loc['how'])
            notes = out.get('notes')
            out['notes'] = (notes if isinstance(notes, list) else []) + [dict(kind='caution', text=CAUTION[lang])]
            fixed.append(CAUTION[lang])
            listed = list(fm_plain.ids_of(loc.get('glossary'))) if 'glossary' in loc else None
        if not out['notes']:
            out.pop('notes')
        # Preserve malformed inputs for the shared checker to diagnose; never
        # truncate a full done list or silently repair an incomplete intent card.
        if isinstance(out.get('done'), list):
            green = ('CI, review and the six gates are green on this head.' if en else
                     '這個 head 的 CI、審查和六關全綠。')
            out['done'].insert(0, dict(kind='fact', text=green))
            fixed.append(green)
        options = loc.get('options')
        options = options if isinstance(options, dict) else {}
        a, b = options.get('A'), options.get('B')
        a = a if isinstance(a, dict) else {}
        b = b if isinstance(b, dict) else {}
        intent = out.get('intent')
        first = intent[0].get('text') if isinstance(intent, list) and intent and isinstance(intent[0], dict) else None
        default_questions = [dict(kind='fact', text=(
            'The change stays inside the pinned scope.' if en else '改動不超出固定的範圍。'))]
        out.update(
            title=title,
            explanation=(f'The review approved {task}. CI, coverage and the six gates must be green on this head before you see this card.' if en else
                         f'審查核准了 {task}。這個 head 的 CI、覆蓋檢查和六關都必須全綠。'),
            before=loc.get('before'), after=loc.get('after'),
            outcome=(f'Option A merges only PR #{pr_number}. The board then replaces itself on the new code.' if en else
                     f'選項 A 只合併 PR #{pr_number}。之後看板自己換上新程式。'),
            options={
                'A': dict(description=f'Merge #{pr_number}' if en else f'合併 #{pr_number}',
                          pros=a.get('pros'), cons=a.get('cons')),
                'B': dict(description='Hold the merge' if en else '暫緩合併',
                          pros='The code stays the same.' if en else '程式維持原樣。', cons=b.get('cons')),
                'C': dict(description='Ask for a fix' if en else '要求修正',
                          pros='You can change the scope.' if en else '你可以改範圍。',
                          cons='A change needs a new review, CI and six gates.' if en else '修改需要重新審查、CI 和六關。')},
            questions=deepcopy(loc.get('questions', default_questions)),
            change_table=[dict(text=first, A='✓', B='—', C='—')])
        if 'questions' not in loc:
            fixed.append(default_questions[0]['text'])
        fixed += [out['title'] or '', out['explanation'], out['outcome']]
        fixed += [out['options'][k][f] for k in 'ABC' for f in ('description', 'pros', 'cons')
                  if (k, f) not in (('A', 'pros'), ('A', 'cons'), ('B', 'cons'))]
        if listed is not None:
            for text in fixed:
                for ident in fm_plain.find_terms(text, lang, glossary):
                    if ident not in listed:
                        listed.append(ident)
            out['glossary'] = listed
        result[lang] = out

    report = check_details(result, kind='merge')
    if not report.get('ok'):
        raise ValueError('\n'.join(_failures(report)))
    plain = check_plain(result)
    if not plain['ok']:
        raise ValueError('\n'.join(plain['problems'] + _failures(plain)))
    return result
