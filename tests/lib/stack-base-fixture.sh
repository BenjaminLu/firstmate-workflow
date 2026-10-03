# shellcheck shell=bash
# fm:sourced
# Lifecycle suites own launch/report behavior; stacking.test.sh owns base lookup.
stack_base_fixture() {
  mv "$1/lib/fm_stack.py" "$1/lib/fm_stack_real.py"
  cat > "$1/lib/fm_stack.py" <<'PYTHON'
import sys
from fm_stack_real import *
if __name__ == '__main__':
    if sys.argv[1] == 'base':
        print('main')
    else:
        main()
PYTHON
  # The service's repository is fixed alongside its base for these fixtures.
  cat >> "$1/lib/fm-stack.sh" <<'SHELL'
fm_stack_repository() { echo fixture/project; }
SHELL
}
