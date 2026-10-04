"""Preserve fm-review.sh Python argument positions for checkout_is_free."""
import sys

sys.dont_write_bytecode = True
from fm_review_runtime import checkout_is_free


if __name__ == "__main__":
    checkout_is_free()
