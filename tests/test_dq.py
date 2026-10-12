"""Data quality: every bad row is caught by the right rule, nothing rejected
reaches LOAN_SNAPSHOT, accepted plus rejected equals received, a re-run gives
identical counts, and a truncated file fails control reconciliation.

Two kinds of evidence:
  - the simulator's seeded errors in the real monthly files (for every month
    the batch has already checked), compared with DQ_ERROR;
  - a hand-made file for an out-of-range date (2000-01-31) that breaks each
    of the 12 rules exactly once at a known row. The test writes it into
    data/incoming, runs the real PL/SQL steps, and removes it afterwards.
"""
from __future__ import annotations

import csv
from datetime import date
from pathlib import Path

import oracledb
import pandas as pd
import pytest

from conftest import ROOT, scalar

INCOMING = ROOT / "data" / "incoming"
PROCESSED = ROOT / "data" / "processed"
TEST_DATE = date(2000, 1, 31)
TRUNCATED_DATE = date(2000, 2, 29)
HEADER = ["reporting_date", "loan_id", "loan_status", "dpd", "balance", "current_fico",
          "forbearance_flag", "remaining_months", "data_source"]


# ----------------------------------------------------------------- helpers
def new_run_id(cur) -> int:
    return cur.callfunc("pkg_batch_log.new_run_id", int)


def run_steps(cur, reporting_date: date, through: str = "load_clean") -> int:
    run_id = new_run_id(cur)
    steps = ["pkg_load.load_snapshot", "pkg_dq.reconcile_control", "pkg_dq.run_checks", "pkg_load.load_clean"]
    for proc in steps[: [s.split(".")[1] for s in steps].index(through) + 1]:
        cur.callproc(proc, [reporting_date, run_id])
    return run_id


def write_files(rows: list[list[str]], reporting_date: date, control_rows: int | None = None,
                control_total: float | None = None) -> list[Path]:
    stamp = f"{reporting_date:%Y%m%d}"
    snapshot, control = INCOMING / f"loan_snapshot_{stamp}.csv", INCOMING / f"control_{stamp}.csv"
    with open(snapshot, "w", encoding="utf-8", newline="\n") as f:
        csv.writer(f, lineterminator="\n").writerows([HEADER, *rows])
    total = sum(round(float(r[4]) * 100) for r in rows) / 100
    control.write_text(f"reporting_date,row_count,total_balance\n{reporting_date:%Y-%m-%d},"
                       f"{control_rows if control_rows is not None else len(rows)},"
                       f"{control_total if control_total is not None else total:.2f}\n",
                       encoding="utf-8", newline="\n")
    return [snapshot, control]


def purge(cur, conn, reporting_date: date) -> None:
    cur.callfunc("pkg_load.purge_date", int, [reporting_date])
    conn.commit()


# One known row per rule. Positions are 1-based lines after the header.
INJECTED = {
    11: "DQ001", 22: "DQ002", 33: "DQ003", 44: "DQ004", 55: "DQ005", 66: "DQ006",
    77: "DQ007", 88: "DQ008", 99: "DQ009", 110: "DQ010", 121: "DQ011", 132: "DQ012",
}
WARN_RULES = {"DQ008", "DQ009"}


def handmade_rows() -> list[list[str]]:
    """2,000 real loans from the live book, valid in every field, then one break per rule."""
    base = pd.read_csv(PROCESSED / "portfolio_base.csv", nrows=2000,
                       usecols=["loan_id", "loan_status", "dpd", "balance", "remaining_months",
                                "funded_amnt"])
    rows = [[f"{TEST_DATE:%Y-%m-%d}", str(r.loan_id), r.loan_status, str(r.dpd), f"{r.balance:.2f}",
             "700", "N", str(r.remaining_months), "SIMULATED"] for r in base.itertuples()]
    funded = base["funded_amnt"].tolist()
    rows.insert(32, list(rows[31]))                     # line 33 repeats line 32 -> DQ003
    funded.insert(32, funded[31])

    def at(line: int) -> list[str]:
        return rows[line - 1]
    at(11)[1] = ""                                       # DQ001 missing loan id
    at(22)[1] = "ABC123"                                 # DQ002 loan id not a number
    at(44)[1] = "900000999"                              # DQ004 not in LOAN_MASTER
    at(55)[4] = "-5.00"                                  # DQ005 negative balance
    at(66)[4] = f"{funded[65] + 1:.2f}"                  # DQ006 above funded amount
    at(77)[3] = "x"                                      # DQ007 DPD not a number
    at(88)[5] = "950"                                    # DQ008 FICO out of range (warn)
    at(99)[6] = "Q"                                      # DQ009 bad forbearance flag (warn)
    at(110)[0] = "2000-01-30"                            # DQ010 wrong reporting date
    at(121)[7] = "0"                                     # DQ011 no remaining term
    at(132)[8] = "MANUAL"                                # DQ012 unknown data source
    return rows


@pytest.fixture(scope="module")
def handmade(conn):
    """Load the hand-made file through the real steps; clean everything up afterwards."""
    rows = handmade_rows()
    files = write_files(rows, TEST_DATE)
    with conn.cursor() as cur:
        try:
            run_steps(cur, TEST_DATE)
            yield rows
        finally:
            purge(cur, conn, TEST_DATE)
            for f in files:
                f.unlink(missing_ok=True)


# ----------------------------------------------------------------- the real monthly files
def checked_dates(cur) -> list[date]:
    cur.execute("""SELECT DISTINCT reporting_date FROM batch_run
                    WHERE step_name = 'DQ_CHECKS' AND status = 'SUCCESS'
                      AND reporting_date > DATE '2010-01-01' ORDER BY 1""")
    return [r[0].date() for r in cur.fetchall()]


def test_every_seeded_error_is_caught_by_the_right_rule(cur):
    dates = [d for d in checked_dates(cur) if (PROCESSED / f"seeded_errors_{d:%Y%m%d}.csv").exists()]
    if not dates:
        pytest.skip("no monthly file has been through the DQ checks yet")
    total = 0
    for d in dates:
        manifest = pd.read_csv(PROCESSED / f"seeded_errors_{d:%Y%m%d}.csv")
        cur.execute("SELECT row_num, rule_id FROM dq_error WHERE reporting_date = :d", d=d)
        caught = set(cur.fetchall())
        missing = [(r.row_num, r.expected_rule) for r in manifest.itertuples()
                   if (r.row_num, r.expected_rule) not in caught]
        assert not missing, f"{d}: seeded errors not caught by the expected rule: {missing[:5]}"
        total += len(manifest)
    assert total > 0


def test_accepted_plus_rejected_equals_received_every_month(cur):
    cur.execute("""
        SELECT s.reporting_date, s.received, NVL(r.rejected, 0), NVL(c.accepted, 0)
          FROM (SELECT reporting_date, COUNT(*) received FROM stg_loan_snapshot GROUP BY reporting_date) s
          LEFT JOIN (SELECT reporting_date, COUNT(DISTINCT row_num) rejected FROM dq_error
                      WHERE severity = 'REJECT' GROUP BY reporting_date) r ON r.reporting_date = s.reporting_date
          LEFT JOIN (SELECT reporting_date, COUNT(*) accepted FROM loan_snapshot
                      GROUP BY reporting_date) c ON c.reporting_date = s.reporting_date""")
    rows = cur.fetchall()
    if not rows:
        pytest.skip("nothing staged yet")
    for reporting_date, received, rejected, accepted in rows:
        assert accepted + rejected == received, f"{reporting_date:%Y-%m-%d}: {accepted} + {rejected} != {received}"


def test_no_rejected_row_reaches_loan_snapshot(cur):
    assert scalar(cur, """SELECT COUNT(*) FROM loan_snapshot l
                            JOIN dq_error e ON e.reporting_date = l.reporting_date
                                           AND e.row_num = l.source_row_num
                                           AND e.severity = 'REJECT'""") == 0


# ----------------------------------------------------------------- the hand-made file
def test_each_rule_catches_exactly_its_row(cur, handmade):
    cur.execute("SELECT row_num, rule_id FROM dq_error WHERE reporting_date = :d", d=TEST_DATE)
    assert sorted(cur.fetchall()) == sorted(INJECTED.items())


def test_rejected_rows_are_kept_out_and_warnings_are_fixed(cur, handmade):
    received = len(handmade)
    rejects = len([r for r in INJECTED.values() if r not in WARN_RULES])
    assert scalar(cur, "SELECT COUNT(*) FROM loan_snapshot WHERE reporting_date = :d", d=TEST_DATE) == received - rejects
    cur.execute("SELECT source_row_num FROM loan_snapshot WHERE reporting_date = :d", d=TEST_DATE)
    loaded = {r[0] for r in cur.fetchall()}
    assert not loaded & {n for n, rule in INJECTED.items() if rule not in WARN_RULES}
    # DQ008: invalid FICO loaded as null (scoring falls back to origination FICO).
    assert scalar(cur, "SELECT current_fico FROM loan_snapshot WHERE reporting_date = :d AND source_row_num = 88",
                  d=TEST_DATE) is None
    # DQ009: invalid forbearance flag loaded as N.
    assert scalar(cur, "SELECT forbearance_flag FROM loan_snapshot WHERE reporting_date = :d AND source_row_num = 99",
                  d=TEST_DATE) == "N"


def test_bad_values_are_recorded_with_the_error(cur, handmade):
    cur.execute("SELECT rule_id, bad_value FROM dq_error WHERE reporting_date = :d", d=TEST_DATE)
    values = dict(cur.fetchall())
    assert values["DQ002"] == "ABC123" and values["DQ005"] == "-5.00" and values["DQ007"] == "x"
    assert values["DQ001"] is None  # the missing value itself


def test_running_the_same_date_twice_gives_identical_counts(cur, handmade):
    def counts():
        return (scalar(cur, "SELECT COUNT(*) FROM stg_loan_snapshot WHERE reporting_date = :d", d=TEST_DATE),
                scalar(cur, "SELECT COUNT(*) FROM dq_error WHERE reporting_date = :d", d=TEST_DATE),
                scalar(cur, "SELECT COUNT(*) FROM loan_snapshot WHERE reporting_date = :d", d=TEST_DATE),
                scalar(cur, "SELECT SUM(balance) FROM loan_snapshot WHERE reporting_date = :d", d=TEST_DATE))
    first = counts()
    run_steps(cur, TEST_DATE)
    assert counts() == first
    assert scalar(cur, """SELECT COUNT(*) - COUNT(DISTINCT loan_id) FROM loan_snapshot
                           WHERE reporting_date = :d""", d=TEST_DATE) == 0


def test_truncated_file_fails_control_reconciliation(conn, cur, handmade):
    # Copy the month, drop its last 10 lines, keep the original control totals.
    full_total = sum(round(float(r[4]) * 100) for r in handmade) / 100
    files = write_files(handmade[:-10], TRUNCATED_DATE, control_rows=len(handmade), control_total=full_total)
    try:
        with pytest.raises(oracledb.DatabaseError, match="ORA-20030"):
            run_steps(cur, TRUNCATED_DATE, through="reconcile_control")
        cur.execute("""SELECT status, message FROM batch_run
                        WHERE reporting_date = :d AND step_name = 'RECONCILE_CONTROL'
                        ORDER BY batch_run_id DESC FETCH FIRST 1 ROW ONLY""", d=TRUNCATED_DATE)
        status, message = cur.fetchone()
        assert status == "FAILED"
        assert "10 rows missing" in message and "never force the load" in message
        # The batch can't carry on: the next step refuses to run on unreconciled data.
        with pytest.raises(oracledb.DatabaseError, match="ORA-20005"):
            cur.callproc("pkg_dq.run_checks", [TRUNCATED_DATE, new_run_id(cur)])
    finally:
        purge(cur, conn, TRUNCATED_DATE)
        for f in files:
            f.unlink(missing_ok=True)
