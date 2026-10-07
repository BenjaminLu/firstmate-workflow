"""T-243 fixture and HTTP assertions; no process ownership outside the shell fixture."""
from contextlib import contextmanager
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request

mode, root, beta = sys.argv[1:4]
root, beta = Path(root), Path(beta)
log = root / 'state/events.jsonl'

def stamp(i):
    return (dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=i)).isoformat()

def event(i, project='alpha'):
    return dict(type='progress', actor='captain', project=project, ts=stamp(i),
                summary={'en': f'line {i}', 'zh-TW': f'事件 {i}'}, data={'n': i})

def write_events(path, events):
    path.write_text('invalid line\n' + ''.join(json.dumps(e) + '\n' for e in events))

if mode == 'seed':
    decisions = []
    for i in range(120):
        # File order is deliberately unrelated to timestamp order.
        rank = (i * 37) % 120
        decisions.append(dict(id=f'D-{i+1}', ts=stamp(rank), chosen='A', project='alpha',
                              identity=f'answer:{i}', merge_reason='settled record ' + 'x' * 300))
    decisions += [dict(id='D-121', ts=stamp(-10), chosen='A', project='alpha', merge='running'),
                  dict(id='D-122', ts=stamp(-9), chosen='A', project='alpha', merge='failed', task='T-REFUSED'),
                  dict(id='D-123', ts=stamp(-8), chosen='A', project='alpha', effect='park', effect_outcome='failed', task='T-EFFECT')]
    # Latest settled answer clears mergeRunning; old refusal must survive supersession.
    decisions[max(range(120), key=lambda i: decisions[i]['ts'])]['merge'] = 'merged'
    for d in decisions:
        (root / 'state/decisions' / (d['id'] + '.json')).write_text(json.dumps(d))
    events = []
    for i in range(50000):
        e = event(i)
        if i < 1000:
            e.update(type='approved')  # plus 1000 decision events = 2000 handoffs
        elif i < 2000:
            e.update(type='decision_made', data={'decision': f'D-event-{i}', 'chosen': 'A'})
        elif i < 2220:
            e.update(type='merged', pr=i, task='T-REFUSED' if i == 2000 else f'T-{i}')
        events.append(e)
    events[2220]['summary']['en'] = 'old only #98765'
    write_events(log, events)
    write_events(beta / 'events.jsonl', [event(i, 'beta') for i in range(503)])
    sys.exit(0)

# Each claim writes its own result so shell assertions remain separately visible
# to CI and gate 4. A failed claim prints its source traceback and does not skip
# independent claims later in the fixture.
results = root / 'paging-results'
results.mkdir(exist_ok=True)

@contextmanager
def claim(name):
    try:
        yield
    except Exception:
        (results / name).write_text('FAIL\n' + traceback.format_exc())
        print(f'Paging claim failed: {name}', file=sys.stderr)
        traceback.print_exc()
    else:
        (results / name).write_text('PASS')

base = 'http://127.0.0.1:' + sys.argv[4]
def get(path, status=200):
    try:
        response = urllib.request.urlopen(base + path, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    assert response.code == status, (path, response.code, response.read())
    return json.load(response)

def page(before=None, limit=200, project='alpha'):
    query = dict(project=project, limit=limit)
    if before is not None:
        query['before'] = before
    return get('/api/events?' + urllib.parse.urlencode(query))

s = get('/api/state?project=alpha')
with claim('windows_totals'):
    assert (s.get('windows') or {}).get('responses') == {'shown': 53, 'total': 123}, s.get('windows')
    assert s['windows']['outcomes'] == {'shown': 420, 'total': 1340}, s['windows']
source = [json.loads(p.read_text()) for p in (root / 'state/decisions').glob('*.json')]
settled = sorted([d for d in source if int(d['id'][2:]) <= 120], key=lambda d: (dt.datetime.fromisoformat(d['ts']), d['id']))
expected = {d['id'] for d in settled[-50:]} | {'D-121', 'D-122', 'D-123'}
with claim('unsettled_responses'):
    assert {'D-121', 'D-122', 'D-123'} <= {d['id'] for d in s['responses']}
with claim('newest_50_responses'):
    assert {d['id'] for d in s['responses']} == expected
    assert [d['id'] for d in s['responses']] == [d['id'] for d in sorted(s['responses'], key=lambda d: (dt.datetime.fromisoformat(d['ts']), d['id']))]
with claim('superseded_refusal'):
    assert next(d for d in s['responses'] if d['id'] == 'D-122')['superseded'] is True
with claim('just_merged_response'):
    assert settled[-1]['id'] in expected and next(d for d in s['responses'] if d['id'] == settled[-1]['id'])['merge'] == 'merged'
with claim('complete_handoffs'):
    assert len(s['handoffs']) == 2000
    assert all('cursor' not in h['identity'] for h in s['handoffs'])
with claim('complete_merged_outcomes'):
    assert len([o for o in s['outcomes'] if o['type'] == 'merged']) == 220
with claim('newest_200_outcomes'):
    assert [o['data']['decision'] for o in s['outcomes'] if o['type'] == 'decision_made'] == [f'D-event-{i}' for i in range(1800, 2000)]
with claim('unchanged_counts'):
    assert s['counts']['merged'] == 220
raw_events = [json.loads(line) for line in log.read_text().splitlines()[1:]]
# Reconstruct the full public projections from the fixture files, rather than
# inflating the denominator with stored-only decision fields.
full_responses = [dict(d, merge=d.get('merge')) for d in source]
for d in full_responses:
    if d['merge'] == 'running':
        d['merge_unknown'] = True
    if d['merge'] == 'failed':
        d['superseded'] = True
    if d.get('effect_outcome') == 'failed':
        d['effect_superseded'] = False
full_outcomes = []
for e in raw_events:
    if e['type'] == 'merged':
        full_outcomes.append(dict(e, identity=f"merge:{e['pr']}", pr_url=f"https://github.com/example/alpha/pull/{e['pr']}"))
    elif e['type'] == 'decision_made':
        full_outcomes.append(dict(e, identity='decision:' + e['data']['decision'], chosen=e['data']['chosen']))
full_outcomes += [dict(type='decision_made', identity=d['identity'], ts=d['ts'], project=d['project'],
                      chosen=d['chosen'], data={'decision':d['id'], 'chosen':d['chosen']})
                  for d in source if d.get('identity')]
with claim('responses_half_size'):
    assert len(json.dumps(s['responses'])) <= len(json.dumps(full_responses)) / 2
with claim('outcomes_half_size'):
    assert len(json.dumps(s['outcomes'])) <= len(json.dumps(full_outcomes)) / 2
with claim('first_page_equals_recent'):
    assert get('/api/events?project=alpha')['events'] == s['recent']
    assert get('/api/events')['events'] == get('/api/state')['recent']
with claim('limit_clamped'):
    assert len(page(limit=0)['events']) == 1
    assert len(page(limit=999)['events']) == 200
with claim('recent_cursors'):
    assert [e['cursor'] for e in get('/api/events?project=alpha')['events']] == [e['cursor'] for e in s['recent']]
    assert page(limit=1)['next'] == s['recent'][0]['cursor']
    store = hashlib.sha256(str(log.parent.resolve()).encode()).hexdigest()[:12]
    last = log.read_text().splitlines()[-1]
    assert s['recent'][0]['cursor'] == f'{store}:49999:' + hashlib.sha256(last.encode()).hexdigest()[:12]
seen, cursors, before = [], [], None
older_link = None
with claim('pages_exactly_once'):
    while True:
        result = page(before)
        cursors.extend(e['cursor'] for e in result['events'])
        older_link = (result['pr_urls_by_project'].get('alpha') or {}).get('98765') or older_link
        seen.extend(e['data']['n'] for e in result['events'] if 'n' in e['data'])
        if result['next'] is None:
            break
        before = result['next']
    # The 1000 decision entries use decision data instead of n.
    assert seen == [i for i in reversed(range(50000)) if not 1000 <= i < 2000]
    assert len(cursors) == len(set(cursors)) == 50000
    assert [int(c.split(':')[1]) for c in cursors] == list(reversed(range(50000)))
with claim('older_only_pr_link'):
    assert '98765' not in s['pr_urls_by_project']['alpha']
    assert older_link == 'https://github.com/example/alpha/pull/98765'
with claim('external_append_paging'):
    seen, before = [], None
    while True:
        result = page(before, 71, 'beta')
        seen.extend(e['data']['n'] for e in result['events'])
        if result['next'] is None:
            break
        before = result['next']
        with log.open('a') as f:
            f.write(json.dumps(event(60000 + len(seen))) + '\n')
        with (beta / 'events.jsonl').open('a') as f:
            f.write(json.dumps(event(60000 + len(seen), 'beta')) + '\n')
    assert seen == list(reversed(range(503))), seen
with claim('bad_cursor_400'):
    assert get('/api/events?before=broken', 400)['code'] == 'badCursor'
    assert get('/api/events?before=000000000000:0:000000000000', 400)['code'] == 'badCursor'
with claim('stale_cursor_409'):
    stale = s['recent'][0]['cursor']
    lines = log.read_text().splitlines()
    lines[50000] = json.dumps(event(77777))
    log.write_text('\n'.join(lines) + '\n')
    assert get('/api/events?before=' + stale, 409)['code'] == 'staleCursor'
# A separate project exercises Date.parse offsets, null/invalid/missing dates, plain
# string ties at the window boundary, and response-derived outcome timestamps.
def order(record, key):
    try:
        time = dt.datetime.fromisoformat(str(record.get('ts') or '').replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError):
        time = float('-inf')
    return time, record[key]

beta_answers = []
for i in range(65):
    d = dict(id=f'D-beta-T001-{i+1}', identity=f'beta-answer:{i}', project='beta', chosen='A', ts=stamp(1000))
    if i == 0:
        d.pop('ts')
    elif i == 1:
        d['ts'] = 'not-a-date'
    elif i == 2:
        # Lexically smaller, chronologically later than the other timestamps.
        d['ts'] = '2025-12-31T23:59:00-02:00'
    elif i == 3:
        d['ts'] = None
    beta_answers.append(d)
    (beta / 'decisions' / (d['id'] + '.json')).write_text(json.dumps(d))
# 250 event outcomes with equal instants expressed using different offsets.
beta_outcomes = []
for i in range(250):
    e = event(i, 'beta')
    e.update(type='decision_made', ts='2026-01-01T00:16:40Z' if i % 2 else '2026-01-01T01:16:40+01:00',
             data={'decision': f'D-tie-{i}'})
    if i == 0:
        e.pop('ts')
    elif i == 1:
        e['ts'] = 'invalid'
    elif i == 2:
        e['ts'] = None
    beta_outcomes.append(e)
write_events(beta / 'events.jsonl', beta_outcomes)
bs = get('/api/state?project=beta')
expected_responses = sorted(beta_answers, key=lambda d: order(d, 'id'))[-50:]
with claim('response_timestamp_order'):
    assert [d['id'] for d in bs['responses']] == [d['id'] for d in expected_responses]
full = [dict(e, identity='decision:' + e['data']['decision']) for e in beta_outcomes]
full += [dict(type='decision_made', identity=d['identity'], ts=d.get('ts')) for d in beta_answers]
keep = {e['identity'] for e in sorted(full, key=lambda e: order(e, 'identity'))[-200:]}
with claim('outcome_timestamp_order'):
    assert [e['identity'] for e in bs['outcomes']] == [e['identity'] for e in full if e['identity'] in keep]
with claim('beta_windows_totals'):
    assert bs['windows'] == {'responses': {'shown': 50, 'total': 65}, 'outcomes': {'shown': 200, 'total': 315}}
with claim('response_outcome_timestamp'):
    assert next(e for e in bs['outcomes'] if e['identity'] == 'beta-answer:2')['ts'] == beta_answers[2]['ts']
# Windows apply after filtering, so the default project cannot displace beta.
with claim('project_filter_before_windows'):
    assert get('/api/state?project=alpha')['windows']['responses']['total'] == 123
# Lost-run folding and evidence decoration must agree between both read paths.
with (beta / 'events.jsonl').open('a') as f:
    for e in [dict(type='agent_lost', actor='worker-lost', project='beta'),
              dict(type='agent_finished', actor='worker-lost', project='beta', data={'status':'process_gone'}),
              dict(type='progress', actor='captain', project='beta', data={'evidence_event':'brief_gap'})]:
        f.write(json.dumps(e) + '\n')
bs = get('/api/state?project=beta')
with claim('folded_page_parity'):
    assert get('/api/events?project=beta')['events'] == bs['recent']
with claim('evidence_warning'):
    assert bs['recent'][0]['evidence_warning'] is True
with claim('lost_run_folded'):
    assert bs['recent'][1]['type'] == 'agent_lost'
# The shell reports every claim, including missing results after setup errors.
