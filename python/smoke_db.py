"""Phase 1 smoke test, Python side.

Connects from the host with python-oracledb in thin mode and prints the
database version and the connected user. scripts/smoke_test.sh runs it right
after the SQL*Plus check, so both client paths are proven together.

Usage: python python/smoke_db.py
"""
import oracledb

from ecl.db import connect


def main() -> None:
    with connect() as conn, conn.cursor() as cur:
        # BANNER_FULL spans two lines (product, then version); keep it on one.
        cur.execute("SELECT REPLACE(banner_full, CHR(10), ' | ') FROM v$version")
        (banner,) = cur.fetchone()
        cur.execute("SELECT USER, SYS_CONTEXT('USERENV', 'CON_NAME') FROM dual")
        user, container = cur.fetchone()
        mode = "thin" if conn.thin else "thick"

    print(f"database version : {banner}")
    print(f"connected user   : {user}")
    print(f"container (PDB)  : {container}")
    print(f"client           : python-oracledb {oracledb.__version__}, {mode} mode")


if __name__ == "__main__":
    main()
