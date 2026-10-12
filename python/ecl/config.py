"""Paths and non-business settings (config/settings.json).

Business assumptions (thresholds, scenario weights, floors) are not here: they
live in config/ecl_parameters.xml and are read from the database after
PKG_PARAMS has loaded them, so Python and PL/SQL always use the same values.
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[2]
CONFIG_DIR = ROOT_DIR / "config"
DATA_DIR = ROOT_DIR / "data"
RAW_DIR = DATA_DIR / "raw"
PROCESSED_DIR = DATA_DIR / "processed"
INCOMING_DIR = DATA_DIR / "incoming"
MODELS_DIR = ROOT_DIR / "models"
REPORTS_DIR = ROOT_DIR / "reports"
DOCS_DIR = ROOT_DIR / "docs"

DEFAULT_SETTINGS = CONFIG_DIR / "settings.json"


def load_settings(path: str | Path | None = None) -> dict:
    """Read settings.json (or the file given with --config)."""
    with open(path or DEFAULT_SETTINGS, encoding="utf-8") as f:
        return json.load(f)
