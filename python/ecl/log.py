"""Logging set up the same way for every Python step.

The format matches log() in scripts/lib/common.sh, so a batch log reads as one
stream whether a line came from bash or from Python.
"""
from __future__ import annotations

import logging
import sys


def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stderr)
        handler.setFormatter(
            logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
        )
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        # Don't let the root logger print every line a second time.
        logger.propagate = False
    return logger
