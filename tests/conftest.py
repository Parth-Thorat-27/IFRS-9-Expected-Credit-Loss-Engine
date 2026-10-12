"""Shared pytest setup: import path for the ecl package and a database connection.

Most tests talk to the running Oracle container (docker compose up -d) as ECL,
the same way the Python steps do.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from ecl.db import connect  # noqa: E402  (needs the path above)


@pytest.fixture(scope="session")
def conn():
    with connect() as connection:
        yield connection


@pytest.fixture
def cur(conn):
    with conn.cursor() as cursor:
        yield cursor


def scalar(cur, sql: str, **binds):
    """First column of the first row."""
    cur.execute(sql, binds)
    row = cur.fetchone()
    return row[0] if row else None
