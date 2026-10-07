# shellcheck shell=bash
# fm:sourced
# Orchestration fixtures replace the evidence service; evidence-binding.test.sh
# exercises its real implementation. Never install this in a production tree.
binding_service_fixture() {
  mkdir -p "$1/bin/lib"
  cp "$ROOT/bin/lib/fm_gates.json" "$1/bin/lib/"
  cp "$ROOT/bin/lib/fm_binding.py" "$1/bin/lib/fm_binding_real.py"
  cat > "$1/bin/lib/fm_binding.py" <<'PY'
from fm_binding_real import gate_list, gate_entry, source_binding, git, command, github, remote_head, sha, repository
def fetch_ref(*args, **kwargs):
    from fm_binding_real import fetch_ref as fetch
    return fetch(*args, **kwargs)

if __name__ == "__main__":
    import argparse, json, os, re, subprocess, sys, runpy
    from pathlib import Path
    # Keep modes outside this fixture's overrides on the production parser.
    if len(sys.argv) > 1 and sys.argv[1] not in ('head', 'base', 'checks', 'ready', 'candidate', 'review-final'):
        runpy.run_path(str(Path(__file__).with_name('fm_binding_real.py')), run_name='__main__')
        raise SystemExit(0)
    p=argparse.ArgumentParser()
    p.add_argument('mode'); p.add_argument('--task'); p.add_argument('--pr')
    p.add_argument('--gate-report',default='')
    p.add_argument('--head', default=''); p.add_argument('--branch', default='')
    p.add_argument('--base-name', default='')
    a=p.parse_args()
    root=Path(os.environ['FM_TARGET_ROOT'])
    base_file=root/'.fixture-pr-base'
    base=base_file.read_text().strip() if base_file.exists() else os.environ.get('FM_BASE', 'main')
    if a.mode in ('head', 'review-final'):
        r=subprocess.run(['git','-C',os.environ['FM_TARGET_ROOT'],'rev-parse',a.branch],capture_output=True,text=True)
        head=r.stdout.strip()
        if a.mode == 'review-final':
            reason = ('PR is not open' if (root/'.fixture-pr-closed').exists() else
                      'base name differs from reviewed base' if base != a.base_name else
                      'local task ref differs from reviewed head' if r.returncode or head != a.head else '')
            if reason:
                print('fm-binding: ' + reason, file=sys.stderr)
                raise SystemExit(1)
        print(head if re.fullmatch('[0-9a-f]{40}',head) else 'a'*40)
    elif a.mode == 'base':
        print(base)
    elif a.mode in ('checks','ready'):
        from pathlib import Path
        if os.environ.get('GHSTATE') and (Path(os.environ['GHSTATE'])/'red').exists():raise SystemExit(1)
        print('{}')
    elif a.mode == 'candidate':
        if not re.fullmatch('[0-9a-f]{40}',a.head):raise SystemExit(1)
        print(json.dumps(dict(head=a.head,task=a.task,pr=int(a.pr),gates=[g['name'] for g in json.loads(Path(__file__).with_name('fm_gates.json').read_text())['gates']],signature='fixture')))

PY
}
