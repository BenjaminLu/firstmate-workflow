#!/usr/bin/env python3
"""A stand-in claude CLI for tests/claude-stream.test.sh (T-287).

It reads the output flag it is given, as the real CLI does: for
`--output-format json` it prints the one result object, at the end; for
`--output-format stream-json` (which claude -p accepts only with --verbose)
it prints one event per line, in the shapes the real CLI streams - a
`system` init event, `assistant` events carrying text and tool_use blocks,
`user` events carrying tool_result blocks, and the final `result` event -
with a delay between them.

FM_TEST_SHAPE picks the round: `complete`, `cutoff` (the transcript ends
before its result) or `malformed` (a cut-off event line, then a valid result).
FM_TEST_GATES names a directory: after the step numbered N the stub writes
the file at-N there and waits for the file go-N before going on, so a test
can look at a round that is still running. Asked for the old format, it waits
at step 5 before it prints anything, as a CLI that buffers until the end. FM_TEST_DELAY is the pause between events (0.05 seconds).
"""
import json
import os
from pathlib import Path
import sys
import time

MODEL = 'claude-opus-5-5'
SIDE = 'claude-haiku-4-5-20251001'
SESSION = '3f2b9a64-7d1e-4c55-9a0b-2e6f1c8d4a71'
FINAL = 'Implemented the change and checked it.\n\nWORKER_COMPLETE:T-287'
WAIT = 120


def line(event):
    sys.stdout.write(json.dumps(event, separators=(',', ':')) + '\n')
    sys.stdout.flush()


def result():
    return {'type': 'result', 'subtype': 'success', 'is_error': False, 'duration_ms': 41234,
            'duration_api_ms': 39811, 'num_turns': 4, 'result': FINAL, 'session_id': SESSION,
            'total_cost_usd': 0.2141,
            'usage': {'input_tokens': 18, 'cache_creation_input_tokens': 5120,
                      'cache_read_input_tokens': 20480, 'output_tokens': 912,
                      'server_tool_use': {'web_search_requests': 0}, 'service_tier': 'standard'},
            'modelUsage': {
                SIDE: {'inputTokens': 610, 'outputTokens': 31, 'cacheReadInputTokens': 0,
                       'cacheCreationInputTokens': 0, 'webSearchRequests': 0, 'costUSD': 0.0007,
                       'contextWindow': 200000},
                MODEL: {'inputTokens': 18, 'outputTokens': 912, 'cacheReadInputTokens': 20480,
                        'cacheCreationInputTokens': 5120, 'webSearchRequests': 0, 'costUSD': 0.2134,
                        'contextWindow': 200000}},
            'permission_denials': [], 'uuid': 'b7c1e0f2-0d5a-4b8e-9c3f-6a1d2e4f5a60'}


def assistant(n, *content):
    return {'type': 'assistant',
            'message': {'id': 'msg_01Stub%04d' % n, 'type': 'message', 'role': 'assistant',
                        'model': MODEL, 'content': list(content), 'stop_reason': None,
                        'stop_sequence': None,
                        'usage': {'input_tokens': 4, 'cache_creation_input_tokens': 0,
                                  'cache_read_input_tokens': 5120, 'output_tokens': 120,
                                  'service_tier': 'standard'}},
            'parent_tool_use_id': None, 'session_id': SESSION, 'uuid': 'a-%04d' % n}


def tool_result(n, ident, text, extra):
    return {'type': 'user',
            'message': {'role': 'user', 'content': [
                {'tool_use_id': ident, 'type': 'tool_result', 'content': text, 'is_error': False}]},
            'parent_tool_use_id': None, 'session_id': SESSION, 'uuid': 'u-%04d' % n,
            'tool_use_result': extra}


def steps(cwd):
    notes, work = str(cwd / 'notes.txt'), str(cwd / 'work.txt')
    yield {'type': 'system', 'subtype': 'init', 'cwd': str(cwd), 'session_id': SESSION,
           'tools': ['Bash', 'Read', 'Edit', 'Write', 'Grep', 'Glob'], 'mcp_servers': [],
           'model': MODEL, 'permissionMode': 'dontAsk', 'slash_commands': [],
           'apiKeySource': 'none', 'claude_code_version': '2.1.3', 'output_style': 'default',
           'agents': [], 'skills': [], 'plugins': [], 'uuid': 's-0001'}
    yield assistant(1, {'type': 'text', 'text': 'I will read the notes first.'})
    yield assistant(2, {'type': 'tool_use', 'id': 'toolu_01Read', 'name': 'Read',
                        'input': {'file_path': notes}})
    yield tool_result(3, 'toolu_01Read', '     1\tthe notes\n',
                      {'type': 'text', 'file': {'filePath': notes, 'content': 'the notes\n',
                                                'numLines': 1, 'startLine': 1, 'totalLines': 1}})
    yield assistant(4, {'type': 'tool_use', 'id': 'toolu_01Bash', 'name': 'Bash',
                        'input': {'command': 'ls -1 stream-probe', 'description': 'List the probe'}})
    yield tool_result(5, 'toolu_01Bash', 'one\ntwo',
                      {'stdout': 'one\ntwo', 'stderr': '', 'interrupted': False, 'isImage': False})
    yield assistant(6, {'type': 'tool_use', 'id': 'toolu_01Write', 'name': 'Write',
                        'input': {'file_path': work, 'content': 'done\n'}})
    yield tool_result(7, 'toolu_01Write', 'File created successfully at: ' + work,
                      {'type': 'create', 'filePath': work, 'content': 'done\n', 'structuredPatch': []})
    yield assistant(8, {'type': 'text', 'text': FINAL})


def gate(gates, n):
    if not gates: return
    (Path(gates) / ('at-%d' % n)).touch()
    end = time.monotonic() + WAIT
    while not (Path(gates) / ('go-%d' % n)).exists() and time.monotonic() < end:
        time.sleep(0.02)


def main():
    argv = sys.argv[1:]
    sys.stdin.read()
    fmt = argv[argv.index('--output-format') + 1] if '--output-format' in argv else 'text'
    shape = os.environ.get('FM_TEST_SHAPE', 'complete')
    gates = os.environ.get('FM_TEST_GATES', '')
    delay = float(os.environ.get('FM_TEST_DELAY', '0.05'))
    whole = json.dumps(result(), separators=(',', ':'))
    if fmt == 'json':
        time.sleep(delay)
        gate(gates, 5)
        if shape == 'cutoff':
            sys.stdout.write(whole[:len(whole) // 2] + '\n')
        else:
            if shape == 'malformed': sys.stdout.write(whole[:len(whole) // 3] + '\n')
            sys.stdout.write(whole + '\n')
        return 0
    if fmt != 'stream-json' or '--verbose' not in argv:
        print('Error: When using --print, --output-format=stream-json requires --verbose', file=sys.stderr)
        return 1
    events = list(steps(Path.cwd()))
    for n, event in enumerate(events, 1):
        if event['type'] == 'user' and event['message']['content'][0]['tool_use_id'] == 'toolu_01Write':
            (Path.cwd() / 'work.txt').write_text('done\n')
        if shape == 'malformed' and n == 5:
            text = json.dumps(event, separators=(',', ':'))
            sys.stdout.write(text[:len(text) // 2] + '\n'); sys.stdout.flush()
        else:
            line(event)
        gate(gates, n)
        time.sleep(delay)
    if shape != 'cutoff':
        line(result())
    return 0


if __name__ == '__main__':
    sys.exit(main())
