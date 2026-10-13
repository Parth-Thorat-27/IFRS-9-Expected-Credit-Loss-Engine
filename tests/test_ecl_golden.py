"""The golden loan, to the cent.

One loan: balance $10,000, 12% a year (1% a month), 24 months left,
12-month PD 5%, LGD 80%, DPD 0, base scenario only. Expected (from the spec,
re-derived independently in python/ecl/ecl_math.py, never from the PL/SQL):

    payment $470.73, monthly hazard 0.42653%
    Stage 1 (12 months)  model $298.69  floor 1% = $100.00   final $298.69
    Stage 2 (lifetime)   model $393.52  floor 5% = $500.00   final $500.00 (floor applied)
    Stage 3 (first year) model $8,000   floor 40% = $4,000   final $8,000.00

Three levels: the Python maths, the PL/SQL row function fn_ecl_loan, and the
whole engine (run_v2 and run_v1 on golden loans for a test date, first with
the spec's assumptions, then with the real parameters).
"""
from __future__ import annotations

from datetime import date

import pytest

from conftest import ROOT, scalar
from ecl import ecl_math
from ecl.pd import monthly_hazard

B, RATE, N, PD, LGD = 10_000.0, 0.12, 24, 0.05, 0.80
EXPECTED = {  # stage: (model ECL, floor rate, floor amount, final ECL, floor applied)
    1: (298.69, 0.01, 100.00, 298.69, "N"),
    2: (393.52, 0.05, 500.00, 500.00, "Y"),
    3: (8000.00, 0.40, 4000.00, 8000.00, "N"),
}
TEST_DATE = date(2000, 1, 31)
LOANS = {999_000_001: 1, 999_000_002: 2, 999_000_003: 3}   # loan id -> stage


# ----------------------------------------------------------------- level 1: the maths
def test_payment_and_hazard():
    assert round(ecl_math.level_payment(B, RATE / 12, N), 2) == 470.73
    assert round(float(monthly_hazard(PD)) * 100, 5) == 0.42653


@pytest.mark.parametrize("stage", [1, 2, 3])
def test_python_reproduces_the_spec(stage):
    model, floor_rate, floor_amount, final, applied = EXPECTED[stage]
    ecl = ecl_math.model_ecl(stage, B, RATE, N, PD, LGD)
    assert round(ecl, 2) == model
    assert ecl_math.final_ecl(ecl, floor_rate, B) == (floor_amount, final, applied)


# ----------------------------------------------------------------- level 2: fn_ecl_loan
@pytest.mark.parametrize("stage", [1, 2, 3])
def test_plsql_row_function_matches_to_the_cent(cur, stage):
    horizon = {1: 12, 2: N, 3: 0}[stage]
    value = scalar(cur, "SELECT pkg_ecl.fn_ecl_loan(:b, :r, :n, :h, :pd, :lgd, :stage) FROM dual",
                   b=B, r=RATE, n=N, h=horizon, pd=PD, lgd=LGD, stage=stage)
    assert round(value, 2) == EXPECTED[stage][0]


# ----------------------------------------------------------------- level 3: the engine
def _log_done(cur, run_id: int, step: str) -> None:
    step_id = cur.callfunc("pkg_batch_log.start_step", int, [run_id, TEST_DATE, step])
    cur.callproc("pkg_batch_log.end_step", [step_id, "SUCCESS", 0, "golden test set-up"])


@pytest.fixture(scope="module")
def golden_loans(conn):
    """Three golden loans (one per stage) on TEST_DATE, with every input the engine reads."""
    with conn.cursor() as cur:
        run_id = cur.callfunc("pkg_batch_log.new_run_id", int)
        version = scalar(cur, "SELECT model_version FROM model_registry WHERE active_flag = 'Y'")
        rows = []
        for loan_id, stage in LOANS.items():
            # Stage 2 by PD deterioration keeps DPD at 0 (multiplier 1.0, no restructured floor):
            # origination PD 1% -> current 5% is 5x and +4 points.
            pd_orig = 0.01 if stage == 2 else PD
            status = "Default" if stage == 3 else "Current"
            reason = {1: "PERFORMING", 2: "PD_DETERIORATION", 3: "DEFAULT_STATUS"}[stage]
            rows.append((loan_id, stage, pd_orig, status, reason))
            cur.execute("""INSERT INTO loan_master (loan_id, issue_d, term_months, loan_amnt, funded_amnt,
                                                    int_rate, grade, pd_12m_orig, pd_model_version)
                           VALUES (:loan_id, DATE '1999-01-01', 36, 20000, 20000, :rate, 'A', :pd_orig, :version)""",
                        loan_id=loan_id, rate=RATE, pd_orig=pd_orig, version=version)
            cur.execute("""INSERT INTO loan_snapshot (reporting_date, loan_id, loan_status, dpd, balance,
                                                      current_fico, forbearance_flag, remaining_months,
                                                      data_source, source_row_num, run_id)
                           VALUES (:rd, :loan_id, :status, 0, :balance, 700, 'N', :remaining, 'SIMULATED', :src_row, :run_id)""",
                        rd=TEST_DATE, loan_id=loan_id, status=status, balance=B, remaining=N,
                        src_row=stage, run_id=run_id)
            cur.execute("""INSERT INTO pd_score (reporting_date, loan_id, pd_12m_orig, pd_12m_current,
                                                 fico_used, fico_source, model_version, run_id)
                           VALUES (:rd, :loan_id, :pd_orig, :pd_current, 700, 'CURRENT', :version, :run_id)""",
                        rd=TEST_DATE, loan_id=loan_id, pd_orig=pd_orig, pd_current=PD, version=version,
                        run_id=run_id)
            cur.execute("""INSERT INTO loan_stage_history (reporting_date, loan_id, stage, reason_code,
                                                           cure_months, stage_since, stage3_since, run_id)
                           VALUES (:rd, :loan_id, :stage, :reason, 0, :rd, :stage3_since, :run_id)""",
                        rd=TEST_DATE, loan_id=loan_id, stage=stage, reason=reason,
                        stage3_since=TEST_DATE if stage == 3 else None, run_id=run_id)
        conn.commit()
        for step in ("LOAD_SNAPSHOT", "ASSIGN_STAGES"):
            _log_done(cur, run_id, step)
        try:
            yield run_id
        finally:
            cur.callfunc("pkg_load.purge_date", int, [TEST_DATE])
            cur.execute("DELETE FROM loan_master WHERE loan_id BETWEEN 999000001 AND 999000003")
            conn.commit()


def run_engines(cur, run_id: int) -> dict:
    cur.callproc("pkg_ecl.run_v2", [TEST_DATE, run_id])
    cur.callproc("pkg_ecl.run_v1", [TEST_DATE, run_id])
    out = {}
    for table in ("ecl_result", "ecl_result_v1"):
        cur.execute(f"""SELECT loan_id, ecl_base, ecl_downside, ecl_severe, ecl_weighted, floor_rate,
                               floor_amount, ecl_final, floor_applied
                          FROM {table} WHERE reporting_date = :d""", d=TEST_DATE)
        out[table] = {r[0]: r[1:] for r in cur.fetchall()}
    return out


def test_engine_reproduces_the_spec_table(conn, cur, golden_loans):
    """With the spec's assumptions (LGD 80%, base scenario only) both engines give the table exactly."""
    xml = (ROOT / "config" / "ecl_parameters.xml").read_text(encoding="utf-8")
    base_only = (xml.replace('code="BASE" weight="0.60"', 'code="BASE" weight="1.00"')
                    .replace('code="DOWNSIDE" weight="0.30"', 'code="DOWNSIDE" weight="0.00"')
                    .replace('code="SEVERE" weight="0.10"', 'code="SEVERE" weight="0.00"'))
    saved_lgd = scalar(cur, "SELECT lgd FROM param_lgd WHERE grade = 'A'")
    try:
        cur.callproc("pkg_params.load_from_clob", [base_only, "golden test: base scenario only"])
        cur.execute("UPDATE param_lgd SET lgd = :lgd WHERE grade = 'A'", lgd=LGD)
        conn.commit()
        results = run_engines(cur, golden_loans)
    finally:
        cur.execute("UPDATE param_lgd SET lgd = :lgd WHERE grade = 'A'", lgd=saved_lgd)
        conn.commit()
        cur.callproc("pkg_params.load_from_xml", ["ecl_parameters.xml"])

    for table, rows in results.items():
        for loan_id, stage in LOANS.items():
            base, _down, _severe, weighted, floor_rate, floor_amount, final, applied = rows[loan_id]
            model, exp_rate, exp_floor, exp_final, exp_applied = EXPECTED[stage]
            assert (base, weighted) == (model, model), f"{table} stage {stage} model ECL"
            assert (floor_rate, floor_amount, final, applied) == (exp_rate, exp_floor, exp_final, exp_applied), \
                f"{table} stage {stage} floor/final"


def test_engine_with_real_parameters_matches_independent_python(cur, golden_loans):
    """All three scenarios, the real weights, multipliers, LGD and floors: engine == Python to the cent."""
    results = run_engines(cur, golden_loans)
    lgd = scalar(cur, "SELECT lgd FROM param_lgd WHERE grade = 'A'")
    cap = scalar(cur, "SELECT setting_value FROM param_setting WHERE setting_name = 'PD_CAP'")
    cur.execute("SELECT scenario_code, weight, pd_multiplier FROM param_scenario")
    scenarios = {code: (w, m) for code, w, m in cur.fetchall()}
    cur.execute("SELECT stage, restructured_flag, months_in_stage3_from, floor_rate FROM param_floor")
    floors = {(s, f, m): rate for s, f, m, rate in cur.fetchall()}

    for loan_id, stage in LOANS.items():
        pd_meas = 1.0 if stage == 3 else min(PD * 1.0, cap)   # DPD 0 -> multiplier 1.0
        by_scenario = {code: ecl_math.model_ecl(stage, B, RATE, N, min(pd_meas * m, cap), lgd)
                       for code, (_w, m) in scenarios.items()}
        weighted = sum(scenarios[c][0] * v for c, v in by_scenario.items())
        floor_rate = floors[(3, "*", 0)] if stage == 3 else floors[(stage, "N", 0)]
        floor_amount, final, applied = ecl_math.final_ecl(weighted, floor_rate, B)
        expected = (ecl_math.cents(by_scenario["BASE"]), ecl_math.cents(by_scenario["DOWNSIDE"]),
                    ecl_math.cents(by_scenario["SEVERE"]), ecl_math.cents(weighted),
                    floor_rate, floor_amount, final, applied)
        for table, rows in results.items():
            assert rows[loan_id] == expected, f"{table} stage {stage}"
