"""Build checked self-project merge details from an answered dispatch card."""
from copy import deepcopy
from pathlib import Path
import re

from fm_ste import check_details
from fm_watch import read_json

INTENT_FIELDS = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes',
                 'before_nodes', 'after_nodes')


def build(state, project, task, pr_number):
    """Return checked details or raise ValueError with an actionable diagnostic.

    The caller resolves self/external project policy before calling this helper.
    Only answered dispatch A records in this project's task namespace qualify.
    """
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

    result = {}
    for lang in ('en', 'zh-TW'):
        loc = source.get(lang)
        if not isinstance(loc, dict):
            loc = {}
        en = lang == 'en'
        title = loc.get('title')
        prefix = f'Dispatch {task}: ' if en else f'派工 {task}：'
        if isinstance(title, str):
            title = (f'MERGE CARD — merge PR #{pr_number}: ' if en else
                     f'【合併卡】合併 PR #{pr_number}：') + title.removeprefix(prefix)
        out = {field: deepcopy(loc[field]) for field in INTENT_FIELDS if field in loc}
        # Preserve malformed inputs for the shared checker to diagnose; never
        # truncate a full done list or silently repair an incomplete intent card.
        if isinstance(out.get('done'), list):
            out['done'].insert(0, dict(kind='fact', text=(
                'CI, review and the six gates are green on this head.' if en else
                '這個 head 的 CI、審查和六關全綠。')))
        options = loc.get('options')
        options = options if isinstance(options, dict) else {}
        a, b = options.get('A'), options.get('B')
        a = a if isinstance(a, dict) else {}
        b = b if isinstance(b, dict) else {}
        intent = out.get('intent')
        first = intent[0].get('text') if isinstance(intent, list) and intent and isinstance(intent[0], dict) else None
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
            questions=deepcopy(loc.get('questions', [dict(kind='fact', text=(
                'The change stays inside the pinned scope.' if en else '改動不超出固定的範圍。'))])),
            change_table=[dict(text=first, A='✓', B='—', C='—')])
        result[lang] = out

    report = check_details(result, kind='merge')
    if not report.get('ok'):
        lines = []
        for section in ('locales', 'labels'):
            for lang, entries in report[section].items():
                for entry in entries:
                    for issue in entry['issues']:
                        if issue['severity'] == 'fail':
                            lines.append('{} {}: {} -> {} {}'.format(
                                lang, entry['field'], entry['sentence'], issue['rule'], issue['detail']))
        raise ValueError('\n'.join(lines))
    return result
