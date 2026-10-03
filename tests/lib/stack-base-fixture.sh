# shellcheck shell=bash
# fm:sourced
# Lifecycle suites isolate base discovery; stacking-binding.test.sh uses real refs.
stack_base_fixture() {
  mv "$1/lib/fm_binding.py" "$1/lib/fm_binding_prior.py"
  cat > "$1/lib/fm_binding.py" <<'PYTHON'
from fm_binding_prior import *
if __name__ == '__main__':
    import sys, runpy
    from pathlib import Path
    if sys.argv[1] == 'base':
        print('main')
    else:
        runpy.run_path(str(Path(__file__).with_name('fm_binding_prior.py')), run_name='__main__')
PYTHON
}
