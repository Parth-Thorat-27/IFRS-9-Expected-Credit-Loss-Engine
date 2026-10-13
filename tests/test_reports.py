"""The report views reconcile, and the published reports carry their numbers.

- V_ECL_MOVEMENT: opening ECL plus every movement equals closing ECL for every
  stage and month, to the cent, and the walk opens and closes at the ECL the
  reports show for the two months.
- V_STAGE_MIGRATION: row totals are last month's loans by stage, column totals
  this month's.
- Every processed month has its CSV exports and HTML report, and the latest
  report has data in every section.
"""
from __future__ import annotations

import csv
from decimal import Decimal

import pandas as pd
import pytest
from lxml import html

from conftest import ROOT, scalar
from ecl.db import read_frame

VIEW_EXPORTS = ["ecl_by_stage", "ecl_by_grade", "ecl_by_state", "stage_migration", "ecl_movement",
                "floor_impact", "scenario_sensitivity", "dq_summary"]
SECTIONS = ["headline", "trend", "migration", "movement", "floors", "scenarios", "dq"]
# The tests' own made-up dates are in 2000; the real months start in 2019.
REAL_MONTHS = "reporting_date > DATE '2010-01-01'"


@pytest.fixture(scope="module")
def months(conn) -> list:
    with conn.cursor() as cur:
        cur.execute(f"SELECT DISTINCT reporting_date FROM ecl_result WHERE {REAL_MONTHS} ORDER BY 1")
        found = [row[0] for row in cur]
    if not found:
        pytest.skip("no month has been processed yet (run scripts/run_all_months.sh)")
    return found


def money(cur, sql: str, **binds) -> Decimal:
    """An exact amount: fetched as text, so no float rounding gets in."""
    return Decimal(scalar(cur, f"SELECT TO_CHAR(({sql}), 'FM999999999990.00') FROM dual", **binds))


def test_ecl_movement_reconciles_to_the_cent_for_every_stage_and_month(cur, months):
    assert scalar(cur, f"SELECT COUNT(DISTINCT reporting_date) FROM v_ecl_movement WHERE {REAL_MONTHS}") == len(months)
    assert scalar(cur, f"SELECT MAX(ABS(difference)) FROM v_ecl_movement WHERE {REAL_MONTHS}") == 0


def test_ecl_movement_opens_at_last_months_ecl_and_closes_at_this_months(cur, months):
    # DIFFERENCE is zero by construction, whatever loans the view joins. This
    # proves the walk covers the whole book: it opens at the ECL reported for
    # the previous month and closes at the ECL reported for this one.
    off = scalar(cur, """
        SELECT COUNT(*) FROM v_ecl_movement m
          LEFT JOIN v_ecl_by_stage c ON c.reporting_date = m.reporting_date AND c.stage = m.stage
          LEFT JOIN v_ecl_by_stage o ON o.reporting_date = m.prev_date AND o.stage = m.stage
         WHERE m.reporting_date > DATE '2010-01-01'
           AND (m.closing_ecl <> NVL(c.ecl_final, 0) OR m.opening_ecl <> NVL(o.ecl_final, 0))""")
    unwalked = scalar(cur, f"""
        SELECT COUNT(*) FROM v_ecl_by_stage b
         WHERE b.{REAL_MONTHS}
           AND NOT EXISTS (SELECT 1 FROM v_ecl_movement m
                            WHERE m.reporting_date = b.reporting_date AND m.stage = b.stage)""")
    assert off == 0
    assert unwalked == 0


def loans_by_stage(counts: pd.DataFrame, day) -> dict:
    return counts[counts.reporting_date == day].set_index("stage").loans.to_dict()


def test_stage_migration_totals_match_the_two_months_loan_counts(conn, months):
    counts = read_frame(conn, f"""SELECT reporting_date, TO_CHAR(stage) AS stage, COUNT(*) AS loans
                                    FROM ecl_result WHERE {REAL_MONTHS} GROUP BY reporting_date, stage""")
    mig = read_frame(conn, f"SELECT * FROM v_stage_migration WHERE {REAL_MONTHS}")

    first = mig[mig.prev_date.isna()]
    assert first.from_stage.eq("NEW").all(), "in the first month every loan is new"
    assert first.groupby("to_stage").loans.sum().to_dict() == loans_by_stage(counts, months[0])

    later = mig[mig.prev_date.notna()]
    assert sorted(later.reporting_date.unique()) == [pd.Timestamp(m) for m in months[1:]]
    for (closing, opening), month in later.groupby(["reporting_date", "prev_date"]):
        rows = month[month.from_stage != "NEW"].groupby("from_stage").loans.sum().to_dict()
        columns = month[month.to_stage != "EXITED"].groupby("to_stage").loans.sum().to_dict()
        assert rows == loans_by_stage(counts, opening), f"row totals for {closing:%Y-%m}"
        assert columns == loans_by_stage(counts, closing), f"column totals for {closing:%Y-%m}"


def test_every_month_has_its_csv_exports_and_html_report(months):
    expected = [f"{view}.csv" for view in VIEW_EXPORTS] + ["ecl_detail.csv", "ecl_report.html"]
    for month in months:
        folder = ROOT / "reports" / f"{month:%Y%m%d}"
        missing = [name for name in expected if not (folder / name).is_file()]
        assert not missing, f"reports/{folder.name}/ is missing {missing}"


def test_detail_export_matches_the_database(cur, months):
    latest = months[-1]
    with (ROOT / "reports" / f"{latest:%Y%m%d}" / "ecl_detail.csv").open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == scalar(cur, "SELECT COUNT(*) FROM ecl_result WHERE reporting_date = :d", d=latest)
    assert sum(Decimal(r["ECL_FINAL"]) for r in rows) == money(
        cur, "SELECT SUM(ecl_final) FROM ecl_result WHERE reporting_date = :d", d=latest)


def test_latest_html_report_has_data_in_every_section(cur, months):
    latest = months[-1]
    page = html.parse(str(ROOT / "reports" / f"{latest:%Y%m%d}" / "ecl_report.html")).getroot()

    for key in SECTIONS:
        found = page.xpath(f'//section[@data-section="{key}"]')
        assert len(found) == 1, f"section '{key}' is missing"
        figures = [cell.text_content() for cell in found[0].xpath('.//td | .//div[@class="tile-value"]')]
        assert any(ch.isdigit() for text in figures for ch in text), f"section '{key}' has no figures"

    # Both trend charts are drawn, with one point per month on the coverage lines.
    trend = page.xpath('//section[@data-section="trend"]')[0]
    assert len(trend.xpath(".//svg")) == 2
    assert all(len(line.get("points").split()) == len(months) for line in trend.xpath(".//polyline"))

    # The numbers are the database's: the loan count tile, and the movement
    # table's closing ECL and all-zero check row.
    tiles = dict(zip(page.xpath('//div[@class="tile-label"]/text()'), page.xpath('//div[@class="tile-value"]/text()')))
    loans = scalar(cur, "SELECT COUNT(*) FROM ecl_result WHERE reporting_date = :d", d=latest)
    assert tiles["Loans on the book"] == f"{loans:,}"

    movement = {tr[0].text_content(): [td.text_content() for td in tr[1:]]
                for tr in page.xpath('//section[@data-section="movement"]//tbody/tr')}
    closing = money(cur, "SELECT SUM(ecl_final) FROM ecl_result WHERE reporting_date = :d", d=latest)
    assert movement["Closing ECL"][-1] == f"{closing:,.2f}"
    assert set(movement["Check: opening + movements − closing"]) == {"0.00"}

    dq_rows = page.xpath('//section[@data-section="dq"]//tbody/tr')
    assert len(dq_rows) == scalar(cur, "SELECT COUNT(*) FROM v_dq_summary WHERE reporting_date = :d", d=latest)
