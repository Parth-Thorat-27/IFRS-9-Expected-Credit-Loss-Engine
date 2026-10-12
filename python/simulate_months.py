"""Phase 7: write the monthly snapshot files the batch loads.

The public data is one snapshot, so the base month (2019-03-31, LC_ACTUAL) is
written from the live book and the next month-ends are simulated from it
(SIMULATED). Each month, for every loan:

  - its DPD bucket moves by the roll-rate matrix in config/settings.json;
  - a loan that ends the month current pays its instalment, so its balance
    falls by the principal part; delinquent loans don't amortise;
  - paid-off, written-off and matured loans leave the book;
  - current FICO drifts with noise, drops when the loan rolls to a worse
    bucket, partly recovers on cure, and stays within 300-850;
  - a delinquent loan can enter forbearance with a small probability.

Every file then gets a configurable share of deliberate errors (negative
balance, missing loan id, unknown loan id, duplicate row, non-numeric DPD)
so data quality has work to do. The errors are only in the file as written;
the simulated loan itself is unchanged. A manifest of the errors goes to
data/processed/seeded_errors_YYYYMMDD.csv for the data quality tests.

Outputs per month-end, in data/incoming:
  loan_snapshot_YYYYMMDD.csv   one row per loan
  control_YYYYMMDD.csv         row count and total balance of that file as written

Usage: python python/simulate_months.py [--config config/settings.json]
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np
import pandas as pd

from ecl.config import INCOMING_DIR, PROCESSED_DIR, load_settings
from ecl.log import get_logger

log = get_logger("simulate_months")

STATES = ["CURRENT", "DPD_1_30", "DPD_31_60", "DPD_61_90", "DPD_90_PLUS", "PAID_OFF", "WRITTEN_OFF"]
ON_BOOK = STATES[:5]
# Inclusive DPD range of each on-book bucket (90+ has no upper end).
BUCKET_DPD = {"CURRENT": (0, 0), "DPD_1_30": (1, 30), "DPD_31_60": (31, 60),
              "DPD_61_90": (61, 90), "DPD_90_PLUS": (91, 10_000)}
SNAPSHOT_COLUMNS = ["reporting_date", "loan_id", "loan_status", "dpd", "balance",
                    "current_fico", "forbearance_flag", "remaining_months", "data_source"]
# Error type -> the data quality rule that must catch it (db/seed/dq_rules.sql).
ERROR_RULES = {"NEGATIVE_BALANCE": "DQ005", "MISSING_LOAN_ID": "DQ001", "UNKNOWN_LOAN_ID": "DQ004",
               "DUPLICATE_ROW": "DQ003", "NON_NUMERIC_DPD": "DQ007"}
# Ids for UNKNOWN_LOAN_ID errors: Lending Club ids are far below this, so none is in LOAN_MASTER.
UNKNOWN_ID_BASE = 900_000_000


def roll_rate_matrix(settings: dict) -> np.ndarray:
    """Rows = from-bucket, columns = STATES. Refuses to run unless every row sums to 1."""
    rates = settings["simulation"]["roll_rates"]
    matrix = np.array([[rates[src].get(dst, 0.0) for dst in STATES] for src in ON_BOOK])
    sums = matrix.sum(axis=1)
    bad = {src: round(float(s), 6) for src, s in zip(ON_BOOK, sums) if abs(s - 1) > 1e-9}
    if bad:
        raise SystemExit(f"roll-rate rows must each sum to 1; these don't: {bad}")
    return matrix


def bucket_of(dpd: np.ndarray) -> np.ndarray:
    """Index into ON_BOOK for each DPD value."""
    return np.select([dpd == 0, dpd <= 30, dpd <= 60, dpd <= 90], [0, 1, 2, 3], default=4)


def status_of(dpd: np.ndarray) -> np.ndarray:
    """Lending Club status implied by DPD, the same bands the base month was drawn from."""
    return np.select([dpd == 0, dpd <= 15, dpd <= 30, dpd <= 120],
                     ["Current", "In Grace Period", "Late (16-30 days)", "Late (31-120 days)"],
                     default="Default")


def month_ends(base: pd.Timestamp, months: int) -> list[pd.Timestamp]:
    return [base + pd.offsets.MonthEnd(k) for k in range(months + 1)]


def step_month(book: pd.DataFrame, matrix: np.ndarray, sim: dict, rng: np.random.Generator) -> tuple[pd.DataFrame, dict]:
    """Move every loan one month forward. Returns the loans still on the book and counts of the exits."""
    n = len(book)
    old_dpd = book["dpd"].to_numpy()
    old_bucket = bucket_of(old_dpd)

    # Draw each loan's next state from its bucket's row of the matrix: the
    # first state whose cumulative probability exceeds a uniform draw. The last
    # column is pinned to exactly 1 so float rounding in cumsum (0.9999999...)
    # can't let a draw fall off the end.
    cumulative = np.cumsum(matrix, axis=1)
    cumulative[:, -1] = 1.0
    cumulative = cumulative[old_bucket]
    draws = rng.random(n)
    new_state = (draws[:, None] >= cumulative).sum(axis=1).clip(max=len(STATES) - 1)
    new_bucket = new_state.copy()  # meaningful only for on-book states (0-4)

    # DPD: a cure goes to 0, a new delinquency lands somewhere in 1-30, a move
    # to another bucket shifts by 30 days, and 90+ loans keep ageing. The
    # result is clipped into the destination bucket's range.
    low = np.array([BUCKET_DPD[b][0] for b in ON_BOOK])
    high = np.array([BUCKET_DPD[b][1] for b in ON_BOOK])
    on_book = new_state < 5
    dest = np.where(on_book, new_bucket, 0)
    shift = np.sign(dest - old_bucket) * 30 + np.where((dest == 4) & (old_bucket == 4), 30, 0)
    new_dpd = np.clip(old_dpd + shift, low[dest], high[dest])
    newly_late = (old_bucket == 0) & (dest == 1)
    new_dpd = np.where(newly_late, rng.integers(1, 31, n), new_dpd)
    new_dpd = np.where(dest == 0, 0, new_dpd)

    # Balance: loans that end the month current pay one instalment.
    balance = book["balance"].to_numpy()
    rate = book["int_rate"].to_numpy() / 12
    principal = np.clip(book["installment"].to_numpy() - balance * rate, 0, None)
    paying = on_book & (dest == 0)
    new_balance = np.where(paying, np.round(np.clip(balance - principal, 0, None), 2), balance)

    # The contractual term runs down whether or not the borrower pays. A loan
    # still owing at maturity stays on the book with one month left.
    remaining = book["remaining_months"].to_numpy() - 1
    matured = paying & ((remaining <= 0) | (new_balance <= 0))
    remaining = np.maximum(remaining, 1)

    # FICO: monthly noise, a drop on a roll to a worse bucket, partial recovery
    # on cure. Values that were invalid in the source (below 300) are left as
    # they are, so data quality keeps flagging them as it would in real life.
    fico = book["current_fico"].to_numpy(dtype=float)
    valid = (fico >= 300) & (fico <= 850)
    drift = rng.normal(0, sim["fico_noise_sd"], n)
    drift -= np.where(on_book & (dest > old_bucket), sim["fico_drop_on_roll"], 0)
    drift += np.where(on_book & (dest == 0) & (old_bucket > 0), sim["fico_gain_on_cure"], 0)
    new_fico = np.where(valid, np.clip(np.round(fico + drift), 300, 850), fico)

    # Forbearance can switch on for a delinquent loan; once on, it stays on.
    forb = book["forbearance_flag"].to_numpy()
    switch_on = on_book & (dest > 0) & (rng.random(n) < sim["forbearance_on_delinquency_prob"])
    new_forb = np.where(switch_on, "Y", forb)

    stays = on_book & ~matured
    exits = {"paid_off": int((new_state == 5).sum()), "written_off": int((new_state == 6).sum()),
             "matured": int(matured.sum())}
    nxt = book.assign(dpd=new_dpd, balance=new_balance, current_fico=new_fico,
                      forbearance_flag=new_forb, remaining_months=remaining)
    return nxt[stays].reset_index(drop=True), exits


def format_rows(book: pd.DataFrame, reporting_date: pd.Timestamp, source: str) -> list[list[str]]:
    """Snapshot rows as the exact strings written to the file."""
    rd = f"{reporting_date:%Y-%m-%d}"
    fico = book["current_fico"].to_numpy(dtype=float)
    return [
        [rd, str(lid), status, str(int(dpd)), f"{bal:.2f}", "" if np.isnan(f) else f"{f:g}", forb,
         str(int(rem)), source]
        for lid, status, dpd, bal, f, forb, rem in zip(
            book["loan_id"], status_of(book["dpd"].to_numpy()), book["dpd"], book["balance"],
            fico, book["forbearance_flag"], book["remaining_months"])
    ]


def seed_errors(rows: list[list[str]], share: float, rng: np.random.Generator) -> tuple[list[list[str]], list[dict]]:
    """Corrupt a share of rows as written. Returns the rows and a manifest with final row numbers."""
    n_errors = int(round(len(rows) * share))
    picks = np.sort(rng.choice(len(rows), size=n_errors, replace=False))
    types = rng.choice(list(ERROR_RULES), size=n_errors)
    chosen = dict(zip(picks.tolist(), types.tolist()))

    out, manifest = [], []
    for i, row in enumerate(rows):
        kind = chosen.get(i)
        if kind is None:
            out.append(row)
            continue
        bad = list(row)
        if kind == "NEGATIVE_BALANCE":
            bad[4] = f"-{bad[4]}"
        elif kind == "MISSING_LOAN_ID":
            bad[1] = ""
        elif kind == "UNKNOWN_LOAN_ID":
            bad[1] = str(UNKNOWN_ID_BASE + len(manifest))
        elif kind == "NON_NUMERIC_DPD":
            bad[3] = "N/A"
        if kind == "DUPLICATE_ROW":
            # The original stays valid; the copy right after it is the bad row.
            out.append(row)
            out.append(list(row))
        else:
            out.append(bad)
        manifest.append({"row_num": len(out), "loan_id": row[1], "error_type": kind,
                         "expected_rule": ERROR_RULES[kind], "written_value": ",".join(out[-1])})
    return out, manifest


def write_month(rows: list[list[str]], manifest: list[dict], reporting_date: pd.Timestamp) -> dict:
    stamp = f"{reporting_date:%Y%m%d}"
    snapshot = INCOMING_DIR / f"loan_snapshot_{stamp}.csv"
    with open(snapshot, "w", encoding="utf-8", newline="\n") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(SNAPSHOT_COLUMNS)
        writer.writerows(rows)
    # The control file describes the file exactly as written, bad rows
    # included, so a truncated or altered file no longer matches it.
    total = sum(round(float(r[4]) * 100) for r in rows) / 100
    with open(INCOMING_DIR / f"control_{stamp}.csv", "w", encoding="utf-8", newline="\n") as f:
        f.write("reporting_date,row_count,total_balance\n")
        f.write(f"{reporting_date:%Y-%m-%d},{len(rows)},{total:.2f}\n")
    pd.DataFrame(manifest, columns=["row_num", "loan_id", "error_type", "expected_rule", "written_value"]) \
      .to_csv(PROCESSED_DIR / f"seeded_errors_{stamp}.csv", index=False, lineterminator="\n")
    return {"file": snapshot.name, "rows": len(rows), "total_balance": total}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", help="settings file (default config/settings.json)")
    args = parser.parse_args()

    settings = load_settings(args.config)
    sim = settings["simulation"]
    matrix = roll_rate_matrix(settings)

    base_file = PROCESSED_DIR / "portfolio_base.csv"
    if not base_file.exists():
        raise SystemExit(f"missing {base_file}: run python/prepare_data.py first")
    book = pd.read_csv(base_file, usecols=["loan_id", "balance", "int_rate", "installment", "current_fico",
                                           "forbearance_flag", "remaining_months", "dpd", "loan_status",
                                           "reporting_date"])
    base = pd.Timestamp(book["reporting_date"].iloc[0])
    INCOMING_DIR.mkdir(parents=True, exist_ok=True)
    seed = settings["seed"]

    for k, reporting_date in enumerate(month_ends(base, sim["months"])):
        if k == 0:
            # The real month: Lending Club's own statuses, as received.
            rows = format_rows(book, reporting_date, "LC_ACTUAL")
            for row, status in zip(rows, book["loan_status"]):
                row[2] = status
            exits = {}
        else:
            book, exits = step_month(book, matrix, sim, np.random.default_rng([seed, 100 + k]))
            rows = format_rows(book, reporting_date, "SIMULATED")
        rows, manifest = seed_errors(rows, sim["error_rate"], np.random.default_rng([seed, 200 + k]))
        written = write_month(rows, manifest, reporting_date)

        buckets = pd.Series(np.array(ON_BOOK)[bucket_of(book["dpd"].to_numpy())]).value_counts()
        log.info("%s %-9s loans %6d, balance %15s | %s | exits %s | rows with errors %d (%.3f%%)",
                 f"{reporting_date:%Y-%m-%d}", "LC_ACTUAL" if k == 0 else "SIMULATED", len(book),
                 f"{book['balance'].sum():,.2f}",
                 " ".join(f"{b}={int(buckets.get(b, 0))}" for b in ON_BOOK),
                 exits or "-", len(manifest), 100 * len(manifest) / written["rows"])


if __name__ == "__main__":
    main()
