"""run_v1 (row by row, exact NUMBER arithmetic) and run_v2 (set-based,
BINARY_DOUBLE arithmetic) must agree to the cent on a full month.

Runs both engines on the latest staged month, so it takes a few seconds per
engine. The month's ECL_RESULT is rewritten with identical values (the engine
is deterministic).
"""
import pytest

from conftest import scalar


def test_v1_and_v2_agree_to_the_cent_on_a_full_month(cur):
    month = scalar(cur, "SELECT MAX(reporting_date) FROM loan_stage_history WHERE reporting_date > DATE '2010-01-01'")
    if month is None:
        pytest.skip("no month has been staged yet")
    run_id = cur.callfunc("pkg_batch_log.new_run_id", int)
    cur.callproc("pkg_ecl.run_v2", [month, run_id])
    cur.callproc("pkg_ecl.run_v1", [month, run_id])

    scored = scalar(cur, "SELECT COUNT(*) FROM pd_score WHERE reporting_date = :d", d=month)
    assert scalar(cur, "SELECT COUNT(*) FROM ecl_result WHERE reporting_date = :d", d=month) == scored
    assert scalar(cur, "SELECT COUNT(*) FROM ecl_result_v1 WHERE reporting_date = :d", d=month) == scored
    # Largest absolute difference over every money column of every loan.
    assert scalar(cur, "SELECT pkg_ecl.compare_versions(:d) FROM dual", d=month) < 0.01
