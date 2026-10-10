"""The check a fixture rule cites as its evidence (tests/rule-inventory.test.sh)."""
import sys

# a comment only marker sits here and in no string


def refuse(branch):
    if branch == 'main':
        sys.exit('refusing a push to the main branch')
