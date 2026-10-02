"""Retain external notes locally; projection is a separate policy choice."""
import os
from pathlib import Path
import re
import sys
import time


def retain(state, kind, task, source):
    if not re.fullmatch(r'[a-z-]+', kind) or not re.fullmatch(r'[A-Za-z0-9-]+', task):
        raise ValueError('invalid note identity')
    directory=Path(state)/'notes'/task
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    path=directory/(kind+'-'+str(time.time_ns())+'.md')
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as out: out.write(Path(source).read_text())
    return path


if __name__ == '__main__':
    try: print(retain(*sys.argv[1:]))
    except (OSError,ValueError) as error:
        print('fm-note: '+str(error),file=sys.stderr); sys.exit(65)
