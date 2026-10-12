"""T-298: the designer round's UI paths, page capture and design gate.

A pull request is a UI change when its diff touches a path matching the
project's `ui` globs (DEFAULT_UI when the project declares none). Only a UI
change gets a designer round, and only a UI change needs a design APPROVE on
its exact head at gate 6. Everything else keeps the path it had before.

Capture runs in the launcher, outside the round's sandbox: every page the
pull request changes is rendered at each viewport, light and dark, for the
head and, when the spec names one in `design.prototype`, for the approved
prototype. One missing screenshot fails the whole capture, and the round
does not start.

    fm_design.py ui      --config C [--project P] --repo R --base B --head H
    fm_design.py capture --config C [--project P] --repo R --base B --head H
                         --task T --spec FILE --out DIR [--prototype DIR] [--prototype-only]
    fm_design.py gate    --config C [--project P] --repo R --base B --head H
                         --state S --evidence-project E --task T [--code ENGINE]
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
BIN = Path(__file__).resolve().parent.parent

DEFAULT_UI = ['**/*.html', '**/*.css', '**/*.scss', '**/*.tsx', '**/*.jsx', '**/*.vue', '**/*.svelte']
WEB_WIDTHS = [320, 390, 768, 1440, 1920]
WEB_HEIGHT = 900
# small phone, large phone and tablet, each portrait and landscape
APP_DEVICES = [('small-phone', 375, 667), ('large-phone', 430, 932), ('tablet', 820, 1180)]
SCHEMES = ('light', 'dark')
PNG = b'\x89PNG\r\n\x1a\n'
SLUG = re.compile(r'[^A-Za-z0-9._-]+')


class CaptureError(ValueError):
    """A page could not be captured; no designer round may start."""


def glob_regex(pattern):
    """Gitignore-like globs: `**/` is any number of directories, `*` one name part."""
    out, i = '', 0
    while i < len(pattern):
        if pattern.startswith('**/', i):
            out += '(?:.*/)?'; i += 3
        elif pattern.startswith('**', i):
            out += '.*'; i += 2
        elif pattern[i] == '*':
            out += '[^/]*'; i += 1
        elif pattern[i] == '?':
            out += '[^/]'; i += 1
        else:
            out += re.escape(pattern[i]); i += 1
    return re.compile(out + r'\Z')


def ui_paths(paths, globs):
    """The changed paths that make a pull request a UI change."""
    compiled = [glob_regex(g) for g in globs]
    return [p for p in paths if any(r.match(p) for r in compiled)]


def ui_globs(config, project=''):
    """The project's `ui` globs; they replace the defaults when declared."""
    if config and project and Path(config).is_file():
        script = '. "$1/fm-config.sh"; fm_project_get "$2" ui "$3"'
        result = subprocess.run(['bash', '-c', script, '_', str(BIN), project, str(config)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError(result.stderr.strip() or 'cannot read the project ui globs')
        declared = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if declared:
            return declared
    return list(DEFAULT_UI)


def git(repo, *args, binary=False):
    result = subprocess.run(['git', '-C', str(repo), *args], stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError('git ' + ' '.join(args[:2]) + ' failed: ' + result.stderr.decode(errors='replace').strip())
    return result.stdout if binary else result.stdout.decode()


def changed(repo, base, head):
    out = git(repo, 'diff-tree', '-r', '-z', '--name-only', '--no-renames', base, head)
    return [p for p in out.split('\0') if p]


def ui_change(config, project, repo, base, head):
    globs = ui_globs(config, project)
    paths = ui_paths(changed(repo, base, head), globs)
    return dict(ui=bool(paths), paths=paths, globs=globs)


def breakpoints(css):
    """Each CSS width breakpoint's two edges: the last width before it and the first after."""
    edges = set()
    for kind, value in re.findall(r'\((min|max)-width\s*:\s*([0-9]+(?:\.[0-9]+)?)px\s*\)', css):
        n = int(float(value))
        edges.update((n - 1, n) if kind == 'min' else (n, n + 1))
    return sorted(e for e in edges if e > 0)


def viewports(kind, css=''):
    """(name, width, height) for every capture, without the colour scheme."""
    if kind == 'app':
        out = []
        for name, short, long in APP_DEVICES:
            out += [(f'{name}-portrait', short, long), (f'{name}-landscape', long, short)]
        return out
    widths = sorted(set(WEB_WIDTHS) | set(breakpoints(css)))
    return [(f'w{w}', w, WEB_HEIGHT) for w in widths]


def page_css(root, page_path):
    """The page's own styles: inline <style> blocks and local linked stylesheets."""
    path = Path(root) / page_path
    text = path.read_text(errors='replace') if path.is_file() else ''
    css = [text] if path.suffix != '.html' else re.findall(r'<style[^>]*>(.*?)</style>', text, re.S | re.I)
    for href in re.findall(r'<link[^>]+href=["\']([^"\':]+\.css)["\']', text, re.I):
        linked = (path.parent / href).resolve()
        if linked.is_file() and Path(root).resolve() in linked.parents:
            css.append(linked.read_text(errors='replace'))
    return '\n'.join(css)


def pages(spec, paths, globs):
    """Every page this change touches: the spec's design.pages, then each changed HTML page."""
    design = spec.get('design') if isinstance(spec.get('design'), dict) else {}
    found, seen = [], set()
    for entry in design.get('pages') or []:
        if isinstance(entry, dict) and isinstance(entry.get('path'), str) and entry['path'] not in seen:
            seen.add(entry['path'])
            found.append(dict(name=str(entry.get('name') or entry['path']), path=entry['path'],
                              prototype=entry.get('prototype')))
    for path in ui_paths(paths, globs):
        if path.endswith('.html') and path not in seen:
            seen.add(path)
            found.append(dict(name=path, path=path, prototype=None))
    for page in found:
        page['slug'] = SLUG.sub('-', page['path']).strip('-')
    return found


def prototype_dir(spec, engine_state):
    """The approved prototype folder, only under state/prototypes/."""
    design = spec.get('design') if isinstance(spec.get('design'), dict) else {}
    name = design.get('prototype')
    if not name:
        return None
    root = (Path(engine_state) / 'prototypes').resolve()
    folder = Path(name)
    folder = (folder if folder.is_absolute() else Path(engine_state).parent / folder).resolve()
    if root not in folder.parents and folder != root:
        raise CaptureError(f'design.prototype must be a folder under state/prototypes/, not {name}')
    if not folder.is_dir():
        raise CaptureError(f'the prototype folder {name} does not exist')
    return folder


def prototype_page(folder, page):
    for candidate in (page.get('prototype'), page['path'], Path(page['path']).name):
        if candidate and (Path(folder) / candidate).is_file():
            return Path(folder) / candidate
    if len(list(Path(folder).glob('*.html'))) == 1:
        return next(Path(folder).glob('*.html'))
    raise CaptureError(f'the prototype has no page for {page["path"]}')


def plan(page_list, kind, targets, out):
    """targets: [(label, root, resolver)] -> the shots the capture tool must write."""
    shots = []
    for page in page_list:
        for label, root, resolve in targets:
            source = resolve(root, page)
            if not Path(source).is_file():
                raise CaptureError(f'the {label} has no page {page["path"]}')
            css = page_css(Path(source).parent, Path(source).name)
            for name, width, height in viewports(kind, css):
                for scheme in SCHEMES:
                    shots.append(dict(page=page['path'], target=label, viewport=name, width=width,
                                      height=height, scheme=scheme, url=Path(source).resolve().as_uri(),
                                      file=f'{label}/{page["slug"]}-{name}-{scheme}.png'))
    return dict(out=str(Path(out).resolve()), shots=shots)


def apply_server(planned, server):
    """Expand only served head pages; prototype and file plans stay intact."""
    shots = []
    for shot in planned['shots']:
        served = server['pages'].get(shot['page']) if shot['target'] == 'head' else None
        if not served:
            shots.append(shot)
            continue
        for index, view in enumerate(served.get('views', [{}])):
            item = dict(shot, url=view.get('url', served['url']))
            for key in ('ready', 'click'):
                if view.get(key, served.get(key)):
                    item[key] = view.get(key, served.get(key))
            if 'name' in view:
                item['view'] = view['name']
                path = Path(shot['file'])
                item['file'] = str(path.with_name(f'{path.stem}-view-{index + 1}.png'))
            shots.append(item)
    planned['shots'] = shots


def capture_tool():
    configured = os.environ.get('FM_DESIGN_CAPTURE', '')
    if configured:
        return shlex.split(configured)
    runner = shutil.which('node') or shutil.which('bun')
    if not runner:
        raise CaptureError('no bun or node to run the page capture')
    return [runner, str(BIN / 'lib/fm-design-capture.mjs')]


def run_capture(planned, out, seconds=600):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / 'requests.json').unlink(missing_ok=True)
    (out / 'plan.json').write_text(json.dumps(planned, indent=1))
    try:
        result = subprocess.run([*capture_tool(), str(out / 'plan.json')], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=seconds)
    except (OSError, subprocess.SubprocessError) as error:
        raise CaptureError('the capture tool did not run: ' + str(error)) from error
    if result.returncode:
        said = (result.stderr or result.stdout).strip().splitlines()
        raise CaptureError(f'the capture tool exited {result.returncode}' + (': ' + '\n'.join(said[-30:]) if said else ''))
    missing = []
    for shot in planned['shots']:
        path = out / shot['file']
        try:
            ok = path.is_file() and path.read_bytes()[:8] == PNG
        except OSError:
            ok = False
        if not ok:
            missing.append(shot['file'])
    if missing:
        raise CaptureError(f'{len(missing)} of {len(planned["shots"])} screenshots are missing, first {missing[0]}')


def manifest(planned, task, head, kind, prototype):
    by_page = {}
    for shot in planned['shots']:
        row = by_page.setdefault(shot['page'], {})
        cell = row.setdefault((shot.get('view'), shot['viewport'], shot['scheme']),
                              dict(viewport=shot['viewport'], width=shot['width'], height=shot['height'],
                                   scheme=shot['scheme'], head=None, prototype=None))
        if 'view' in shot:
            cell['view'] = shot['view']
        cell[shot['target']] = shot['file']
    return dict(version=1, task=task, head=head, kind=kind, prototype=prototype,
                pages=[dict(page=page, shots=list(cells.values())) for page, cells in by_page.items()])


def export_tree(repo, head, into):
    """The head's files, from git objects; no worktree is created."""
    archive = git(repo, 'archive', '--format=tar', head, binary=True)
    with tempfile.TemporaryFile() as stream:
        stream.write(archive); stream.seek(0)
        with tarfile.open(fileobj=stream) as tar:
            members = [m for m in tar.getmembers() if not (m.issym() or m.islnk() or m.isdev())
                       and not m.name.startswith('/') and '..' not in Path(m.name).parts]
            safe = {'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}
            tar.extractall(into, members=members, **safe)


def capture(args):
    spec = json.loads(Path(args.spec).read_text())
    kind = (spec.get('design') or {}).get('kind') or 'web'
    globs = ui_globs(args.config, args.project)
    paths = [] if args.prototype_only else changed(args.repo, args.base, args.head)
    page_list = pages(spec, paths, globs)
    folder = Path(args.prototype).resolve() if args.prototype else prototype_dir(spec, args.state)
    if args.prototype_only and not folder:
        raise CaptureError('a prototype check needs a prototype folder')
    if args.prototype_only and not page_list:
        page_list = [dict(name=p.name, path=p.name, prototype=p.name, slug=SLUG.sub('-', p.name))
                     for p in sorted(folder.glob('*.html'))]
    if not page_list:
        raise CaptureError('no page to capture: name the pages in the spec design.pages')
    out = Path(args.out)
    with tempfile.TemporaryDirectory() as tree:
        targets = []
        if not args.prototype_only:
            export_tree(args.repo, args.head, tree)
            targets.append(('head', tree, lambda root, page: Path(root) / page['path']))
        if folder:
            targets.append(('prototype', folder, prototype_page))
        planned = plan(page_list, kind, targets, out)
        from fm_capture_server import capture_server
        with capture_server(tree) as server:
            if server:
                apply_server(planned, server)
            run_capture(planned, out)
    record = manifest(planned, args.task, args.head, kind, str(folder) if folder else None)
    requests = out / 'requests.json'
    if requests.is_file():
        record['capture'] = json.loads(requests.read_text())
    (out / 'manifest.json').write_text(json.dumps(record, indent=1))
    return record


def before_design_gate(code, repo, head):
    """Nothing is retroactive: a head committed before the engine gained this
    file keeps the path it had. Unknown history applies the gate."""
    try:
        since = git(code, 'log', '--diff-filter=A', '-1', '--format=%ct', '--', 'bin/lib/fm_design.py').strip()
        made = git(repo, 'log', '-1', '--format=%ct', head).strip()
        return bool(since) and int(made) < int(since)
    except (ValueError, OSError, subprocess.SubprocessError):
        return False


def design_gate(args):
    """0 when no design APPROVE is needed or one covers this exact head."""
    found = ui_change(args.config, args.project, args.repo, args.base, args.head)
    if not found['ui']:
        print('  lane design: not-needed (no path matches the ui globs)')
        return 0
    if before_design_gate(args.code, args.repo, args.head):
        print('  lane design: not-needed (head committed before the design gate shipped)')
        return 0
    sys.path.insert(0, str(BIN / 'lib'))
    from fm_evidence import Store, protocol
    records = Store(args.state, args.evidence_project, args.task).verdicts(lane='design')
    reason = ''
    if not records:
        reason = 'no design review exists'
    elif records[-1]['verdict'] != 'APPROVE':
        reason = 'the latest design review is a REJECT'
    elif not records[-1].get('signature'):
        reason = 'the design approval is unsigned'
    elif records[-1]['head'] != args.head:
        reason = 'the design approval covers another head'
    else:
        errors = protocol(records, args.task)
        reason = '; '.join(errors)
    if reason:
        print(f'  lane design: missing ({reason}; UI paths: {", ".join(found["paths"][:5])})')
        return 1
    print('  lane design: ok')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['ui', 'capture', 'gate'])
    parser.add_argument('--config', default='')
    parser.add_argument('--project', default='')
    parser.add_argument('--repo', default='.')
    parser.add_argument('--base', default='')
    parser.add_argument('--head', default='')
    parser.add_argument('--task', default='')
    parser.add_argument('--spec')
    parser.add_argument('--out')
    parser.add_argument('--state', default='state')
    parser.add_argument('--evidence-project', default='self')
    parser.add_argument('--prototype')
    parser.add_argument('--prototype-only', action='store_true')
    parser.add_argument('--code', default=str(BIN.parent))
    args = parser.parse_args()
    try:
        if args.command == 'ui':
            print(json.dumps(ui_change(args.config, args.project, args.repo, args.base, args.head)))
            return 0
        if args.command == 'gate':
            return design_gate(args)
        record = capture(args)
        print(f'captured {sum(len(p["shots"]) for p in record["pages"])} viewports on {len(record["pages"])} pages')
        return 0
    except CaptureError as error:
        print('fm-design: capture failed: ' + str(error), file=sys.stderr)
        return 65
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('fm-design: ' + str(error), file=sys.stderr)
        return 65


if __name__ == '__main__':
    sys.exit(main())
