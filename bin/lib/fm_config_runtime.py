"""Config runtime helpers extracted from fm-config.sh."""

import sys


def identity():
    import json, pathlib, sys
    run, pid, code = sys.argv[1:]
    p = pathlib.Path(run)
    identity = json.loads((p / 'identity.json').read_text())
    process = p / 'process.json'
    launcher = json.loads(process.read_text()) if process.exists() else {}
    temporary = p / ('process.' + pid + '.tmp')
    temporary.write_text(json.dumps(dict(identity, **({'owner_record': launcher['owner_record']}
        if launcher.get('owner_record') else {}), pid=int(pid), token=code, snapshot=code)))
    temporary.replace(process)


def record_end():
    import importlib.util, json, pathlib, sys
    spec = importlib.util.spec_from_file_location('managed', pathlib.Path(sys.argv[3]) / 'bin/fm-herdr.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    run = pathlib.Path(sys.argv[1])
    identity = json.loads((run / 'identity.json').read_text())
    last = run / 'last-result.json'
    result = json.loads(last.read_text()) if last.exists() else {}
    if not sys.argv[4] or result.get('chain_attempt') != sys.argv[4]:
        result = dict(status='unknown', chain_attempt=sys.argv[4], vendor=sys.argv[5])
    module.save(run / 'orchestration-result.json', dict(identity, process_exit=int(sys.argv[2]), adapter_result=result))


def vendor_resolution():
    import json, os, sys, tempfile
    from pathlib import Path
    path = Path(sys.argv[1])
    data = json.loads(path.read_text())
    data['vendor_resolution'] = dict(host=sys.argv[2] or None, rule=sys.argv[3], vendor=sys.argv[4])
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.vendor-')
    try:
        with os.fdopen(fd, 'w') as stream: json.dump(data, stream)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def vendor_model():
    import json, re, sys
    requested = sys.argv[1]
    usage, said = None, None
    decoder = json.JSONDecoder()
    for line in sys.stdin.read().splitlines():
        for f in re.finditer(r"\"model\"\s*:\s*\"([^\"]*)\"", line): said = f.group(1)
        start = line.find("{")
        while start != -1:
            try: obj, end = decoder.raw_decode(line, start)
            except ValueError: start = line.find("{", start + 1); continue
            if isinstance(obj, dict) and isinstance(obj.get("modelUsage"), dict) and obj["modelUsage"]:
                usage = obj["modelUsage"]
            start = line.find("{", end)
    def out_tokens(v):
        n = v.get("outputTokens") if isinstance(v, dict) else None
        return n if isinstance(n, (int, float)) else 0
    if usage:
        keys = list(usage)
        print(requested if requested in keys else max(keys, key=lambda k: out_tokens(usage[k])))
    elif said: print(said)


def private_stage():
    import os, sys
    paths = sys.stdin.buffer.read().split(b"\0")
    bad = [os.fsdecode(p) for p in paths if any(part.startswith(b".fm-") for part in p.split(b"/"))]
    if bad:
        print("fm: private artifacts cannot be committed: " + repr(bad), file=sys.stderr)
        sys.exit(65)

    from pathlib import Path
    import subprocess
    design = os.environ.get('FM_DESIGN')
    if len(sys.argv) < 2 or not design:
        return
    try:
        source = Path(design)
        if not source.is_file():
            return
        private = source.read_bytes()
    except OSError:
        return
    copies = []
    for path in paths:
        if not path:
            continue
        try:
            result = subprocess.run(['git', '-C', sys.argv[1], 'cat-file', 'blob', ':' + os.fsdecode(path)],
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0 and result.stdout == private:
            copies.append(os.fsdecode(path))
    if copies:
        print("fm: the private design.md cannot be committed: " + repr(copies), file=sys.stderr)
        sys.exit(65)


def attempt_id():
    import uuid; print(uuid.uuid4().hex)


def main():
    command = sys.argv.pop(1)
    commands = {
        'identity': identity,
        'record-end': record_end,
        'vendor-resolution': vendor_resolution,
        'vendor-model': vendor_model,
        'private-stage': private_stage,
        'attempt-id': attempt_id,
    }
    commands[command]()


if __name__ == "__main__":
    main()
