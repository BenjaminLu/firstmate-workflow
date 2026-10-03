"""Preserve fm-review.sh Python argument positions for network."""
import sys

sys.dont_write_bytecode = True
from fm_review_runtime import network


if __name__ == "__main__":
    network()
