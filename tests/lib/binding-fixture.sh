# shellcheck shell=bash
# fm:sourced
# Orchestration fixtures replace the evidence service; evidence-binding.test.sh
# exercises its real implementation. Never install this in a production tree.
binding_service_fixture() {
  mkdir -p "$1/bin/lib"
  cp "$ROOT/bin/lib/fm_binding.py" "$1/bin/lib/fm_binding_real.py"
  cat > "$1/bin/lib/fm_binding.py" <<'PY'
from fm_binding_real import source_binding, git
if __name__ == "__main__":
    import argparse, json, os, re, subprocess
    p=argparse.ArgumentParser()
    p.add_argument('mode'); p.add_argument('--task'); p.add_argument('--pr')
    p.add_argument('--gate-report',default='')
    p.add_argument('--head', default=''); p.add_argument('--branch', default='')
    a=p.parse_args()
    if a.mode == 'head':
        r=subprocess.run(['git','-C',os.environ['FM_TARGET_ROOT'],'rev-parse',a.branch],capture_output=True,text=True)
        head=r.stdout.strip()
        print(head if re.fullmatch('[0-9a-f]{40}',head) else 'a'*40)
    elif a.mode in ('checks','ready'):
        from pathlib import Path
        if os.environ.get('GHSTATE') and (Path(os.environ['GHSTATE'])/'red').exists():raise SystemExit(1)
        print('{}')
    elif a.mode == 'candidate':
        if not re.fullmatch('[0-9a-f]{40}',a.head):raise SystemExit(1)
        print(json.dumps(dict(head=a.head,task=a.task,pr=int(a.pr),gates=[1,2,4,5,6,7],signature='fixture')))

PY
}
