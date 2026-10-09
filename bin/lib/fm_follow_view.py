"""What a round's window shows (T-271): the run's log made readable, and
the `follow --all` dashboard, one line per live round.

bin/fm-herdr.py loads this file lazily inside `follow`, with bytecode off,
and keeps its raw byte-for-byte copy of the log when the file is missing or
raw mode is asked for. The view only reads: run.log, the event log beside
the attempt's own record root, the attempt's and actor's records, and the
worktree through `git diff` with every repository setting that could start a
program, fetch or take a lock turned off. Besides git it runs only the `ps`
of fm-herdr.py's liveness helpers, through the probe fm-herdr.py hands it,
and that probe creates nothing (no execution.lock either).

Every word it prints is English and comes from LABELS: this is terminal
output like the rest of bin/, not the board's dictionaries (section 9).
Everything read from a log, a record or a worktree passes through clean()
first, so a model cannot move the cursor or recolour the terminal.
"""
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import textwrap
import time


LABELS = {
    'header': '{actor}  {task}  round {round}  {pr}  {elapsed}',
    'header_now': 'now: {activity}   vendor silence: {silence}',
    'pr': 'PR #{pr}',
    'no_pr': 'no PR yet',
    'unknown': 'unknown',
    'command': '$ {command}',
    'exit': 'exit {code}',
    'hidden': '... {count} lines hidden ...',
    'message': '> ',
    'search': 'search: {query}',
    'diff': 'diff of {path} against HEAD, as the file is now',
    'binary': 'binary file changed: {path}',
    'unchanged': 'no change against HEAD: {path}',
    'unavailable': 'diff unavailable: {reason}',
    'no_tree': 'worktree {path} no longer exists',
    'no_path': '{path} no longer exists',
    'outside': '{path} is outside the worktree',
    'git_failed': 'git exited {code}: {detail}',
    'git_missing': 'git could not run: {detail}',
    'status': '== ',
    'notice': '!! ',
    'event': '** {type}{pr}: {summary}',
    'event_bare': '** {type}{pr}',
    'event_pr': ' (PR #{pr})',
    'error': 'error: {text}',
    'waiting': 'waiting for {vendor}: it sends its output when it finishes ({time})',
    'doing_command': 'running a command: {command}',
    'doing_edit': 'editing a file: {path}',
    'doing_message': 'writing a message',
    'doing_wait': 'waiting for {vendor}',
    'doing_start': 'starting',
    'doing_done': 'finished',
    'lines_invalid': 'FM_FOLLOW_LINES must be a whole number from 1 to 200; showing 5',
    'col_actor': 'ACTOR',
    'col_task': 'TASK',
    'col_elapsed': 'ELAPSED',
    'col_now': 'NOW',
    'col_log': 'LOG AGE',
    'col_silence': 'VENDOR SILENCE',
    'stuck': 'possibly stuck',
    'no_rounds': 'no live rounds',
}


def say(key, **values):
    return LABELS[key].format(**values)


# Terminal control a log may carry: CSI, OSC, DCS/SOS/PM/APC strings, any
# other escape, and the 8-bit CSI. Then every other control character but
# newline and tab.
ESCAPES = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?'
                     r'|\x1b[PX^_][^\x1b]*(?:\x1b\\)?|\x1b.?|\x9b[0-?]*[ -/]*[@-~]', re.S)
CONTROLS = re.compile(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]')


def clean(text):
    return CONTROLS.sub('', ESCAPES.sub('', str(text)))


# What fm-herdr.py's runner and the sandbox launcher write into run.log.
HEARTBEAT = re.compile(r'\[fm\] \S+ still running \([0-9]+s\)')
FIRSTMATE = re.compile(r'\[fm\] ')
SANDBOX = re.compile(r'(?:fm-sandbox|sandbox): ')
BINARY = re.compile(r'^(?:Binary files |GIT binary patch)', re.M)
GIT_HEADER = re.compile(r'(?:\+\+\+|---|diff |index |new file|deleted file|old mode|new mode|similarity|rename )')
SAFE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}')

# git as the view runs it: no optional locks, no filesystem monitor, no
# pager, no rename detection; diff with no external program and no text
# converter. The environment refuses prompts, lazy fetches and every
# transport protocol.
GIT_OPTIONS = ('--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'core.pager=cat',
               '-c', 'diff.renames=false')
DIFF = ('diff', '--no-ext-diff', '--no-textconv', '--no-color')

GREEN, RED, CYAN, YELLOW, MAGENTA, GREY, BLUE = '32', '31', '36', '33', '35', '90', '34'


def duration(seconds):
    if seconds is None: return say('unknown')
    whole = max(0, int(seconds))
    hours, rest = divmod(whole, 3600)
    minutes, secs = divmod(rest, 60)
    if hours: return f'{hours}h{minutes:02d}m'
    if minutes: return f'{minutes}m{secs:02d}s'
    return f'{secs}s'


def setting(name, default):
    """A non-negative number of seconds from the environment, else default."""
    try: value = float(os.environ.get(name, ''))
    except ValueError: return default
    return value if math.isfinite(value) and value >= 0 else default


def lines_limit():
    """FM_FOLLOW_LINES, and whether it was set to something it cannot be."""
    given = os.environ.get('FM_FOLLOW_LINES', '')
    if given == '': return 5, False
    if re.fullmatch(r'[0-9]{1,3}', given) and 1 <= int(given) <= 200: return int(given), False
    return 5, True


def collapse(lines, keep):
    """The first and last `keep` lines, and how many between them were hidden."""
    if len(lines) <= 2 * keep: return [(line, False) for line in lines]
    hidden = say('hidden', count=len(lines) - 2 * keep)
    return ([(line, False) for line in lines[:keep]] + [(hidden, True)]
            + [(line, False) for line in lines[-keep:]])


def record(path):
    try: value = json.loads(Path(path).read_text())
    except (OSError, ValueError): return {}
    return value if isinstance(value, dict) else {}


# --- built-in highlighting, by file extension ------------------------------

LANGUAGES = {'.py': 'python', '.sh': 'shell', '.bash': 'shell', '.zsh': 'shell',
             '.ts': 'script', '.tsx': 'script', '.js': 'script', '.jsx': 'script',
             '.mjs': 'script', '.cjs': 'script', '.json': 'json', '.md': 'markdown',
             '.markdown': 'markdown'}
KEYWORDS = {
    'python': ('and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue', 'def',
               'del', 'elif', 'else', 'except', 'False', 'finally', 'for', 'from', 'global',
               'if', 'import', 'in', 'is', 'lambda', 'None', 'nonlocal', 'not', 'or', 'pass',
               'raise', 'return', 'True', 'try', 'while', 'with', 'yield'),
    'shell': ('if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done',
              'case', 'esac', 'function', 'in', 'select', 'return', 'local', 'export',
              'readonly', 'declare', 'set', 'unset', 'shift', 'exit', 'break', 'continue'),
    'script': ('async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
               'default', 'delete', 'do', 'else', 'export', 'extends', 'false', 'finally',
               'for', 'from', 'function', 'if', 'import', 'in', 'instanceof', 'interface',
               'let', 'new', 'null', 'of', 'return', 'static', 'super', 'switch', 'this',
               'throw', 'true', 'try', 'type', 'typeof', 'undefined', 'var', 'void', 'while',
               'yield'),
    'json': ('true', 'false', 'null'),
}
TOKENS = {'comment': GREY, 'string': YELLOW, 'number': CYAN, 'keyword': MAGENTA}
_SQ = r"'(?:\\.|[^'\\])*'?"
_DQ = r'"(?:\\.|[^"\\])*"?'
_BQ = r'`(?:\\.|[^`\\])*`?'
_NUMBER = r'(?<![\w.])[0-9]+(?:\.[0-9]+)?(?![\w.])'


def _words(language):
    return r'\b(?:' + '|'.join(KEYWORDS[language]) + r')\b'


def _grammar(comment, string, keyword):
    parts = (('comment', comment), ('string', string), ('number', _NUMBER), ('keyword', keyword))
    return re.compile('|'.join('(?P<' + name + '>' + rule + ')' for name, rule in parts if rule))


GRAMMARS = {
    'python': _grammar(r'#.*', _SQ + '|' + _DQ, _words('python')),
    'shell': _grammar(r'(?<![^\s;|&(])#.*', _SQ + '|' + _DQ, _words('shell')),
    'script': _grammar(r'//.*|/\*.*?(?:\*/|$)', _SQ + '|' + _DQ + '|' + _BQ, _words('script')),
    'json': _grammar(None, _DQ, _words('json')),
    'markdown': _grammar(r'<!--.*?(?:-->|$)', r'`[^`]*`?', r'^#{1,6}(?:\s.*|$)'),
}


class Style:
    def __init__(self, on): self.on = on

    def __call__(self, code, text):
        if not (self.on and code and text): return text
        return '\x1b[' + code + 'm' + text + '\x1b[0m'


def highlight(style, language, text, base=''):
    grammar = GRAMMARS.get(language)
    if grammar is None or not style.on: return style(base, text)
    out, at = [], 0
    for found in grammar.finditer(text):
        if found.start() == found.end(): continue
        out.append(style(base, text[at:found.start()]))
        out.append(style(TOKENS[found.lastgroup], found.group()))
        at = found.end()
    out.append(style(base, text[at:]))
    return ''.join(out)


# --- the worktree's change, through git with nothing it could start ---------

def git(root, *args):
    env = dict(os.environ, GIT_PAGER='cat', GIT_TERMINAL_PROMPT='0', GIT_NO_LAZY_FETCH='1',
               GIT_ALLOW_PROTOCOL='')
    try:
        done = subprocess.run(['git', *GIT_OPTIONS, '-C', str(root), *args], env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        return None, say('git_missing', detail=clean(error))
    return done, None


def failed(done):
    detail = clean(done.stderr.decode('utf-8', 'replace')).strip().split('\n')[0]
    return 'unavailable', say('git_failed', code=done.returncode, detail=detail)


def relative(root, path):
    """`path` inside the worktree `root`, or None."""
    given = Path(path)
    rel = None
    if not given.is_absolute(): rel = given
    else:
        for base, target in ((root, given), (root.resolve(), given), (root.resolve(), given.resolve())):
            try: rel = target.relative_to(base); break
            except ValueError: continue
    if rel is None or '..' in rel.parts or str(rel) in ('', '.'): return None
    return rel


def change_of(tree, path):
    """('lines', name, lines), ('binary', name), ('unchanged', name) or
    ('unavailable', reason): one file's change against HEAD, staged and
    unstaged together, as the file is now."""
    if not tree: return 'unavailable', say('no_tree', path=say('unknown'))
    root = Path(tree)
    if not root.is_dir(): return 'unavailable', say('no_tree', path=clean(tree))
    rel = relative(root, path)
    if rel is None: return 'unavailable', say('outside', path=clean(path))
    name = rel.as_posix()
    done, error = git(root, *DIFF, 'HEAD', '--', name)
    if error: return 'unavailable', error
    if done.returncode: return failed(done)
    out = done.stdout
    if not out.strip():
        here = root / rel
        if not (here.exists() or here.is_symlink()):
            return 'unavailable', say('no_path', path=clean(name))
        listed, error = git(root, 'ls-files', '--error-unmatch', '--', name)
        if error: return 'unavailable', error
        if listed.returncode == 0: return 'unchanged', clean(name)
        if listed.returncode != 1: return failed(listed)
        done, error = git(root, *DIFF, '--no-index', '--', '/dev/null', name)
        if error: return 'unavailable', error
        if done.returncode not in (0, 1): return failed(done)
        out = done.stdout
    text = clean(out.decode('utf-8', 'replace'))
    if BINARY.search(text): return 'binary', clean(name)
    return 'lines', clean(name), text.rstrip('\n').split('\n')


# --- the terminal --------------------------------------------------------

class Screen:
    """One output stream. Colour and screen control only on a terminal with
    no NO_COLOR; otherwise the same words as plain lines."""

    def __init__(self, stream=None):
        self.out = stream if stream is not None else sys.stdout.buffer
        try: self.tty = os.isatty(self.out.fileno())
        except (AttributeError, OSError, ValueError): self.tty = False
        self.fancy = self.tty and not os.environ.get('NO_COLOR')
        self.style = Style(self.fancy)
        self.header = 0
        self.beat = False
        self.last_beat = None
        self.resized = False
        self.framed = False

    def write(self, text):
        self.out.write(text.encode('utf-8', 'replace')); self.out.flush()

    def size(self):
        try: columns, rows = os.get_terminal_size(self.out.fileno())
        except (AttributeError, OSError, ValueError): return 80, 24
        return max(columns, 20), max(rows, 5)

    def width(self):
        """Where text wraps: the terminal's width, else COLUMNS, else nowhere."""
        if self.tty: return self.size()[0]
        given = os.environ.get('COLUMNS', '')
        return int(given) if re.fullmatch(r'[0-9]{2,4}', given) and int(given) >= 20 else None

    def line(self, text):
        if self.beat: self.write('\n'); self.beat = False
        self.write(text + '\n')

    def heartbeat(self, text):
        """In place on a terminal; as a plain line at most once a minute."""
        if self.fancy:
            text = text[:self.size()[0] - 1]
            self.write(('\r\x1b[2K' if self.beat else '') + self.style(CYAN, text))
            self.beat = True
            return
        now = time.monotonic()
        if self.last_beat is None or now - self.last_beat >= 60:
            self.last_beat = now
            self.line(text)

    def start_header(self, lines):
        if not self.fancy:
            for text in lines: self.line(text)
            return
        self.header = len(lines)
        self.write('\x1b[H\x1b[2J')
        self.region(bottom=False)
        self.draw(lines)
        if hasattr(signal, 'SIGWINCH'):
            try: signal.signal(signal.SIGWINCH, self.on_resize)
            except ValueError: pass  # not the main thread: no resize redraw

    def on_resize(self, _signum, _frame):
        self.resized = True

    def region(self, bottom):
        # Setting the scroll region homes the cursor; put it back below the header.
        rows = self.size()[1]
        self.write(f'\x1b[{self.header + 1};{rows}r\x1b[{rows if bottom else self.header + 1};1H')

    def draw(self, lines):
        if not (self.fancy and self.header): return
        if self.resized:
            self.resized = False
            self.region(bottom=True)
        columns = self.size()[0]
        parts = ['\x1b7']
        for row, text in enumerate(lines[:self.header], 1):
            parts.append(f'\x1b[{row};1H\x1b[2K' + self.style('7' if row == 1 else '1', text[:columns]))
        parts.append('\x1b8')
        self.write(''.join(parts))

    def frame(self, lines):
        """The dashboard's whole screen, redrawn in place."""
        columns = self.size()[0]
        start = '\x1b[?25l\x1b[H\x1b[2J' if not self.framed else '\x1b[H'
        self.framed = True
        self.write(start + '\r\n'.join(styled + '\x1b[K' for styled in lines(columns)) + '\x1b[J')

    def close(self):
        if self.beat: self.write('\n'); self.beat = False
        if self.fancy and self.header:
            self.write('\x1b7\x1b[r\x1b8')
            self.header = 0
        if self.framed:
            self.write('\r\n\x1b[?25h')
            self.framed = False


# --- one round -----------------------------------------------------------

class Round:
    """One attempt's log, parsed; rendered when it has a screen. Without one
    (the dashboard) it only keeps what the round is doing now."""

    def __init__(self, attempt, probe, screen=None, engine=None):
        self.attempt = attempt = Path(attempt)
        self.probe, self.screen = probe, screen
        self.style = screen.style if screen else Style(False)
        invocation = record(attempt / 'invocation.json')
        identity = record(attempt.parent / 'identity.json')
        self.actor = identity.get('actor') or invocation.get('actor') or attempt.parent.name
        self.task = identity.get('task') or invocation.get('task')
        self.round = identity.get('round')
        default = None
        roots = (engine, attempt.parents[3] if len(attempt.parents) > 3 else None, os.environ.get('FM_ROOT'))
        for where in roots:
            if where and default is None:
                try: default = probe.default_project(Path(where))
                except (OSError, ValueError): default = None
        self.default = default
        self.project = identity.get('project') or default
        adapter = invocation.get('adapter')
        self.vendor = Path(adapter).stem if isinstance(adapter, str) and adapter else None
        self.tree = invocation.get('tree') if isinstance(invocation.get('tree'), str) else None
        try: self.started = (attempt / 'invocation.json').stat().st_mtime
        except OSError: self.started = None
        self.log = attempt / 'run.log'
        self.at, self.rest, self.skip = 0, b'', False
        # <root>/state/runs/<actor>/<attempt> beside <root>/state/events.jsonl
        self.events = attempt.parent.parent.parent / 'events.jsonl'
        self.event_at, self.event_rest = 0, b''
        self.pr = None
        self.pending = []
        self.attached = time.monotonic()
        self.heard = None
        self.waited = False
        self.doing = ('wait', '')
        self.shown = set()
        self.block = None
        self.keep, self.bad_keep = lines_limit()
        self.quiet = setting('FM_FOLLOW_QUIET', 30.0)

    # what it reads

    def read_log(self, tail=0):
        try:
            with self.log.open('rb') as source:
                if tail and self.at == 0:
                    size = os.fstat(source.fileno()).st_size
                    if size > tail: self.at, self.skip = size - tail, True
                source.seek(self.at)
                data = source.read(1 << 20)
        except OSError: return b''
        self.at += len(data)
        if self.skip and data:
            cut = data.find(b'\n')
            if cut < 0: return b''
            data, self.skip = data[cut + 1:], False
        return data

    def poll_events(self):
        """This task's newest pull request, and this actor's new events as lines."""
        try:
            with self.events.open('rb') as source:
                if os.fstat(source.fileno()).st_size < self.event_at: self.event_at, self.event_rest = 0, b''
                source.seek(self.event_at)
                data = source.read()
        except OSError: return []
        self.event_at += len(data)
        *lines, self.event_rest = (self.event_rest + data).split(b'\n')
        said = []
        for raw in lines:
            try: event = json.loads(raw)
            except ValueError: continue
            if not isinstance(event, dict): continue
            # an event naming no project is the default project's
            if (event.get('project') or self.default) != self.project: continue
            pr = event.get('pr')
            pr = pr if isinstance(pr, int) and not isinstance(pr, bool) else None
            if self.task and event.get('task') == self.task and pr is not None: self.pr = pr
            if event.get('actor') != self.actor: continue
            kind = clean(event.get('type') or say('unknown'))
            summary = event.get('summary')
            summary = summary.get('en') if isinstance(summary, dict) else None
            part = say('event_pr', pr=pr) if pr is not None else ''
            text = (say('event', type=kind, pr=part, summary=clean(summary)) if isinstance(summary, str) and summary
                    else say('event_bare', type=kind, pr=part))
            said.append(self.style(MAGENTA, text))
        return said

    # what it is doing

    def silence(self, now=None):
        """Observed vendor silence, or None while not yet watched long enough."""
        now = time.monotonic() if now is None else now
        if now - self.attached < self.quiet: return None
        return now - (self.heard if self.heard is not None else self.attached)

    def observed(self, now=None):
        now = time.monotonic() if now is None else now
        return now - (self.heard if self.heard is not None else self.attached)

    def activity(self, alive=True, over=False):
        if over: return say('doing_done')
        kind, what = self.doing
        if kind == 'command': return say('doing_command', command=what[:80])
        if kind == 'edit': return say('doing_edit', path=what)
        if kind == 'message': return say('doing_message')
        vendor = clean(self.vendor) if self.vendor else say('unknown')
        quiet = self.silence()
        if alive and quiet is not None and quiet > self.quiet:
            return say('waiting', vendor=vendor, time=duration(quiet))
        return say('doing_wait', vendor=vendor)

    def header(self, alive=True, over=False):
        unknown = say('unknown')
        pr = say('pr', pr=self.pr) if self.pr is not None else say('no_pr')
        quiet = self.silence()
        return [say('header', actor=clean(self.actor or unknown), task=clean(self.task or unknown),
                    round=clean(self.round) if self.round is not None else unknown, pr=pr,
                    elapsed=duration(time.time() - self.started) if self.started else unknown),
                say('header_now', activity=self.activity(alive, over),
                    silence=duration(quiet) if quiet is not None else unknown)]

    # what it prints

    def put(self, text):
        if self.screen: self.screen.line(text)

    def feed(self, data, final=False):
        *lines, self.rest = (self.rest + data).split(b'\n')
        if final and self.rest:
            lines.append(self.rest); self.rest = b''
        for raw in lines: self.take(raw.decode('utf-8', 'replace').rstrip('\r'))
        if final: self.unblock()

    def take(self, text):
        if HEARTBEAT.match(text):
            if self.screen: self.screen.heartbeat(say('status') + clean(text))
            return
        self.heard, self.waited = time.monotonic(), False
        ours = FIRSTMATE.match(text) or SANDBOX.match(text)
        if self.block is not None and not ours:
            # a vendor's pretty-printed final object, gathered whole
            self.block.append(text)
            if text == '}':
                block, self.block = self.block, None
                try: found = json.loads('\n'.join(block))
                except ValueError: found = None
                if not (isinstance(found, dict) and self.handle(found)):
                    for line in block: self.plain(line)
            elif len(self.block) > 4000: self.unblock()
            return
        if text == '{' and not ours:
            self.block = [text]; return
        if text.startswith('{'):
            try: found = json.loads(text)
            except ValueError: found = None
            if isinstance(found, dict) and self.handle(found): return
        if FIRSTMATE.match(text): self.put(self.style(CYAN, say('status') + clean(text)))
        elif SANDBOX.match(text): self.put(self.style(YELLOW, say('notice') + clean(text)))
        else: self.plain(text)

    def unblock(self):
        block, self.block = self.block, None
        for line in block or (): self.plain(line)

    def plain(self, text):
        self.put(clean(text))

    def handle(self, event):
        """True when the object is one this view understands (shown or not)."""
        kind = event.get('type')
        if kind in ('thread.started', 'turn.started', 'turn.completed'):
            self.doing = ('wait', ''); return True
        if kind == 'turn.failed':
            error = event.get('error')
            text = error.get('message') if isinstance(error, dict) else error
            self.message(say('error', text=clean(text or say('unknown'))), RED); return True
        if kind == 'error':
            self.message(say('error', text=clean(event.get('message') or say('unknown'))), RED); return True
        if kind in ('item.started', 'item.updated', 'item.completed'):
            item = event.get('item')
            if isinstance(item, dict): self.item(kind, item)
            return True
        if kind == 'result':  # claude and cursor-agent: one final object
            if isinstance(event.get('result'), str):
                self.message(event['result'], RED if event.get('is_error') else '')
            return True
        if isinstance(event.get('response'), str):  # gemini
            self.message(event['response']); return True
        if isinstance(event.get('error'), dict) and isinstance(event['error'].get('message'), str):
            self.message(say('error', text=clean(event['error']['message'])), RED); return True
        return False

    def item(self, phase, item):
        kind, ident = item.get('type'), item.get('id')
        if kind == 'command_execution': self.command(phase, item)
        elif kind == 'file_change':
            if phase == 'item.completed': self.file_change(item)
        elif kind == 'agent_message':
            if phase == 'item.completed' and isinstance(item.get('text'), str):
                self.message(item['text']); self.doing = ('message', '')
        elif kind == 'web_search':
            key = ('search', ident)
            if not item.get('query') and phase != 'item.completed': return  # asked, not yet said
            if ident is None or key not in self.shown:
                if ident is not None: self.shown.add(key)
                self.put(self.style(BLUE, say('search', query=clean(item.get('query') or say('unknown')))))
            self.doing = ('wait', '')
        else:
            self.doing = ('wait', '')

    def command(self, phase, item):
        command = item.get('command')
        if isinstance(command, list): command = ' '.join(str(part) for part in command)
        command = clean(command or '').replace('\n', ' ')
        key = ('command', item.get('id'))
        if key[1] is None or key not in self.shown:
            if key[1] is not None: self.shown.add(key)
            self.put(self.style('1;' + YELLOW, say('command', command=command)))
        if phase != 'item.completed':
            self.doing = ('command', command); return
        output = clean(item.get('aggregated_output') or '').rstrip('\n')
        for text, hidden in collapse(output.split('\n') if output else [], self.keep):
            self.put('  ' + (self.style(GREY, text) if hidden else text))
        code = item.get('exit_code')
        if code is not None:
            self.put('  ' + self.style(GREEN if code == 0 else RED, say('exit', code=clean(code))))
        self.doing = ('wait', '')

    def file_change(self, item):
        changes = item.get('changes') if isinstance(item.get('changes'), list) else []
        for change in changes:
            if not isinstance(change, dict): continue
            kind = change.get('kind')
            paths = [change.get('path'), change.get('move_path'),
                     kind.get('move_path') if isinstance(kind, dict) else None]
            for path in paths:
                if not (isinstance(path, str) and path): continue
                self.doing = ('edit', clean(path))
                if self.screen: self.diff(path)

    def diff(self, path):
        found = change_of(self.tree, path)
        style = self.style
        if found[0] == 'unavailable':
            self.put(style(GREY, say('unavailable', reason=found[1]))); return
        if found[0] == 'binary':
            self.put(style('1', say('binary', path=found[1]))); return
        if found[0] == 'unchanged':
            self.put(style(GREY, say('unchanged', path=found[1]))); return
        _, name, lines = found
        language = LANGUAGES.get(Path(name).suffix.lower())
        self.put(style('1', say('diff', path=name)))
        for text, hidden in collapse(lines, 200):
            if hidden: self.put(style(GREY, text))
            elif GIT_HEADER.match(text): self.put(style('1', text))
            elif text.startswith('@@'): self.put(style(CYAN, text))
            elif text.startswith('+'): self.put(style(GREEN, '+') + highlight(style, language, text[1:], GREEN))
            elif text.startswith('-'): self.put(style(RED, text))
            elif text.startswith(' '): self.put(' ' + highlight(style, language, text[1:]))
            else: self.put(style(GREY, text))

    def message(self, text, colour=''):
        """What the model wrote, wrapped to the terminal, marked and coloured apart."""
        self.doing = ('message', '')
        if not self.screen: return
        marker = say('message')
        width = self.screen.width()
        room = max((width or 0) - len(marker), 10)
        for paragraph in clean(text).strip('\n').split('\n'):
            pieces = [paragraph]
            if width and len(paragraph) > room:
                pieces = textwrap.wrap(paragraph, room, break_on_hyphens=False) or ['']
            for piece in pieces:
                self.put(self.style('1;' + BLUE, marker) + self.style(colour or '97', piece))

    # the single-round view

    def state(self, unseen, grace):
        """(over, alive), judged exactly as fm-herdr.py's raw follower judges it."""
        attempt = self.attempt
        if (attempt / 'result.json').exists() or (attempt / 'runner.exit').exists(): return True, False
        pid = attempt / 'runner.pid'
        if pid.is_file():
            try: runner = int(pid.read_text())
            except (ValueError, OSError): return True, False
            try: os.kill(runner, 0)
            except OSError:
                live = self.probe.round_live(attempt, runner)
                return not live, live
            return False, True
        return time.monotonic() - unseen > grace, False

    def tick(self, alive, over, due):
        screen = self.screen
        now = time.monotonic()
        if screen.fancy and (now >= due[0] or screen.resized):
            screen.draw(self.header(alive, over)); due[0] = now + 1
        quiet = self.silence(now)
        if alive and not self.waited and quiet is not None and quiet > self.quiet:
            self.waited = True
            vendor = clean(self.vendor) if self.vendor else say('unknown')
            self.put(self.style(GREY, say('waiting', vendor=vendor, time=duration(quiet))))

    def run(self, poll):
        screen = self.screen
        grace = float(os.environ.get('FM_FOLLOW_GRACE', '120'))
        unseen = time.monotonic()
        self.pending.extend(self.poll_events())
        over, alive = self.state(unseen, grace)
        screen.start_header(self.header(alive, False))
        if self.bad_keep: self.put(self.style(YELLOW, say('notice') + say('lines_invalid')))
        due, events = [time.monotonic() + 1], time.monotonic() + 1
        while True:
            over, alive = self.state(unseen, grace)
            data = self.read_log()
            if data:
                self.feed(data); self.tick(alive, over, due)
                continue
            if time.monotonic() >= events or over:
                self.pending.extend(self.poll_events()); events = time.monotonic() + 1
            for text in self.pending: self.put(text)
            self.pending.clear()
            self.tick(alive, over, due)
            if over:
                self.feed(b'', final=True)
                screen.draw(self.header(False, True))
                return 0
            time.sleep(poll)

    # a dashboard row

    def row(self, starting, watching, stuck_after):
        unknown = say('unknown')
        try: log_age = duration(time.time() - self.log.stat().st_mtime)
        except OSError: log_age = unknown
        quiet = self.silence() if watching else None
        stuck = watching and not starting and self.observed() > stuck_after
        return [clean(self.actor or unknown), clean(self.task or unknown),
                duration(time.time() - self.started) if self.started else unknown,
                say('doing_start') if starting else self.activity(),
                log_age, duration(quiet) if quiet is not None else unknown,
                say('stuck') if stuck else '']


def follow(attempt, poll=0.2, probe=None, engine=None, stream=None):
    """The formatted view of one round, ending when fm-herdr.py's raw
    follower would: a result or exit file, nothing of the round left
    running, or the start grace passed with no round started."""
    screen = Screen(stream)
    view = Round(attempt, probe, screen, engine)
    try: return view.run(poll)
    except KeyboardInterrupt: return 130
    except BrokenPipeError: return 0  # the window went away; that stops nothing
    finally:
        try: screen.close()
        except OSError: pass


def live_attempts(runs, probe, grace):
    """(attempt, starting) for each actor's latest attempt that is live, or
    has no runner.pid yet and is still inside the start grace."""
    found = []
    try: actors = sorted(path for path in Path(runs).iterdir() if path.is_dir() and SAFE_NAME.fullmatch(path.name))
    except OSError: return found
    for actor in actors:
        stamps = []
        for invocation in actor.glob('*/invocation.json'):
            try: stamps.append((invocation.stat().st_mtime_ns, invocation.parent))
            except OSError: continue
        if not stamps: continue
        stamp, attempt = max(stamps)
        if (attempt / 'result.json').exists() or (attempt / 'runner.exit').exists(): continue
        pidfile = attempt / 'runner.pid'
        if pidfile.is_file():
            try: pid = int(pidfile.read_text())
            except (OSError, ValueError): continue
            if probe.round_live(attempt, pid): found.append((attempt, False))
        elif time.time() - stamp / 1e9 <= grace:
            found.append((attempt, True))
    return found


def table(rows, style):
    heads = [say('col_actor'), say('col_task'), say('col_elapsed'), say('col_now'), say('col_log'),
             say('col_silence')]
    cells = [heads + ['']] + [[cell[:60] for cell in row] for row in rows]
    widths = [max(len(row[column]) for row in cells) for column in range(len(heads))]

    def lay(widths):
        def fit(cell, width):
            return cell if len(cell) <= width else cell[:width - 1] + '…'
        return ['  '.join(fit(cell, widths[n]).ljust(widths[n]) for n, cell in enumerate(row[:len(heads)])).rstrip()
                + ('  ' + row[-1] if row[-1] else '') for row in cells]
    plain = lay(widths)

    def styled(columns):
        # The stuck label is the word this view exists to show: when a stuck
        # row would run past the screen, the NOW column gives way first, and
        # on a screen too narrow even then the label leads the row.
        lines, now = plain, 3
        over = max([len(text) for text, row in zip(plain[1:], rows) if row[-1]] or [0]) - columns
        if over > 0:
            narrow = list(widths)
            narrow[now] = max(len(heads[now]), widths[now] - over)
            lines = lay(narrow)
        out = [style('1', lines[0][:columns])]
        for text, row in zip(lines[1:], rows):
            if row[-1] and len(text) > columns: text = row[-1] + '  ' + text[:-len(row[-1]) - 2].rstrip()
            out.append(style(RED if row[-1] else '', text[:columns]))
        return out
    return plain, styled


def dashboard(runs, probe, engine=None, refresh=2.0, stream=None):
    """One line per live round of the selected project. On a terminal it
    refreshes until Ctrl-C; otherwise it prints one snapshot and exits 0."""
    screen = Screen(stream)
    grace = setting('FM_FOLLOW_GRACE', 120.0)
    stuck = setting('FM_FOLLOW_STUCK', 300.0)
    tracked = {}
    try:
        while True:
            rows, seen = [], {}
            for attempt, starting in live_attempts(runs, probe, grace):
                view = tracked.get(attempt) or Round(attempt, probe, None, engine)
                seen[attempt] = view
                if not starting: view.feed(view.read_log(tail=262144))
                rows.append(view.row(starting, screen.fancy, stuck))
            tracked = seen
            if not screen.fancy:
                if not rows: screen.line(say('no_rounds'))
                else:
                    for text in table(rows, screen.style)[0]: screen.line(text)
                return 0
            if rows: screen.frame(table(rows, screen.style)[1])
            else: screen.frame(lambda columns: [say('no_rounds')[:columns]])
            time.sleep(refresh)
    except KeyboardInterrupt:
        return 0
    except BrokenPipeError:
        return 0
    finally:
        try: screen.close()
        except OSError: pass
