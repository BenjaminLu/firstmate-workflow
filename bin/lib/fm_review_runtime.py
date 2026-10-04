"""Managed checkout ownership and final-answer readers for fm-review.sh."""
import sys


def network():
    import json
    print(" ".join(json.load(open(sys.argv[1]))["network"]))


def checkout_is_free():
    import importlib.util, pathlib, sys
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    try:
        states = m.executions(sys.argv[2])
        sys.exit(1 if any(s['state'] != 'terminated' for s in states) else 0)
    except (OSError, ValueError, KeyError):
        sys.exit(1)


def attempt_output():
    import importlib.util, os, pathlib, sys
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[1]) / 'bin/fm-herdr.py')
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    sys.stdout.write(m.review_final(sys.argv[2], sys.argv[3], os.environ))


if __name__ == '__main__':
    command = sys.argv.pop(1)
    {'checkout_is_free': checkout_is_free, 'attempt_output': attempt_output,
     'network': network}[command]()
