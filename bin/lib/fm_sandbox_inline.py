"""Carry a module into confinement without changing its -c payload arguments."""
from pathlib import Path
import sys


def inline_program(source, filename):
    # repr quotes arbitrary source and paths as data. The compiled program
    # sees the same sys.argv as the old -c heredoc, including argv[0] == '-c'.
    return f'exec(compile({source!r}, {filename!r}, "exec"))'


def main():
    filename = sys.argv[1]
    print(inline_program(Path(filename).read_text(), filename))


if __name__ == '__main__':
    main()
