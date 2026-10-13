"""A dispatch or repin card takes its spec fields from the task spec (T-301).

    fm_card_spec.py --task <id> --tasks-dir <dir> --details <file> [--config <file>]

Reads the task's local spec file, <dir>/<id>.json, never a pin: the card asks
the captain to approve that file. For each locale, each explain key the spec
has is copied into a card that omits it; a card that supplies one must hold
the same JSON value, else it is refused with the field named. Keys the spec
lacks stay as authored. The card must then carry intent, done and both node
lists, whoever wrote them. Prints the merged details; refusals exit 65.

T-303: with --config (the engine config.yaml; the self project only) each
locale also gets the door the pin will keep, with its reason and a fixed
rollback line. The author never writes it; fm-decide.sh refuses one.
"""
import json
import sys
from pathlib import Path

LOCALES = ('en', 'zh-TW')
SPEC_FIELDS = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes', 'before_nodes', 'after_nodes')
REQUIRED = ('intent', 'done', 'before_nodes', 'after_nodes')
ROLLBACK = {
    'two-way': {'en': 'A revert of the merge undoes the change.',
                'zh-TW': '還原這次合併即可撤銷改動。'},
    'one-way': {'en': 'A revert alone does not undo the change, so the plan round states the rollback.',
                'zh-TW': '單靠還原無法撤銷改動，所以計畫輪寫明回復方式。'},
}


def door(spec, config_text):
    """The door the pin will keep, as a card shows it in each locale."""
    import fm_door
    found = fm_door.effective(spec, config_text)
    reasons = dict(en=found['reason'], **{'zh-TW': found['reason']})
    if found['forced_by']:
        reasons['zh-TW'] = f'範圍 {found["forced_by"]} 在敏感路徑清單上，所以任務走 one-way 流程。'
    elif found['reason'] == fm_door.NO_DOOR:
        reasons['zh-TW'] = 'spec 沒寫 door，所以任務走 one-way 流程。'
    elif found['reason'] == fm_door.BAD_DOOR:
        reasons['zh-TW'] = 'spec 的 door 不是種類加理由，所以任務走 one-way 流程。'
    return {lang: dict(kind=found['kind'], reason=reasons[lang], rollback=ROLLBACK[found['kind']][lang])
            for lang in LOCALES}


def merge(spec, details, task):
    if not isinstance(spec, dict) or spec.get('id') != task:
        raise ValueError('the task spec is not ' + task + "'s")
    explain = spec.get('explain')
    explain = explain if isinstance(explain, dict) else {}
    for lang in LOCALES:
        card = details.get(lang)
        if not isinstance(card, dict):
            raise ValueError(lang + ': required on the card')
        source = explain.get(lang)
        source = source if isinstance(source, dict) else {}
        for field in SPEC_FIELDS:
            if field not in source:
                continue
            if field not in card:
                card[field] = source[field]
            elif card[field] != source[field]:
                raise ValueError(lang + '.' + field + ' differs from the task spec')
        for field in REQUIRED:
            if field not in card:
                raise ValueError(lang + '.' + field + ': a dispatch or repin card needs it, from the task spec or the card')
    return details


def main(argv):
    args = dict(zip(argv[::2], argv[1::2]))
    if (len(argv) not in (6, 8) or len(args) * 2 != len(argv)
            or sorted(set(args) - {'--config'}) != ['--details', '--task', '--tasks-dir']):
        print('usage: fm_card_spec.py --task <id> --tasks-dir <dir> --details <file> [--config <file>]', file=sys.stderr)
        return 64
    task = args['--task']
    path = Path(args['--tasks-dir']) / (task + '.json')
    try:
        if not path.is_file():
            raise ValueError('no task spec at ' + str(path))
        spec = json.loads(path.read_text(encoding='utf-8'))
        details = json.loads(Path(args['--details']).read_text(encoding='utf-8'))
        if not isinstance(details, dict):
            raise ValueError('details must be an object')
        merged = merge(spec, details, task)
        if '--config' in args:
            config = Path(args['--config'])
            import fm_plain
            glossary = fm_plain.load_glossary()
            for lang, value in door(spec, config.read_text(encoding='utf-8') if config.is_file() else '').items():
                merged[lang]['door'] = value
                # the terms the door text uses are explained on the card
                listed = merged[lang].get('glossary')
                if isinstance(listed, list):
                    used = fm_plain.find_terms(value['reason'] + '\n' + value['rollback'], lang, glossary)
                    listed += [ident for ident in dict.fromkeys(used) if ident not in listed]
    except (ValueError, OSError) as error:
        print('fm-decide: ' + str(error) + '; nothing was written', file=sys.stderr)
        return 65
    print(json.dumps(merged, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
