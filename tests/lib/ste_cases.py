"""STE fixtures and observations; assertions belong to tests/lib.sh."""
import importlib.util
import json
from pathlib import Path
import sys


def card():
    result = {}
    for lang, text in [('en', 'The check passes.'), ('zh-TW', '檢查通過。')]:
        result[lang] = {key: text for key in ('title', 'explanation', 'before', 'after', 'outcome')}
        result[lang]['options'] = {key: dict(description=text, pros=text, cons=text) for key in 'ABC'}
        for key in ('intent', 'why', 'done', 'questions'):
            result[lang][key] = [dict(kind='fact', text=text)]
        result[lang].update(scope_in=['checker'], scope_out=[], notes=[dict(kind='caution', text=text)],
                            before_nodes=[dict(state='gone', label=text)],
                            after_nodes=[dict(state='new', label=text)],
                            change_table=[dict(text=text, A='✓', B='—', C='?')])
    return result


def fixture(mode):
    d = card()
    if mode == 'legacy':
        for loc in d.values():
            for key in list(loc):
                if key not in ('title', 'explanation', 'before', 'after', 'outcome', 'options'):
                    del loc[key]
    elif mode == 'fail':
        d['en']['intent'][0] = dict(kind='step', text='Ensure the check passes.')
    elif mode == 'missing':
        del d['en']['intent']
    elif mode == 'counts':
        d['en']['questions'] *= 2
    elif mode == 'state':
        d['en']['before_nodes'][0]['state'] = 'new'
    elif mode == 'control':
        d['en']['scope_in'] = ['bad\x7f']
    elif mode == 'surrogate':
        d['en']['notes'][0]['text'] = '\ud800'
    elif mode == 'pair':
        del d['zh-TW']['why']
    return d


def observations(module):
    def emit(name, value):
        print('{}\t{}'.format('true' if value else 'false', name))
    cases = [
        ('R1', 'step', 'Run ' + 'word ' * 20, 'Run the check.', 'fail'),
        ('R2', 'fact', 'word ' * 26, 'The check passes.', 'fail'),
        ('R3', 'step', 'Run the check and then merge it.', 'Run the check.', 'fail'),
        ('R4', 'step', 'Check that it is written.', 'Check the file.', 'fail'),
        ('R4', 'fact', 'It is written.', 'It exists.', 'warn'),
        ('R5', 'fact', 'It will pass.', 'It passes.', 'fail'),
        ('R6', 'step', 'Ensure it passes prior\tto use.', 'Make sure it passes before use.', 'fail'),
        ('R7', 'fact', 'Testing takes time.', 'Timing takes time.', 'warn'),
        ('R8', 'fact', "It's appropriate.", 'It fits.', 'fail'),
        ('R9', 'step', 'Run it. Note: keep a copy.', 'Run it.', 'fail'),
        ('Z1', 'step', '字' * 26, '執行檢查。', 'fail'),
        ('Z1', 'fact', '字' * 31, '檢查通過。', 'fail'),
        ('Z2', 'step', '檢查然後合併。', '檢查。', 'fail'),
        ('Z3', 'fact', '檔案被移除。', '檔案消失。', 'fail'),
        ('Z4', 'fact', '檢查將會通過。', '檢查通過。', 'fail'),
        ('Z5', 'fact', '大概十分鐘左右。', '十分鐘。', 'fail'),
        ('Z6', 'step', '併入檔案。', '合併檔案。', 'fail'),
        ('Z7', 'step', '檢查。注意：檔案。', '檢查檔案。', 'fail'),
    ]
    for rule, kind, bad, good, severity in cases:
        emit(rule + ' detects ' + kind + ' ' + severity,
             any(i['rule'] == rule and i['severity'] == severity for i in module.check(bad, kind)['issues']))
        emit(rule + ' accepts clean ' + kind, not any(i['rule'] == rule for i in module.check(good, kind)['issues']))
    samples = [
        ('Move the coverage program into bin/lib/fm_ci_checks.py.', 'step'),
        ('Keep each message and each exit code the same.', 'step'),
        ('The coverage check in T-196 is correct.', 'fact'),
        ('The sandbox stops the save, and cursor waits 30 to 40 seconds.', 'fact'),
        ('把覆蓋率程式搬到 bin/lib/fm_ci_checks.py。', 'fact'),
        ('保留每一則訊息和每一個退出碼。', 'step'),
        ('T-196 的覆蓋率檢查是對的。', 'fact'),
        ('沙盒擋下這次寫入，cursor 卡住 30 到 40 秒。', 'fact')]
    for text, kind in samples:
        r = module.check(text)
        emit('real sample: ' + text, r['kind'] == kind and not any(i['severity'] == 'fail' for i in r['issues']))
    for text, expected in [
        ('Ensure the reviewer is notified, and then merge the PR after CI passes, etc.', {'R6', 'R4', 'R3', 'R8'}),
        ('請確認 reviewer 被通知，然後在 CI 通過後併入 PR，大概十分鐘左右。', {'Z2', 'Z3', 'Z5', 'Z6'})]:
        emit('real refusal: ' + text, expected <= {i['rule'] for i in module.check(text, 'step')['issues']})
    for text, n in [('Use `ensure will and then run`.', 2), ('檢查 `被將併入 大概`。', 3)]:
        r = module.check(text)
        emit('backticks: ' + text, r['n'] == n and not r['issues'])
    for text, expected in [('One. Two! Three?', ['One.', 'Two!', 'Three?']),
                           ('一。二！三？', ['一。', '二！', '三？']),
                           ('One. 二。Three!', ['One.', '二。', 'Three!']), ('  ', [])]:
        emit('split ' + text, module.split(text) == expected)
    for text, limit, rule in [('word ' * 7, 6, 'R2'), ('字' * 15, 14, 'Z1')]:
        r = module.label(text)
        emit('label overflow ' + rule, r['max'] == limit and any(i['rule'] == rule for i in r['issues']))
        emit('label boundary ' + rule, not module.label('word ' * 6 if rule == 'R2' else '字' * 14)['issues'])
    emit('label vocabulary', any(i['rule'] == 'R6' for i in module.label('utilize')['issues']))
    d = card()
    d['en']['outcome'] = 'It is written. Testing takes time.'
    emit('warnings do not refuse cards', module.check_details(d)['ok'])
    for field in ('title', 'explanation', 'before', 'after', 'outcome'):
        d = card(); d['en'][field] = 'It will pass.'
        emit('checks ' + field, not module.check_details(d)['ok'])
    for field in ('description', 'pros', 'cons'):
        d = card(); d['en']['options']['B'][field] = 'It will pass.'
        emit('checks option ' + field, not module.check_details(d)['ok'])
    for field in ('intent', 'why', 'done', 'questions', 'notes'):
        d = card(); d['en'][field][0]['text'] = 'It passes. It will pass.'
        r = module.check_details(d)
        emit('checks split ' + field, not r['ok'] and any(e['field'] == field and e['sentence'] == 'It will pass.' for e in r['locales']['en']))
    for field in ('before_nodes', 'after_nodes'):
        d = card(); d['en'][field][0]['label'] = 'word ' * 7
        emit('checks ' + field, not module.check_details(d)['ok'])

    emit('single imperative auto detection', module.check('Run.')['kind'] == 'step')
    # Schema failures must not depend on prose failures.
    def malformed(name, d):
        try:
            module.check_details(d)
        except ValueError:
            emit(name, True)
        else:
            emit(name, False)

    for field in ('intent', 'why', 'done', 'notes', 'questions', 'before_nodes', 'after_nodes', 'change_table'):
        for value in (None, {}, [], [None]):
            d = card(); d['en'][field] = value
            malformed('reject malformed ' + field + ' ' + repr(value), d)
        d = card(); d['en'][field] *= 13
        malformed('reject too many ' + field, d)
    for field in ('scope_in', 'scope_out'):
        for value in (None, {}, [None], ['x' * 201], ['bad\x01'], ['bad\x85'], ['\udfff']):
            d = card(); d['en'][field] = value
            malformed('reject malformed ' + field + ' ' + ascii(value), d)
    for field in ('before_nodes', 'after_nodes', 'change_table'):
        d = card(); d['en'][field] *= 2
        malformed('reject mismatched ' + field, d)
    for field in ('intent', 'why', 'done', 'notes', 'questions'):
        for key, value in [('kind', 'other'), ('text', 'x' * 2001), ('text', ''), ('text', '\x7f')]:
            d = card(); d['en'][field][0][key] = value
            malformed('reject invalid item ' + field + '.' + key, d)
    d = card(); d['en']['change_table'][0]['A'] = 'yes'
    malformed('reject invalid table mark', d)
    d = card(); d['en']['after_nodes'][0]['state'] = 'gone'
    malformed('reject gone after node', d)
    d = card(); d['en']['future_key'] = {'anything': True}
    emit('unknown locale keys survive', module.check_details(d)['ok'])


if __name__ == '__main__':
    if sys.argv[1] == 'fixture':
        print(json.dumps(fixture(sys.argv[2])))
    else:
        spec = importlib.util.spec_from_file_location('fm_ste', Path(__file__).resolve().parents[2] / 'bin/lib/fm_ste.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        observations(module)
