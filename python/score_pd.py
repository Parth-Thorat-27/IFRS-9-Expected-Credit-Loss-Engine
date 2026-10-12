"""Phase 9: score one month's clean snapshot with the PD model.

For every loan in LOAN_SNAPSHOT on the reporting date:
  - pd_12m_orig     copied from LOAN_MASTER (application data, at origination);
  - pd_12m_current  the same model and features, but with the origination FICO
                    replaced by today's FICO, so a falling score raises the PD.
                    Where data quality nulled the current FICO (DQ008), the
                    origination FICO is used instead.
Both are 12-month PDs (constant hazard from the model's term PD), floored at
PD_FLOOR. Rows go to PD_SCORE with batched executemany, and the step is
logged to BATCH_RUN through PKG_BATCH_LOG.

Usage: python python/score_pd.py --reporting-date YYYY-MM-DD [--run-id N]
"""
from __future__ import annotations

import argparse
import json
from datetime import date

import joblib
import numpy as np
import pandas as pd

from ecl import features, markdown
from ecl.batchlog import batch_step
from ecl.config import MODELS_DIR
from ecl.db import connect, get_setting, read_frame
from ecl.log import get_logger
from ecl.pd import apply_floor, term_to_12m

log = get_logger("score_pd")

APP_COLS = ", ".join(f"m.{c}" for c in features.APPLICATION_COLUMNS)
SNAPSHOT_SQL = f"""
    SELECT s.loan_id, s.current_fico, m.issue_d, m.term_months, m.pd_12m_orig, {APP_COLS}
      FROM loan_snapshot s
      JOIN loan_master m ON m.loan_id = s.loan_id
     WHERE s.reporting_date = :reporting_date"""
BATCH_SIZE = 20_000


def active_model(conn):
    """Load the saved model and make sure it is the version MODEL_REGISTRY says is active."""
    with conn.cursor() as cur:
        cur.execute("SELECT model_version FROM model_registry WHERE active_flag = 'Y'")
        row = cur.fetchone()
    if row is None:
        raise SystemExit("no active model in MODEL_REGISTRY: run python/train_pd_model.py first")
    saved = json.loads((MODELS_DIR / "pd_model.json").read_text(encoding="utf-8"))["model_version"]
    if saved != row[0]:
        raise SystemExit(f"models/pd_model.joblib is {saved} but the active model is {row[0]}: retrain or reactivate")
    return joblib.load(MODELS_DIR / "pd_model.joblib"), row[0]


def fico_band_table(scored: pd.DataFrame) -> str:
    """Average PDs by how far FICO moved since origination: PD should be higher where FICO fell."""
    change = scored["fico_used"] - scored["fico_orig"]
    band = np.select([change <= -40, change < 0, change == 0], ["fell 40+", "fell 1-39", "unchanged"], "rose")
    table = (scored.assign(band=band)
                   .groupby("band")
                   .agg(loans=("loan_id", "size"), pd_orig=("pd_12m_orig", "mean"),
                        pd_current=("pd_12m_current", "mean"))
                   .reindex(["fell 40+", "fell 1-39", "unchanged", "rose"]).dropna())
    return markdown.table(
        ["FICO since origination", "Loans", "Mean pd_12m_orig", "Mean pd_12m_current", "Ratio"],
        [[b, f"{int(r.loans):,}", f"{r.pd_orig:.2%}", f"{r.pd_current:.2%}", f"{r.pd_current / r.pd_orig:.2f}"]
         for b, r in zip(table.index, table.itertuples())], right=[1, 2, 3, 4])


def score(conn, reporting_date: date, run_id: int | None) -> pd.DataFrame:
    with batch_step(conn, "SCORE_PD", run_id, reporting_date) as step:
        with conn.cursor() as cur:
            # Never score a month whose clean load hasn't finished.
            cur.callproc("pkg_batch_log.require_step", [reporting_date, "LOAD_CLEAN"])
        model, version = active_model(conn)
        pd_floor = get_setting(conn, "PD_FLOOR")

        book = read_frame(conn, SNAPSHOT_SQL, {"reporting_date": reporting_date})
        if book.empty:
            raise RuntimeError(f"no clean snapshot rows for {reporting_date}")
        if book["pd_12m_orig"].isna().any():
            raise RuntimeError("LOAN_MASTER has loans without pd_12m_orig: run python/train_pd_model.py")

        book["fico_orig"] = (book["fico_range_low"] + book["fico_range_high"]) / 2
        has_current = book["current_fico"].notna()
        book["fico_used"] = book["current_fico"].where(has_current, book["fico_orig"])
        book["fico_source"] = np.where(has_current, "CURRENT", "ORIGINATION")

        x = features.add_derived_features(book, fico=book["fico_used"])
        pd_term = model.predict_proba(x[features.NUMERIC_FEATURES + features.CATEGORICAL_FEATURES])[:, 1]
        book["pd_12m_current"] = apply_floor(term_to_12m(pd_term, book["term_months"]), pd_floor)

        rows = [(reporting_date, int(r.loan_id), float(r.pd_12m_orig), float(r.pd_12m_current),
                 float(r.fico_used), r.fico_source, version, step.run_id)
                for r in book.itertuples()]
        with conn.cursor() as cur:
            # Re-runnable: replace the date's scores, never add to them.
            cur.execute("DELETE FROM pd_score WHERE reporting_date = :d", d=reporting_date)
            for start in range(0, len(rows), BATCH_SIZE):
                cur.executemany("""
                    INSERT INTO pd_score (reporting_date, loan_id, pd_12m_orig, pd_12m_current,
                                          fico_used, fico_source, model_version, run_id)
                    VALUES (:1, :2, :3, :4, :5, :6, :7, :8)""", rows[start:start + BATCH_SIZE])
        conn.commit()

        fallback = int((~has_current).sum())
        step.rows = len(rows)
        step.message = (f"{len(rows)} loans scored with {version}; mean pd_12m_orig "
                        f"{book['pd_12m_orig'].mean():.4f}, mean pd_12m_current {book['pd_12m_current'].mean():.4f}; "
                        f"origination FICO used for {fallback} loans (DQ008)")
        log.info("%s: %s", reporting_date, step.message)
    return book


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reporting-date", required=True, type=date.fromisoformat, help="YYYY-MM-DD")
    parser.add_argument("--run-id", type=int, help="BATCH_RUN run id to log under (default: a new one)")
    args = parser.parse_args()

    with connect() as conn:
        scored = score(conn, args.reporting_date, args.run_id)
    print(f"\nPD by FICO change since origination, {args.reporting_date}:\n")
    print(fico_band_table(scored))


if __name__ == "__main__":
    main()
