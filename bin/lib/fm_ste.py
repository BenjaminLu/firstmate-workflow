#!/usr/bin/env python3
"""Single source for intent-card STE checks and the board's rule data.

This mechanical subset cannot assess meaning, translations, or manual rules.
Malformed details raise ValueError; prose failures are returned in the report.
"""
import json
import re
import sys

IMPERATIVE = 'add allow approve ask change check choose close confirm copy delete dispatch do find fix give hold keep let make merge move open put read record remove repin replace rerun run send set show start stop tell type update use wait widen write'.split()
UNAPPROVED = dict(zip(
    ['utilize', 'utilise', 'ensure', 'perform', 'approximately', 'commence', 'terminate', 'prior to', 'in order to', 'via', 'obtain', 'additional', 'require', 'requires', 'is able to', 'are able to', 'facilitate', 'subsequently', 'numerous', 'regarding', 'attempt', 'sufficient', 'indicate', 'indicates', 'modify', 'initiate', 'assist'],
    ['use', 'use', 'make sure', 'do', 'about', 'start', 'stop', 'before', 'to', 'through', 'get', 'more', 'need', 'needs', 'can', 'can', 'help', 'then', 'many', 'about', 'try', 'enough', 'show', 'shows', 'change', 'start', 'help']))
ING_OK = set('string thing during nothing something anything everything ring bring king spring sting swing ping pending missing existing following remaining timing timings sharding routing ceiling pricing preflight warning morning evening building'.split())
WORD = r"[A-Za-z0-9#][A-Za-z0-9#'._/-]*"
ZH_WORD = r'[A-Za-z0-9#._/-]+'
CJK = r'[\u4e00-\u9fff]'
PASSIVE = r'\b(is|are|was|were|be|been|being|gets|got)\s+(\w+ly\s+)?(\w+ed|built|done|found|given|held|kept|known|made|met|paid|put|read|run|seen|sent|set|shown|split|taken|told|written|thrown|broken|chosen)\b'
MULTI = r'(,|;|\band then\b|\bthen\b|\band\b)\s+(' + '|'.join(IMPERATIVE) + r')\b'
MODAL = r'\b(will|would|could|should|shall|might)\b'
VAGUE = r'\b(etc\.?|and/or|some|appropriate|appropriately|properly|various|relevant)\b'
CONTRACTION = r"\b\w+'(t|s|re|ve|ll|d)\b"
NOTE = r'\b(note|caution|warning|important)\b[:\s]'
ZH_MULTI = r'(並且|並|然後|再|同時|以及|接著)'
ZH_PASSIVE = r'(被|受到|由[^，。]{1,8}所)'
ZH_MODAL = r'(將會|將|應該|應當|會不會)'
ZH_VAGUE = r'(可能|大概|左右|等等|適當|盡量|相關|一些|之類)'
ZH_NOTE = r'(注意|警告)[：:]'
ZH_IMPERATIVE = r'^(請)?(合併|派工|派|審查|重跑|重新|修|修正|移除|加入|改|更新|確認|停|停止|啟動|寫|讀|搬|搬到|放|保留|檢查|執行|跑|選|設|設定|擴大|發|等)'
GLOSSARY = {'併入': '合併', '審核': '審查', '分派': '派工', '檢閱': '審查', '佈署': '部署', '預審': '預檢'}
LIMITS = {'en': {'step': 20, 'fact': 25, 'label': 6}, 'zh-TW': {'step': 25, 'fact': 30, 'label': 14}}
NEW_FIELDS = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes', 'questions', 'before_nodes', 'after_nodes', 'change_table')
WALK_FIELDS = ('change_points', 'door', 'check')
LEGACY_FIELDS = NEW_FIELDS
NEW_FIELDS += WALK_FIELDS + ('scene',)
# A retrospective card's per-item list (T-273); it makes no card an intent card.
ITEM_FIELDS = ('items',)
NEW_FIELDS += ITEM_FIELDS
# why, how and glossary appear on every card (T-270); alone they never make
# a card an intent card.
PLAIN_FIELDS = ('why', 'how', 'glossary')
INTENT_TRIGGERS = tuple(field for field in NEW_FIELDS if field not in PLAIN_FIELDS)
CARD_LISTS = LEGACY_FIELDS + ('how',)
LOCALES = ('en', 'zh-TW')
ITEM_KEYS = {'id', 'project', 'title', 'why', 'how', 'evidence', 'scope', 'effect', 'removes', 'why_not_removal'}
ITEM_ID = r'(firstmate|self|P-[0-9a-f]{8})/R[1-9][0-9]{0,3}'


def rules():
    """JSON-ready display contract; patterns and lists are the checker's own."""
    descriptions = [
        ('R1', 'Limit a step to 20 words.', '指令最多 20 個字詞。', 'fail'),
        ('R2', 'Limit a fact to 25 words; a label to 6.', '敘述最多 25 個字詞；標籤最多 6 個。', 'fail'),
        ('R3', 'Use one instruction per step.', '每個步驟只寫一個指令。', 'fail'),
        ('R4', 'Use active voice (facts receive a warning).', '使用主動語態（敘述僅提示）。', {'step': 'fail', 'fact': 'warn'}),
        ('R5', 'Do not use future or modal verbs.', '不使用未來式或情態動詞。', 'fail'),
        ('R6', 'Use approved words.', '使用核准字詞。', 'fail'),
        ('R7', 'Review words that end in -ing.', '檢查以 -ing 結尾的字詞。', 'warn'),
        ('R8', 'Do not use vague words or contractions.', '不使用模糊字詞或縮寫形式。', 'fail'),
        ('R9', 'Put notes outside steps.', '把註記放在步驟之外。', 'fail'),
        ('R10', 'At most 6 sentences per paragraph and 3 nouns per cluster; checked by eye.', '每段最多 6 句，名詞群最多 3 個名詞；人工檢查。', 'manual'),
        ('Z1', 'Limit a step to 25 units, a fact to 30, a label to 14.', '指令最多 25 單位，敘述最多 30 單位，標籤最多 14 單位。', 'fail'),
        ('Z2', 'Use one action per step.', '每個步驟只寫一個動作。', 'fail'),
        ('Z3', 'Use active voice.', '使用主動語態。', 'fail'),
        ('Z4', 'Do not use future or modal words.', '不使用未來或情態用詞。', 'fail'),
        ('Z5', 'Do not use vague words.', '不使用模糊字詞。', 'fail'),
        ('Z6', 'Use one term per meaning.', '同一意思使用同一術語。', 'fail'),
        ('Z7', 'Put notes outside steps.', '把註記放在步驟之外。', 'fail'),
        ('Z8', 'At most 6 sentences per paragraph; checked by eye.', '每段最多 6 句；人工檢查。', 'manual'),
    ]
    return {'rules': [dict(id=i, text={'en': en, 'zh-TW': zh}, severity=s) for i, en, zh, s in descriptions],
            'limits': LIMITS, 'word_lists': {'IMPERATIVE': IMPERATIVE, 'UNAPPROVED': UNAPPROVED,
                                          'ING_OK': sorted(ING_OK), 'GLOSSARY': GLOSSARY},
            'patterns': {name: globals()[name] for name in ('WORD', 'ZH_WORD', 'CJK', 'PASSIVE', 'MULTI', 'MODAL', 'VAGUE', 'CONTRACTION', 'NOTE', 'ZH_MULTI', 'ZH_PASSIVE', 'ZH_MODAL', 'ZH_VAGUE', 'ZH_NOTE', 'ZH_IMPERATIVE')}}


def split(text):
    return [part.strip() for part in re.split(r'(?<=[.!?])\s+|(?<=[。！？])', text) if part.strip()]


def _check(text, kind=None, is_label=False):
    text = re.sub(r'`[^`]*`', 'CODETOKEN', text).strip()
    lang = 'zh-TW' if re.search(CJK, text) else 'en'
    words = re.findall(WORD, text)
    if kind is None:
        first = re.match(r'[A-Za-z]+\b', text)
        step = re.match(ZH_IMPERATIVE, text) if lang == 'zh-TW' else first and first.group().lower() in IMPERATIVE
        kind = 'step' if step else 'fact'
    if kind not in ('step', 'fact'):
        raise ValueError('kind must be step or fact')
    n = len(re.findall(CJK + '|' + ZH_WORD, text)) if lang == 'zh-TW' else len(words)
    maximum = LIMITS[lang]['label' if is_label else kind]
    issues = []

    def issue(rule, detail, severity='fail'):
        issues.append(dict(rule=rule, detail=detail, severity=severity))

    def matches(rule, pattern, severity='fail'):
        for match in re.finditer(pattern, text, re.I):
            issue(rule, match.group(), severity)

    if n > maximum:
        issue('Z1' if lang == 'zh-TW' else ('R1' if kind == 'step' else 'R2'), '{} > {}'.format(n, maximum))
    if lang == 'en':
        if kind == 'step':
            matches('R3', MULTI)
            matches('R9', NOTE)
        matches('R4', PASSIVE, 'fail' if kind == 'step' else 'warn')
        matches('R5', MODAL)
        for found, use in UNAPPROVED.items():
            pattern = r'\b' + r'\s+'.join(map(re.escape, found.split())) + r'\b'
            for match in re.finditer(pattern, text, re.I):
                issue('R6', match.group() + ' -> ' + use)
        for match in re.finditer(r'\b[A-Za-z][a-z]+ing\b', text):
            word = match.group()
            if len(word) > 4 and word.lower() not in ING_OK:
                issue('R7', word, 'warn')
        matches('R8', VAGUE)
        matches('R8', CONTRACTION)
    else:
        if kind == 'step':
            matches('Z2', ZH_MULTI)
            matches('Z7', ZH_NOTE)
        matches('Z3', ZH_PASSIVE)
        matches('Z4', ZH_MODAL)
        matches('Z5', ZH_VAGUE)
        for found, use in GLOSSARY.items():
            for match in re.finditer(found, text):
                issue('Z6', match.group() + ' -> ' + use)
    return dict(lang=lang, n=n, max=maximum, kind=kind, issues=issues)


def check(text, kind=None):
    return _check(text, kind)


def label(text):
    return _check(text, 'fact', True)


def _text(value, field, maximum=2000):
    if not isinstance(value, str) or not 1 <= len(value) <= maximum or not value.strip():
        raise ValueError(field + ': expected nonempty text of at most {} code points'.format(maximum))
    if any((ord(c) < 32 and c not in '\t\n\r') or 127 <= ord(c) <= 159 or 55296 <= ord(c) <= 57343 for c in value):
        raise ValueError(field + ': prohibited control or surrogate')


def _integer(value, low, high):
    return type(value) is int and low <= value <= high


def _walk(details):
    if not any(key in details.get(lang, {}) for lang in LOCALES for key in WALK_FIELDS):
        return
    for key in WALK_FIELDS:
        if (key in details['en']) != (key in details['zh-TW']):
            raise ValueError(key + ': required in both locales or neither')
    for lang in LOCALES:
        loc = details[lang]
        points = loc.get('change_points')
        if not isinstance(loc.get('intent'), list) or not loc['intent']:
            raise ValueError(lang + '.intent: expected nonempty array')
        count = len(loc['intent'])
        if not isinstance(points, list) or not points:
            raise ValueError(lang + '.change_points: expected nonempty array')
        for point in points:
            if not isinstance(point, dict) or set(point) != {'intent', 'how'} or not _integer(point.get('intent'), 1, count):
                raise ValueError(lang + '.change_points: invalid intent or fields')
            _text(point['how'], lang + '.change_points.how')
            if len(split(point['how'])) != 1:
                raise ValueError(lang + '.change_points.how: expected one fact sentence')
        if {p['intent'] for p in points} != set(range(1, count + 1)):
            raise ValueError(lang + '.change_points: every intent needs a point')
        door = loc.get('door')
        if not isinstance(door, dict) or set(door) != {'kind', 'reason', 'rollback'} or door.get('kind') not in ('one-way', 'two-way'):
            raise ValueError(lang + '.door: expected kind, reason and rollback')
        for key in ('reason', 'rollback'):
            _text(door[key], lang + '.door.' + key)
        if door['kind'] == 'two-way':
            if 'check' in loc:
                raise ValueError(lang + '.check: forbidden for two-way door')
            continue
        check = loc.get('check')
        if not isinstance(check, dict) or set(check) != {'q', 'options', 'why', 'about'}:
            raise ValueError(lang + '.check: required for one-way door')
        for key in ('q', 'why'):
            _text(check[key], lang + '.check.' + key)
        options = check['options']
        if not isinstance(options, list) or not 2 <= len(options) <= 4:
            raise ValueError(lang + '.check.options: expected 2-4 options')
        for option in options:
            _text(option, lang + '.check.options')
        about = check['about']
        if not isinstance(about, dict) or set(about) != {'intent'} or not _integer(about.get('intent'), 1, count):
            raise ValueError(lang + '.check.about: invalid intent')
    en, zh = details['en'], details['zh-TW']
    if [p['intent'] for p in en['change_points']] != [p['intent'] for p in zh['change_points']]:
        raise ValueError('change_points: locale intent sequence must match')
    if en['door']['kind'] != zh['door']['kind']:
        raise ValueError('door: locale kind must match')
    if en['door']['kind'] == 'one-way' and (en['check']['about'] != zh['check']['about'] or len(en['check']['options']) != len(zh['check']['options'])):
        raise ValueError('check: locale about and option counts must match')


def _scene(details):
    if not any('scene' in details[lang] for lang in LOCALES):
        return
    if not all('scene' in details[lang] for lang in LOCALES):
        raise ValueError('scene: required in both locales')
    structures = []
    for lang in LOCALES:
        scene = details[lang]['scene']
        prefix = lang + '.scene.'
        def fail(field, reason):
            raise ValueError(prefix + field + ': ' + reason)
        def obj(value, required, optional, field):
            if not isinstance(value, dict) or not required <= set(value) or set(value) - required - optional:
                fail(field, 'invalid fields')
        def items(field, low, high):
            value = scene.get(field)
            if not isinstance(value, list) or not low <= len(value) <= high:
                fail(field, 'expected %s-%s items' % (low, high))
            return value
        def prose(value, field, is_label=False):
            _text(value, prefix + field)
            if not is_label and len(split(value)) != 1:
                fail(field, 'expected one fact sentence')
            result = label(value) if is_label else check(value, 'fact')
            if any(i['severity'] == 'fail' for i in result['issues']):
                fail(field, 'fails STE')
        obj(scene, {'lanes', 'nodes', 'edges', 'tokens', 'changes'}, {'counter'}, 'scene')
        lanes = items('lanes', 1, 6)
        nodes = items('nodes', 1, 24)
        edges = items('edges', 0, 40)
        changes = items('changes', 1, 9)
        for lane in lanes:
            obj(lane, {'label'}, set(), 'lanes')
            prose(lane['label'], 'lanes.label', True)
        change_ids = set()
        for i, change in enumerate(changes):
            obj(change, {'id', 'text', 'intents'}, set(), 'changes')
            if change['id'] != 'c' + str(i + 1):
                fail('changes.id', 'expected c1..cN in order')
            change_ids.add(change['id'])
            intents = change['intents']
            if not isinstance(intents, list) or not intents or any(not _integer(n, 1, len(details[lang]['intent'])) for n in intents) or len(set(intents)) != len(intents):
                fail('changes.intents', 'invalid intent indexes')
            prose(change['text'], 'changes.text')
        ids = set()
        for field, values in (('nodes', nodes), ('edges', edges)):
            for value in values:
                required = {'id', 'label', 'lane', 'kind', 'state'} if field == 'nodes' else {'id', 'from', 'to', 'state'}
                obj(value, required, {'change'} if field == 'nodes' else {'change', 'label'}, field)
                identifier = value['id']
                if not isinstance(identifier, str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,23}', identifier) or identifier in ids:
                    fail(field + '.id', 'invalid or duplicate id')
                ids.add(identifier)
                if value['state'] not in ('same', 'gone', 'new'):
                    fail(field + '.state', 'invalid state')
                if value['state'] == 'same':
                    if 'change' in value: fail(field + '.change', 'forbidden on same')
                elif not isinstance(value.get('change'), str) or value['change'] not in change_ids:
                    fail(field + '.change', 'required change id')
                if 'label' in value: prose(value['label'], field + '.label', True)
                if field == 'nodes':
                    if not _integer(value['lane'], 0, len(lanes) - 1): fail('nodes.lane', 'out of range')
                    if value['kind'] not in ('input', 'step', 'decision', 'store', 'focal', 'oneway'): fail('nodes.kind', 'invalid kind')
        by_node = {n['id']: n for n in nodes}
        by_edge = {e['id']: e for e in edges}
        for edge in edges:
            for endpoint in ('from', 'to'):
                # Type before membership: an unhashable reference is a field error.
                if not isinstance(edge[endpoint], str) or edge[endpoint] not in by_node: fail('edges.' + endpoint, 'unknown node')
            states = {by_node[edge[k]]['state'] for k in ('from', 'to')}
            if {'gone', 'new'} <= states: fail('edges.state', 'cannot join gone and new nodes')
            for state in ('gone', 'new'):
                if state in states and edge['state'] != state: fail('edges.state', 'edge touching ' + state + ' node must be ' + state)
        obj(scene['tokens'], {'before', 'after'}, set(), 'tokens')
        for phase, allowed in (('before', ('same', 'gone')), ('after', ('same', 'new'))):
            path = scene['tokens'][phase]
            if not isinstance(path, list) or not 1 <= len(path) <= 24: fail('tokens.' + phase, 'expected 1-24 edge ids')
            previous = None
            for identifier in path:
                if not isinstance(identifier, str) or identifier not in by_edge: fail('tokens.' + phase, 'unknown edge id')
                edge = by_edge[identifier]
                if edge['state'] not in allowed: fail('tokens.' + phase, 'invalid edge state')
                if previous is not None and previous != edge['from']: fail('tokens.' + phase, 'discontinuous path')
                previous = edge['to']
        if 'counter' in scene:
            obj(scene['counter'], {'label', 'before', 'after'}, set(), 'counter')
            prose(scene['counter']['label'], 'counter.label', True)
            for phase in ('before', 'after'): _text(scene['counter'][phase], prefix + 'counter.' + phase, 12)
        def structural(value):
            if isinstance(value, dict): return {k: structural(v) for k, v in value.items() if k not in ('label', 'text')}
            if isinstance(value, list): return [structural(v) for v in value]
            return value
        structures.append(structural(scene))
    if structures[0] != structures[1]:
        raise ValueError('scene: locale structure must match (ids, lanes, states, tokens, counter and intents)')


def _items(details):
    """A retrospective card's items: 1 to 60, unique ids, the same ids,
    projects and effects at the same position in both locales."""
    for lang in LOCALES:
        if not isinstance(details.get(lang), dict) or 'items' not in details[lang]:
            raise ValueError('items: required in both locales or neither')
        items = details[lang]['items']
        field = lang + '.items'
        if not isinstance(items, list) or not 1 <= len(items) <= 60:
            raise ValueError(field + ': expected 1-60 items')
        for item in items:
            if not isinstance(item, dict) or not set(item) <= ITEM_KEYS:
                raise ValueError(field + ': expected item objects with known fields')
            if not isinstance(item.get('id'), str) or not re.fullmatch(ITEM_ID, item['id']):
                raise ValueError(field + '.id: expected <label>/R<n>')
            if item.get('project') != item['id'].split('/')[0]:
                raise ValueError(field + '.project: expected the label of the id')
            for key in ('title', 'why', 'how'):
                _text(item.get(key), field + '.' + key)
            if item.get('effect') not in ('removes', 'net-removal', 'adds'):
                raise ValueError(field + '.effect: expected removes, net-removal or adds')
            for key, low, high, maximum in (('evidence', 1, 10, 2000), ('scope', 0, 20, 200),
                                            ('removes', 0 if item['effect'] == 'adds' else 1, 20, 2000)):
                values = item.get(key)
                if not isinstance(values, list) or not low <= len(values) <= high:
                    raise ValueError(field + '.' + key + ': expected {}-{} entries'.format(low, high))
                for value in values:
                    _text(value, field + '.' + key, maximum)
            if (item['effect'] == 'adds') != ('why_not_removal' in item):
                raise ValueError(field + '.why_not_removal: required on an adds item and only there')
            if 'why_not_removal' in item:
                _text(item['why_not_removal'], field + '.why_not_removal')
        ids = [item['id'] for item in items]
        if len(set(ids)) != len(ids):
            raise ValueError(field + ': duplicate item id')
    en, zh = details['en']['items'], details['zh-TW']['items']
    if [(i['id'], i['project'], i['effect'], i['removes']) for i in en] != [(i['id'], i['project'], i['effect'], i['removes']) for i in zh]:
        raise ValueError('items: locale ids, projects, effects and removals must match position by position')


def _validate(details):
    if not isinstance(details, dict):
        raise ValueError('details must be an object')
    if not any(isinstance(details.get(lang), dict) and any(k in details[lang] for k in INTENT_TRIGGERS) for lang in LOCALES):
        return False
    if any(isinstance(details.get(lang), dict) and 'items' in details[lang] for lang in LOCALES):
        _items(details)
        intent = [k for k in INTENT_TRIGGERS if k not in ITEM_FIELDS + ('notes',)]
        if not any(isinstance(details.get(lang), dict) and any(k in details[lang] for k in intent) for lang in LOCALES):
            _notes(details)
            return True
    for lang in LOCALES:
        if not isinstance(details.get(lang), dict) or 'intent' not in details[lang]:
            raise ValueError('intent is required in both locales')
    _walk(details)
    _scene(details)
    _intent_fields(details)
    return True


def _notes(details):
    if ('notes' in details['en']) != ('notes' in details['zh-TW']):
        raise ValueError('notes: required in both locales or neither')
    for lang in LOCALES:
        for item in details[lang].get('notes', []) if isinstance(details[lang].get('notes', []), list) else [None]:
            if not isinstance(item, dict) or item.get('kind') not in ('note', 'caution'):
                raise ValueError(lang + '.notes: expected note or caution items')
            _text(item.get('text'), lang + '.notes.text')


def _intent_fields(details):
    for key in CARD_LISTS:
        if (key in details['en']) != (key in details['zh-TW']):
            raise ValueError(key + ': required in both locales or neither')
        if key not in details['en']:
            if key == 'done':
                raise ValueError('en.done: required on an intent card')
            continue
        for lang in LOCALES:
            values = details[lang][key]
            field = lang + '.' + key
            maximum = 6 if key == 'questions' else 8 if key in ('before_nodes', 'after_nodes', 'change_table') else 12
            if not isinstance(values, list):
                raise ValueError(field + ': expected array')
            if key not in ('scope_in', 'scope_out') and not 1 <= len(values) <= maximum:
                raise ValueError(field + ': expected 1-{} items'.format(maximum))
            for item in values:
                if key in ('scope_in', 'scope_out'):
                    _text(item, field, 200)
                    continue
                if not isinstance(item, dict):
                    raise ValueError(field + ': expected object items')
                if key in ('before_nodes', 'after_nodes'):
                    allowed = ('same', 'gone') if key == 'before_nodes' else ('same', 'new')
                    if item.get('state') not in allowed:
                        raise ValueError(field + ': invalid node state')
                    _text(item.get('label'), field + '.label')
                else:
                    _text(item.get('text'), field + '.text')
                    if key == 'change_table':
                        if any(item.get(k) not in ('✓', '—', '?') for k in 'ABC'):
                            raise ValueError(field + ': invalid option mark')
                    elif item.get('kind') not in (('note', 'caution') if key == 'notes' else ('step', 'fact')):
                        raise ValueError(field + ': invalid kind')
        if key in ('questions', 'before_nodes', 'after_nodes', 'change_table') and len(details['en'][key]) != len(details['zh-TW'][key]):
            raise ValueError(key + ': locale counts must match')


def check_explain(explain):
    """Validate a spec explanation without requiring decision-only fields."""
    if not isinstance(explain, dict):
        raise ValueError('explain must be an object')
    for lang in LOCALES:
        loc = explain.get(lang)
        if not isinstance(loc, dict):
            raise ValueError(lang + ': required in explain')
        for field in ('intent', 'done', 'before_nodes', 'after_nodes'):
            if field not in loc:
                raise ValueError(lang + '.' + field + ': required in explain')
        if any(field not in NEW_FIELDS or field in ('questions', 'change_table') + ITEM_FIELDS for field in loc):
            raise ValueError(lang + ': unknown explain field')
    _validate(explain)
    _alignment(explain)
    return _report(explain, explain=True)


def _alignment(details):
    for lang in LOCALES:
        loc = details[lang]
        for number in range(1, len(loc['intent']) + 1):
            name = ('Intent ' if lang == 'en' else '意圖 ') + str(number)
            prefixes = (name + ':',) if lang == 'en' else (name + '：', name + ':')
            if not any(item['text'].startswith(prefixes) for item in loc['done']):
                raise ValueError(lang + '.done: no alignment item for ' + name)


def _intent(details):
    return any('intent' in details.get(lang, {}) for lang in LOCALES)


def check_details(details, kind=None):
    if not _validate(details):
        return {'intent_card': False}
    if not _intent(details):
        return _report(details, intent=False)
    for lang in LOCALES:
        loc = details[lang]
        if kind in ('merge', 'merge-untracked'):
            for field in LEGACY_FIELDS:
                if field != 'notes' and field not in loc:
                    raise ValueError(lang + '.' + field + ': required on a merge intent card')
            prefix = 'MERGE CARD — ' if lang == 'en' else '【合併卡】'
            _text(loc.get('title'), lang + '.title')
            if not loc['title'].startswith(prefix):
                raise ValueError(lang + '.title: a merge card title starts with "' + prefix + '"')
    _alignment(details)
    return _report(details)


def _report(details, explain=False, intent=True):
    report = dict(ok=True, locales={}, labels={})
    report['explain' if explain else 'intent_card'] = intent
    if any('items' in details.get(lang, {}) for lang in LOCALES):
        report['items'] = True
    for lang in LOCALES:
        loc = details[lang]
        report['locales'][lang] = []
        report['labels'][lang] = []

        def add(field, text, kind=None, index=None, sentences=True, node=False):
            _text(text, lang + '.' + field)
            for sentence in split(text) if sentences else [text]:
                result = label(sentence) if node else check(sentence, kind)
                result.pop('lang')
                entry = dict(field=field, index=index, sentence=sentence, **result)
                report['labels' if node else 'locales'][lang].append(entry)
                if any(i['severity'] == 'fail' for i in result['issues']):
                    report['ok'] = False

        if not explain:
            add('title', loc.get('title'), 'fact', sentences=False)
            for field in ('explanation', 'before', 'after', 'outcome'):
                add(field, loc.get(field))
            options = loc.get('options')
            if not isinstance(options, dict):
                raise ValueError(lang + '.options: expected object')
            for key, option in options.items():
                if not isinstance(option, dict):
                    raise ValueError(lang + '.options.' + key + ': expected object')
                for field in ('description', 'pros', 'cons'):
                    add('options.' + key + '.' + field, option.get(field),
                        None if field == 'description' else 'fact', sentences=field != 'description')
        for field in ('intent', 'why', 'how', 'done', 'questions', 'notes'):
            for index, item in enumerate(loc.get(field, [])):
                add(field, item['text'], 'fact' if field == 'notes' else item['kind'], index)
        for index, point in enumerate(loc.get('change_points', [])):
            add('change_points.how', point['how'], 'fact', index)
        for field in ('reason', 'rollback'):
            if 'door' in loc:
                add('door.' + field, loc['door'][field], 'fact')
        if 'check' in loc:
            for field in ('q', 'why'):
                add('check.' + field, loc['check'][field], 'fact')
            for index, option in enumerate(loc['check']['options']):
                add('check.options', option, 'fact', index)
        for field in ('before_nodes', 'after_nodes'):
            for index, item in enumerate(loc.get(field, [])):
                add(field, item['label'], index=index, sentences=False, node=True)
        for index, item in enumerate(loc.get('items', [])):
            add('items.title', item['title'], 'fact', index, sentences=False)
            for field in ('why', 'how', 'why_not_removal'):
                if field in item:
                    add('items.' + field, item[field], 'fact', index)
    return report


def check_plain(details, root=None):
    """Change 8 of T-270: why, how and glossary on every card, plus the
    mechanical plain-writing checks and STE for every why and how item.

    Shape problems raise ValueError; findings and STE failures are reported.
    """
    import fm_plain
    glossary = fm_plain.load_glossary(root)
    if not isinstance(details, dict):
        raise ValueError('details must be an object')
    problems = fm_plain.check_card(details, glossary)
    shape = [p for p in problems if not re.search(r' (glued-number|slash-chain|unexplained-term) "', p)]
    if shape:
        raise ValueError('; '.join(shape))
    report = dict(plain=True, ok=not problems, problems=problems, locales={})
    for lang in LOCALES:
        report['locales'][lang] = []
        for field in ('why', 'how'):
            for index, item in enumerate(details[lang][field]):
                for sentence in split(item['text']):
                    result = check(sentence, item['kind'])
                    result.pop('lang')
                    report['locales'][lang].append(dict(field=field, index=index, sentence=sentence, **result))
                    if any(i['severity'] == 'fail' for i in result['issues']):
                        report['ok'] = False
    return report


def main(argv):
    if argv == ['rules']:
        print(json.dumps(rules(), ensure_ascii=False))
        return 0
    if len(argv) == 2 and argv[0] == 'check-plain':
        try:
            with open(argv[1], encoding='utf-8') as stream:
                report = check_plain(json.load(stream))
        except (ValueError, OSError) as error:
            print('fm_ste: ' + str(error), file=sys.stderr)
            return 64
        print(json.dumps(report, ensure_ascii=False))
        if report['ok']:
            return 0
        for problem in report['problems']:
            print(problem, file=sys.stderr)
        for lang, entries in report['locales'].items():
            for entry in entries:
                for issue in entry['issues']:
                    if issue['severity'] == 'fail':
                        print('{} {}: {} -> {} {}'.format(lang, entry['field'], entry['sentence'], issue['rule'], issue['detail']), file=sys.stderr)
        return 65
    kind = None
    if len(argv) == 4 and argv[:2] == ['check-details', '--kind'] and not argv[2].startswith('--'):
        kind = argv[2]
        filename = argv[3]
    elif len(argv) == 2 and argv[0] in ('check-details', 'check-explain') and argv[1] != '--kind':
        filename = argv[1]
    else:
        print('usage: fm_ste.py rules | check-details [--kind <kind>] <file> | check-explain <spec.json> | check-plain <file>', file=sys.stderr)
        return 64
    try:
        with open(filename, encoding='utf-8') as stream:
            data = json.load(stream)
            if argv[0] == 'check-explain':
                if not isinstance(data, dict):
                    raise ValueError('spec must be an object')
                report = check_explain(data['explain']) if 'explain' in data else {'explain': False}
            else:
                report = check_details(data, kind)
    except (ValueError, OSError) as error:
        print('fm_ste: ' + str(error), file=sys.stderr)
        return 64
    print(json.dumps(report, ensure_ascii=False))
    if report.get('ok', True):
        return 0
    for section in ('locales', 'labels'):
        for lang, entries in report[section].items():
            for entry in entries:
                for issue in entry['issues']:
                    if issue['severity'] == 'fail':
                        print('{} {}: {} -> {} {}'.format(lang, entry['field'], entry['sentence'], issue['rule'], issue['detail']), file=sys.stderr)
    return 65


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
