"""Data validation and transitions for the opt-in, self-only landing queue.

No network, subprocess, locks, process probes or writes are performed here.
The resident supervisor owns persistence and authoritative reads. The status
entry point deliberately reads only the canonical queue projection.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

VERSION = 1
POLICY_KEYS = {'version', 'strategy', 'enabled', 'repository', 'base', 'cohort',
               'captain_authorization', 'depth', 'batch'}
STATES = {'observed', 'queued', 'blocked', 'front', 'updating', 'waiting-ci',
          'waiting-review', 'verifying', 'waiting-captain', 'merging', 'landed',
          'parked', 'uncertain'}
COUNTERS = ('automatic_updates_requested', 'completed_landings', 'invalidated_gate_jobs',
            'captain_wait_seconds', 'front_seconds', 'duplicate_effects_observed')
SHA = re.compile(r'[0-9a-f]{40}')
DIGEST = re.compile(r'[0-9a-f]{64}')
DECISION = re.compile(r'D-[A-Za-z0-9_-]+-[1-9][0-9]*')


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def safe_path(path):
    path = Path(path)
    if not path.is_absolute() or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('symlinked or noncanonical queue input')
    return path


def read(path):
    return json.loads(safe_path(path).read_text(encoding='utf-8'))


def policy_digest(policy):
    content = {k: policy[k] for k in POLICY_KEYS - {'captain_authorization'}}
    content['cohort'] = sorted(content['cohort'])
    return hashlib.sha256(json.dumps(content, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def validate_policy(policy, repository, base):
    if not isinstance(policy, dict) or set(policy) != POLICY_KEYS:
        raise ValueError('queue policy requires exactly the version 1 fields')
    if any(type(policy[k]) is not int or policy[k] != 1 for k in ('version', 'depth', 'batch')):
        raise ValueError('queue policy supports only version/depth/batch 1')
    cohort = policy['cohort']
    if (type(policy['enabled']) is not bool or policy['strategy'] != 'self-front'
            or policy['repository'] != repository or policy['base'] != base
            or not isinstance(cohort, list) or not 2 <= len(cohort) <= 3
            or not all(integer(n, 1) for n in cohort) or len(set(cohort)) != len(cohort)
            or not isinstance(policy['captain_authorization'], str)
            or not DECISION.fullmatch(policy['captain_authorization'])):
        raise ValueError('queue policy identity, cohort or authorization is invalid')
    return dict(policy, cohort=sorted(cohort))


def effect(record, chosen):
    named = record.get('details', {}).get('effect', {}).get(chosen)
    if named is not None:
        return named
    if record.get('kind') in ('merge', 'merge-untracked'):
        return 'merge' if chosen == 'A' else 'hold'
    return None


def decision_authority(state, project, ident, note):
    """Retained stock answer plus canonical captain event, never a boolean."""
    if not isinstance(ident, str) or not re.fullmatch('D-' + re.escape(project) + r'-T260-[1-9][0-9]*', ident): return False
    try:
        if safe_path(state / 'pending' / (ident + '.json')).exists(): return False
        record = read(state / 'decisions' / (ident + '.json'))
        if (record.get('id') != ident or record.get('task') != 'T-260'
                or record.get('project', 'firstmate-workflow') != project
                or record.get('chosen') != 'A' or record.get('kind') != 'choice'
                or record.get('purpose') != 'decision' or record.get('effect') != 'hold'
                or record.get('effect_outcome') != 'done' or effect(record, 'A') != 'hold'):
            return False
        notes = record['details']['en']['notes']
        if not isinstance(notes, list): return False
        prefix = 'Queue policy SHA-256:' if note.startswith('Queue policy') else 'Queue resume:'
        matches = [n for n in notes if isinstance(n, dict) and
                   isinstance(n.get('text'), str) and n['text'].startswith(prefix)]
        if (len(matches) != 1 or matches[0].get('kind') not in ('note', 'caution')
                or matches[0]['text'] != note): return False
        events = [json.loads(line) for line in safe_path(state / 'events.jsonl').read_text().splitlines() if line.strip()]
        candidates = [e for e in events if e.get('type') == 'decision_made'
                      and e.get('data', {}).get('decision') == ident]
        if not candidates: return False
        e = candidates[-1]; d = e.get('data', {})
        return (e.get('actor') == 'captain' and e.get('task') == 'T-260'
                and e.get('project', 'firstmate-workflow') == project
                and d.get('chosen') == 'A' and d.get('effect') == 'hold' and d.get('outcome') == 'done')
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return False


def load_policy(state, repository, base, project, external=False):
    path = state / 'autopilot/queue-policy.json'
    try:
        value = read(path)
    except FileNotFoundError:
        return None, ''
    except (OSError, ValueError):
        return None, 'queue-policy-invalid'
    if external:
        if not isinstance(value, dict): return None, 'queue-policy-invalid'
        if value.get('enabled') is True or value.get('strategy') == 'self-front':
            return None, 'self-strategy-not-supported'
        return None, ''
    try:
        value = validate_policy(value, repository, base)
        if value['enabled'] and not decision_authority(state, project, value['captain_authorization'],
                'Queue policy SHA-256: ' + policy_digest(value)):
            raise ValueError('queue rollout authorization unavailable')
        return value, ''
    except ValueError:
        return None, 'queue-policy-invalid-or-unapproved'


def validate_queue(q, repository=None, base=None):
    if not isinstance(q, dict) or type(q.get('version')) is not int or q['version'] != VERSION:
        raise ValueError('unknown or corrupt queue schema')
    if (not isinstance(q.get('policy_digest'), str) or not DIGEST.fullmatch(q['policy_digest'])
            or not isinstance(q.get('repository'), str) or not q['repository']
            or not isinstance(q.get('base'), str) or not q['base']
            or (repository is not None and q['repository'] != repository)
            or (base is not None and q['base'] != base)
            or type(q.get('enabled')) is not bool or not integer(q.get('next_sequence'), 1)
            or not integer(q.get('owner_generation')) or not isinstance(q.get('owner_receipt'), dict)
            or not isinstance(q.get('members'), dict) or not isinstance(q.get('counters'), dict)):
        raise ValueError('invalid queue identity or owner schema')
    if not isinstance(q.get('accounted'), list) or not all(isinstance(x, str) for x in q['accounted']):
        raise ValueError('invalid queue accounting identities')
    for name in COUNTERS:
        value = q['counters'].get(name)
        if type(value) not in (int, float) or not 0 <= value < float('inf'):
            raise ValueError('invalid queue counters')
    sequences = set()
    for number, m in q['members'].items():
        if (not isinstance(number, str) or not re.fullmatch(r'[1-9][0-9]*', number)
                or not isinstance(m, dict) or not isinstance(m.get('task'), str)
                or not re.fullmatch(r'(?:T|SK)-[0-9]+', m['task'])
                or not integer(m.get('admission_sequence'), 1)
                or m['admission_sequence'] in sequences or m['admission_sequence'] >= q['next_sequence']
                or not SHA.fullmatch(m.get('head', '')) or not SHA.fullmatch(m.get('base_sha', ''))
                or m.get('state') not in STATES or not isinstance(m.get('reason'), str) or len(m['reason']) > 500
                or not integer(m.get('attempt_generation')) or not isinstance(m.get('jobs'), list)
                or not all(isinstance(j, str) and re.fullmatch(r'[0-9a-f]{32}', j) for j in m['jobs'])
                or not isinstance(m.get('timestamps'), dict)
                or any(type(v) not in (int, float) or not 0 <= v < float('inf') for v in m['timestamps'].values())
                or not all(m.get(k) is None or isinstance(m.get(k), str)
                           for k in ('failed_fingerprint', 'resume_decision', 'card_id'))):
            raise ValueError('invalid queue member')
        sequences.add(m['admission_sequence'])
        request = m.get('request')
        if request is not None:
            if (not isinstance(request, dict) or not isinstance(request.get('request_id'), str)
                    or not DIGEST.fullmatch(request['request_id']) or request.get('kind') != 'update'
                    or not SHA.fullmatch(request.get('H', '')) or not SHA.fullmatch(request.get('B', ''))
                    or not DIGEST.fullmatch(request.get('policy_digest', ''))
                    or not integer(request.get('attempt_generation'))
                    or request.get('state') not in ('planned', 'issued', 'accepted', 'uncertain', 'settled')
                    or (request.get('state') != 'settled' and q.get('front') != number)
                    or 'outcome' not in request
                    or (request['outcome'] is not None and not isinstance(request['outcome'], str))):
                raise ValueError('invalid queue request')
    if q.get('front') is not None and q['front'] not in q['members']:
        raise ValueError('invalid queue front')
    active = {'front', 'updating', 'waiting-ci', 'waiting-review', 'verifying', 'waiting-captain', 'merging'}
    if any(m['state'] in active and q['front'] != n for n, m in q['members'].items()):
        raise ValueError('unreserved active queue member')
    return q


def new_queue(policy):
    return dict(version=VERSION, policy_digest=policy_digest(policy), repository=policy['repository'],
                base=policy['base'], enabled=True, next_sequence=1, owner_generation=0,
                owner_receipt={}, members={}, front=None, counters={n: 0 for n in COUNTERS}, accounted=[])


def binding(q, member):
    return dict(policy_digest=q['policy_digest'], admission_sequence=member['admission_sequence'],
                attempt_generation=member['attempt_generation'], H=member['head'], B=member['base_sha'])


def transition(q, number, state, reason, now):
    m = q['members'][number]
    if (m['state'], m['reason']) == (state, reason): return
    old = m['state']; stamps = m['timestamps']
    identity = f'{number}:{m["attempt_generation"]}:{old}:{stamps.get("transition", 0)}'
    if old == 'waiting-captain' and state != old and identity not in q['accounted']:
        q['counters']['captain_wait_seconds'] += max(0, now - stamps.get('captain_started', now))
        q['accounted'].append(identity)
    if state == 'waiting-captain' and old != state: stamps['captain_started'] = now
    stamps['transition'] = stamps.get('transition', 0) + 1
    stamps['changed'] = now
    m.update(state=state, reason=reason[:500])


def release(q, number, now):
    if q['front'] != number: return
    m = q['members'][number]
    ident = f'front:{number}:{m["attempt_generation"]}:{m["timestamps"].get("acquired")}'
    if ident not in q['accounted']:
        q['counters']['front_seconds'] += max(0, now - m['timestamps'].get('acquired', now))
        q['accounted'].append(ident)
    q['front'] = None


def cancelled_card(state, project, ident, task):
    """A task park alone never cancels a pending captain merge authority."""
    try:
        if safe_path(state / 'pending' / (ident + '.json')).exists(): return False
        r = read(state / 'decisions' / (ident + '.json'))
        chosen = r.get('chosen')
        if (r.get('id') != ident or r.get('task') != task or r.get('project', 'firstmate-workflow') != project
                or r.get('kind') != 'merge' or chosen not in ('B', 'C') or effect(r, chosen) != 'hold'
                or r.get('effect') != 'hold' or r.get('effect_outcome') != 'done'): return False
        events = [json.loads(line) for line in safe_path(state / 'events.jsonl').read_text().splitlines() if line.strip()]
        matches = [e for e in events if e.get('type') == 'decision_made' and e.get('data', {}).get('decision') == ident]
        if not matches: return False
        e = matches[-1]; d = e.get('data', {})
        return (e.get('actor') == 'captain' and e.get('task') == task
                and e.get('project', 'firstmate-workflow') == project and d.get('chosen') == chosen
                and d.get('effect') == 'hold' and d.get('outcome') == 'done')
    except (ValueError, KeyError, TypeError, AttributeError, OSError): return False


def projection(q):
    validate_queue(q)
    def member(number, sequence=False):
        m = q['members'][number]
        value = dict(PR=int(number), task=m['task'], state=m['state'], H=m['head'], B=m['base_sha'],
                     generation=m['attempt_generation'], reason=m['reason'])
        if sequence: value['sequence'] = m['admission_sequence']
        return value
    return dict(version=VERSION, repository=q['repository'], base=q['base'], enabled=q['enabled'],
                front=member(q['front']) if q['front'] else None, generation=q['owner_generation'],
                members=[member(n, True) for n in sorted(q['members'], key=lambda n:q['members'][n]['admission_sequence'])],
                counters={k:q['counters'][k] for k in COUNTERS}, ci_runner_minutes='unavailable')


def status(argv):
    if (len(argv) != 5 or argv[0] != 'status' or argv[1] != '--state'
            or argv[3] != '--format' or argv[4] not in ('json', 'text') or not Path(argv[2]).is_absolute()):
        print('usage: status --state <absolute-self-state-directory> --format json|text')
        return 64
    try:
        engine = Path(os.environ.get('FM_ENGINE_ROOT') or Path(__file__).resolve().parents[2])
        state = safe_path(Path(argv[2])); canonical = safe_path(engine / 'state')
        if state != canonical or not state.is_dir() or not (engine / 'bin/fm-config.sh').is_file():
            raise ValueError('nonself state')
        path = safe_path(state / 'autopilot/state.json')
        if not path.exists():
            print('{"status":"not initialized"}' if argv[4] == 'json' else 'Self queue: not initialized')
            return 3
        record = read(path)
        if not isinstance(record, dict): raise ValueError('invalid state')
        if 'self_queue' not in record:
            print('{"status":"not initialized"}' if argv[4] == 'json' else 'Self queue: not initialized')
            return 3
        report = projection(record['self_queue'])
        if argv[4] == 'json': print(json.dumps(report, sort_keys=True))
        else:
            print(f'Self queue: {"enabled" if report["enabled"] else "off"}; {report["repository"]} / {report["base"]}')
            for m in report['members']:
                print(f'#{m["PR"]} {m["task"]}: {m["state"]} ({m["reason"]}); H={m["H"]} B={m["B"]} generation={m["generation"]}')
            print('CI runner minutes: unavailable')
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        print('{"status":"invalid self queue state"}' if argv[4] == 'json' else 'Self queue: invalid self queue state')
        return 65


if __name__ == '__main__':
    sys.exit(status(sys.argv[1:]))
