"""BATCH_RUN logging for Python steps, through the same PKG_BATCH_LOG the
PL/SQL steps use, so every step of a run lands in one table.

    with batch_step(conn, "SCORE_PD", run_id, reporting_date) as step:
        ... work ...
        step.rows, step.message = n, "scored 99,912 loans"

On an exception the step is closed as FAILED with the error, and the error
is re-raised so the caller (and the batch) still stops.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date

import oracledb


@dataclass
class StepResult:
    rows: int | None = None
    message: str | None = None
    run_id: int | None = None


@contextmanager
def batch_step(conn: oracledb.Connection, step_name: str, run_id: int | None = None,
               reporting_date: date | None = None):
    with conn.cursor() as cur:
        if run_id is None:
            run_id = cur.callfunc("pkg_batch_log.new_run_id", int)
        step_id = cur.callfunc("pkg_batch_log.start_step", int, [run_id, reporting_date, step_name])
    result = StepResult(run_id=run_id)
    try:
        yield result
    except BaseException as exc:
        conn.rollback()
        with conn.cursor() as cur:
            cur.callproc("pkg_batch_log.end_step",
                         [step_id, "FAILED", None, f"{type(exc).__name__}: {exc}"[:4000]])
        raise
    with conn.cursor() as cur:
        cur.callproc("pkg_batch_log.end_step", [step_id, "SUCCESS", result.rows, result.message])
