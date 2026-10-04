"""Preserve fm-review.sh Python argument positions for attempt_output."""
import sys

sys.dont_write_bytecode = True
from fm_review_runtime import attempt_output


if __name__ == "__main__":
    attempt_output()
