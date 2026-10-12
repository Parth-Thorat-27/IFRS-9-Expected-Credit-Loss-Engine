"""The single way every Python step reaches the database.

python-oracledb runs in thin mode by default: it speaks Oracle's network
protocol in pure Python, so the host needs no Oracle Instant Client. Only the
container has Oracle software installed.

Connection settings come from the same .env file that docker-compose and the
bash scripts read, so the three clients can't drift apart.
"""
from __future__ import annotations

import os
from pathlib import Path

import oracledb
from dotenv import load_dotenv

# python/ecl/db.py -> parents[2] is the repository root, where .env lives.
ROOT_DIR = Path(__file__).resolve().parents[2]


def _setting(name: str, default: str | None = None) -> str:
    value = os.getenv(name) or default
    if not value:
        raise RuntimeError(f"{name} is not set: copy .env.example to .env and fill it in")
    return value


def connect() -> oracledb.Connection:
    """Open a connection as the application user (ECL).

    Use it as a context manager so the connection always closes:
        with connect() as conn: ...
    """
    # override=False: a variable already set in the real environment wins,
    # which lets a CI job or a one-off run point somewhere else without editing .env.
    load_dotenv(ROOT_DIR / ".env", override=False)
    # Easy Connect syntax: host:port/service_name.
    dsn = (
        f"{_setting('ORACLE_HOST', 'localhost')}:"
        f"{_setting('ORACLE_PORT', '1521')}/"
        f"{_setting('ORACLE_SERVICE', 'FREEPDB1')}"
    )
    return oracledb.connect(
        user=_setting("APP_USER", "ECL"),
        password=_setting("APP_USER_PASSWORD"),
        dsn=dsn,
    )


def read_frame(conn: oracledb.Connection, sql: str, binds: dict | None = None):
    """Run a query and return a pandas DataFrame with lower-case column names."""
    import pandas as pd  # only the steps that need DataFrames pay for the import

    with conn.cursor() as cur:
        # Fetch 10,000 rows per round trip instead of the default 100.
        cur.arraysize = 10_000
        cur.execute(sql, binds or {})
        columns = [d[0].lower() for d in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=columns)


def get_setting(conn: oracledb.Connection, name: str) -> float:
    """A business setting from PARAM_SETTING (loaded from the XML config)."""
    with conn.cursor() as cur:
        return cur.callfunc("pkg_params.get_number", float, [name])
