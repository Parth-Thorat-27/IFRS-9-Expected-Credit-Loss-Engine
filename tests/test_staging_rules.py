"""Staging rules: PKG_STAGING.fn_assign_stage called through python-oracledb.

The function is pure, so each test passes chosen inputs and checks the
(stage, reason, cure counter) it returns. Thresholds come from the loaded XML
parameters (STAGE2_DPD 30, STAGE3_DPD 90, SICR 2.0x and +0.5 points, CURE_MONTHS 3).
"""
from __future__ import annotations

import pytest

from conftest import scalar


def stage(cur, dpd=0, status="Current", forbearance="N", pd_orig=0.02, pd_current=0.02,
          prev_stage=None, prev_cure=None):
    cur.execute("""
        SELECT t.d.stage, t.d.reason_code, t.d.cure_months
          FROM (SELECT pkg_staging.fn_assign_stage(:dpd, :status, :forbearance, :pd_orig, :pd_current,
                                                   :prev_stage, :prev_cure) AS d
                  FROM dual) t""",
                dpd=dpd, status=status, forbearance=forbearance, pd_orig=pd_orig,
                pd_current=pd_current, prev_stage=prev_stage, prev_cure=prev_cure)
    return cur.fetchone()


@pytest.mark.parametrize("dpd, expected", [
    (0, (1, "PERFORMING", 0)),
    (30, (1, "PERFORMING", 0)),     # 30 is not above the 30-day backstop
    (31, (2, "DPD_30", 0)),
    (90, (2, "DPD_30", 0)),         # 90 is not above the 90-day rule
    (91, (3, "DPD_90", 0)),
])
def test_dpd_boundaries(cur, dpd, expected):
    assert stage(cur, dpd=dpd) == expected


def test_default_status_is_stage_3_even_at_dpd_0(cur):
    assert stage(cur, dpd=0, status="Default") == (3, "DEFAULT_STATUS", 0)


def test_rules_are_checked_in_order(cur):
    # DPD above 90 and Default status: the first rule (DPD_90) gives the reason.
    assert stage(cur, dpd=120, status="Default") == (3, "DPD_90", 0)
    # DPD above 30 and forbearance: DPD_30 comes first.
    assert stage(cur, dpd=45, forbearance="Y") == (2, "DPD_30", 0)


def test_forbearance_is_stage_2(cur):
    assert stage(cur, forbearance="Y") == (2, "FORBEARANCE", 0)


@pytest.mark.parametrize("pd_orig, pd_current, expected_stage", [
    (0.10, 0.19, 1),    # ratio 1.9: below 2x, even though PD rose 9 points
    (0.006, 0.012, 2),  # ratio 2.0 with a 0.6-point increase: both tests met
    (0.002, 0.005, 1),  # ratio 2.5 but only a 0.3-point increase
])
def test_pd_deterioration_needs_both_relative_and_absolute_increase(cur, pd_orig, pd_current, expected_stage):
    result = stage(cur, pd_orig=pd_orig, pd_current=pd_current)
    assert result[0] == expected_stage
    assert result[1] == ("PD_DETERIORATION" if expected_stage == 2 else "PERFORMING")


def test_cure_takes_three_good_months(cur):
    month0 = stage(cur, dpd=45)                                           # delinquent: Stage 2
    assert month0 == (2, "DPD_30", 0)
    month1 = stage(cur, dpd=0, prev_stage=month0[0], prev_cure=month0[2])
    assert month1 == (2, "CURE_PROBATION", 1)                             # first good month
    month2 = stage(cur, dpd=0, prev_stage=month1[0], prev_cure=month1[2])
    assert month2 == (2, "CURE_PROBATION", 2)                             # second good month
    month3 = stage(cur, dpd=0, prev_stage=month2[0], prev_cure=month2[2])
    assert month3 == (1, "PERFORMING", 0)                                 # third: back to Stage 1


def test_relapse_during_probation_resets_the_cure_counter(cur):
    assert stage(cur, dpd=35, prev_stage=2, prev_cure=2) == (2, "DPD_30", 0)
    assert stage(cur, dpd=0, prev_stage=2, prev_cure=0) == (2, "CURE_PROBATION", 1)


def test_a_stage_3_loan_also_cures_through_probation(cur):
    assert stage(cur, dpd=0, prev_stage=3, prev_cure=0) == (2, "CURE_PROBATION", 1)


def test_explicit_thresholds_make_the_function_pure(cur):
    # The 12-argument version reads no tables: change a threshold, change the answer.
    sql = """SELECT t.d.stage FROM (SELECT pkg_staging.fn_assign_stage(
                 45, 'Current', 'N', 0.02, 0.02, NULL, NULL, :stage2_dpd, 90, 2, 0.005, 3) AS d FROM dual) t"""
    assert scalar(cur, sql, stage2_dpd=30) == 2
    assert scalar(cur, sql, stage2_dpd=60) == 1


def test_audit_rows_equal_stage_changes_from_the_second_month(cur):
    cur.execute("SELECT COUNT(DISTINCT reporting_date) FROM loan_stage_history")
    if cur.fetchone()[0] < 2:
        pytest.skip("fewer than two months staged")
    cur.execute("""
        SELECT h.reporting_date, h.changes, NVL(a.audit_rows, 0)
          FROM (SELECT reporting_date, SUM(CASE WHEN stage <> prev_stage THEN 1 ELSE 0 END) changes
                  FROM loan_stage_history GROUP BY reporting_date) h
          LEFT JOIN (SELECT reporting_date, COUNT(*) audit_rows FROM stage_change_audit
                      GROUP BY reporting_date) a ON a.reporting_date = h.reporting_date
         WHERE h.reporting_date > (SELECT MIN(reporting_date) FROM loan_stage_history)""")
    for reporting_date, changes, audit_rows in cur.fetchall():
        assert audit_rows == changes, f"{reporting_date:%Y-%m-%d}: {audit_rows} audit rows, {changes} changes"
