"""A dispatch or repin card takes its spec fields from the task spec (T-301).

    fm_card_spec.py --task <id> --tasks-dir <dir> --details <file>

Reads the task's local spec file, <dir>/<id>.json, never a pin: the card asks
the captain to approve that file. For each locale, each explain key the spec
has is copied into a card that omits it; a card that supplies one must hold
the same JSON value, else it is refused with the field named. Keys the spec
lacks stay as authored. The card must then carry intent, done and both node
lists, whoever wrote them. Prints the merged details; refusals exit 65.
"""
import json
import sys
from pathlib import Path

LOCALES = ('en', 'zh-TW')
SPEC_FIELDS = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes', 'before_nodes', 'after_nodes')
REQUIRED = ('intent', 'done', 'before_nodes', 'after_nodes')


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
    if len(argv) != 6 or sorted(args) != ['--details', '--task', '--tasks-dir']:
        print('usage: fm_card_spec.py --task <id> --tasks-dir <dir> --details <file>', file=sys.stderr)
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
    except (ValueError, OSError) as error:
        print('fm-decide: ' + str(error) + '; nothing was written', file=sys.stderr)
        return 65
    print(json.dumps(merged, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
