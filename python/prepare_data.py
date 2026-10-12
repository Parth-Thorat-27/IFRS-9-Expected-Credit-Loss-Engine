"""Phase 2: build the engine's two inputs from the raw Lending Club file.

  data/processed/loans_dev.csv        closed loans from matured vintages (PD model, LGD)
  data/processed/portfolio_base.csv   open loans at the base reporting date (the live book)

It also writes docs/data_profile.md. Every random step uses the seed from
config/settings.json, so a re-run produces identical files.

Usage: python python/prepare_data.py [--config config/settings.json] [--raw PATH]
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

from ecl import features, markdown
from ecl.config import DOCS_DIR, PROCESSED_DIR, RAW_DIR, load_settings
from ecl.log import get_logger

log = get_logger("prepare_data")

RAW_NAMES = ("accepted_2007_to_2018Q4.csv", "accepted_2007_to_2018Q4.csv.gz")

CLOSED_STATUS_OUTCOME = {
    "Fully Paid": 0,
    "Charged Off": 1,
    # Loans issued under an older credit policy. The outcome is the same, so they count.
    "Does not meet the credit policy. Status:Fully Paid": 0,
    "Does not meet the credit policy. Status:Charged Off": 1,
}
# Starting days past due drawn for each open status (inclusive ranges).
OPEN_STATUS_DPD = {
    "Current": (0, 0),
    "In Grace Period": (1, 15),
    "Late (16-30 days)": (16, 30),
    "Late (31-120 days)": (31, 120),
    "Default": (121, 150),
}
# Matured vintages: the last issue month per term whose loans had their whole
# term to run before the data cut-off. Younger loans that have already closed
# are mostly early defaults or early payoffs, which would bias the default rate.
LAST_MATURED_ISSUE = {36: pd.Timestamp("2015-12-01"), 60: pd.Timestamp("2013-12-01")}

EMP_LENGTH_YEARS = {"< 1 year": 0, "1 year": 1, "10+ years": 10, **{f"{n} years": n for n in range(2, 10)}}

LGD_COLUMNS = ["total_rec_prncp", "recoveries", "collection_recovery_fee"]
LIVE_RAW_COLUMNS = ["out_prncp", "last_fico_range_low", "last_fico_range_high", "hardship_flag", "last_pymnt_d"]
RAW_COLUMNS = ["id", "loan_status", "issue_d", "term", *features.APPLICATION_COLUMNS, *LGD_COLUMNS, *LIVE_RAW_COLUMNS]
# Read as text and parsed explicitly: these hold %, month names or junk rows.
TEXT_COLUMNS = {
    "id", "loan_status", "issue_d", "term", "int_rate", "revol_util", "grade", "sub_grade",
    "emp_length", "home_ownership", "verification_status", "purpose", "addr_state",
    "earliest_cr_line", "application_type", "hardship_flag", "last_pymnt_d",
}

# Output layouts. The external tables in db/04_external_tables.sql read these
# columns in exactly this order.
DEV_COLUMNS = ["loan_id", "loan_status", "default_flag", "issue_d", "term_months",
               *features.APPLICATION_COLUMNS, *LGD_COLUMNS]
BASE_COLUMNS = ["loan_id", "loan_status", "issue_d", "term_months", *features.APPLICATION_COLUMNS,
                "balance", "current_fico", "forbearance_flag", "remaining_months", "dpd",
                "last_pymnt_d", "reporting_date"]

INT_COLUMNS = ["loan_id", "default_flag", "term_months", "emp_length", "delinq_2yrs", "fico_range_low",
               "fico_range_high", "inq_last_6mths", "open_acc", "pub_rec", "total_acc", "mort_acc",
               "pub_rec_bankruptcies", "remaining_months", "dpd"]
MONEY_COLUMNS = ["loan_amnt", "funded_amnt", "installment", "annual_inc", "revol_bal", "balance", *LGD_COLUMNS]


def find_raw_file(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    for name in RAW_NAMES:
        if (RAW_DIR / name).exists():
            return RAW_DIR / name
    raise SystemExit(f"raw file not found: put {RAW_NAMES[0]} (or .gz) in {RAW_DIR}")


def clean(chunk: pd.DataFrame) -> pd.DataFrame:
    """Parse one raw chunk into typed columns."""
    df = chunk.rename(columns={"id": "loan_id"})
    df["loan_id"] = pd.to_numeric(df["loan_id"], errors="coerce")
    # The file has "Total amount funded in policy code ..." summary lines with no id or status.
    df = df[df["loan_id"].notna() & df["loan_status"].notna()].copy()
    df["loan_id"] = df["loan_id"].astype("int64")
    df["term_months"] = df.pop("term").str.extract(r"(\d+)", expand=False).astype("int64")
    for col in ("int_rate", "revol_util"):
        # Stored as fractions (13.99% -> 0.1399) because the ECL maths uses them that way.
        df[col] = pd.to_numeric(df[col].str.rstrip("%"), errors="coerce") / 100
    df["emp_length"] = df["emp_length"].map(EMP_LENGTH_YEARS).astype("Int64")
    for col in ("issue_d", "earliest_cr_line", "last_pymnt_d"):
        df[col] = pd.to_datetime(df[col], format="%b-%Y", errors="coerce")
    return df


def read_raw(path: Path) -> tuple[pd.DataFrame, pd.DataFrame, pd.Series, pd.Timestamp]:
    """Stream the raw file once; return the closed and open candidates, status counts and max last_pymnt_d."""
    dev_parts, live_parts, status_counts = [], [], []
    max_last_payment = pd.Timestamp.min
    reader = pd.read_csv(path, usecols=RAW_COLUMNS, dtype={c: "str" for c in TEXT_COLUMNS},
                         chunksize=250_000)
    for i, chunk in enumerate(reader, start=1):
        df = clean(chunk)
        status_counts.append(df["loan_status"].value_counts())
        max_last_payment = max(max_last_payment, df["last_pymnt_d"].max())

        closed = df[df["loan_status"].isin(CLOSED_STATUS_OUTCOME)]
        closed = closed[closed["issue_d"] <= closed["term_months"].map(LAST_MATURED_ISSUE)].copy()
        closed["default_flag"] = closed["loan_status"].map(CLOSED_STATUS_OUTCOME)
        dev_parts.append(closed.drop(columns=LIVE_RAW_COLUMNS))

        live_parts.append(df[df["loan_status"].isin(OPEN_STATUS_DPD)].drop(columns=LGD_COLUMNS))
        log.info("chunk %d: %d rows read", i, len(chunk))

    statuses = pd.concat(status_counts).groupby(level=0).sum().sort_values(ascending=False)
    return pd.concat(dev_parts), pd.concat(live_parts), statuses, max_last_payment


def stratified_sample(df: pd.DataFrame, by: str, n: int, rng: np.random.Generator) -> pd.DataFrame:
    """Sample n rows keeping each group's share; largest remainders absorb the rounding."""
    counts = df[by].value_counts()
    exact = counts / counts.sum() * n
    alloc = np.floor(exact).astype(int)
    leftover = n - alloc.sum()
    alloc[(exact - alloc).sort_values(ascending=False, kind="stable").index[:leftover]] += 1
    parts = [df[df[by] == group].sample(n=int(k), random_state=rng) for group, k in alloc.items() if k > 0]
    return pd.concat(parts)


def build_live_book(live: pd.DataFrame, base: pd.Timestamp, n: int, rng_sample, rng_dpd) -> tuple[pd.DataFrame, dict]:
    months_since_issue = (base.year - live["issue_d"].dt.year) * 12 + (base.month - live["issue_d"].dt.month)
    live = live.assign(
        balance=live["out_prncp"],
        current_fico=(live["last_fico_range_low"] + live["last_fico_range_high"]) / 2,
        forbearance_flag=live["hardship_flag"],
        remaining_months=live["term_months"] - months_since_issue,
        reporting_date=base,
    )
    stats = {
        "open_loans": len(live),
        "zero_balance": int((live["balance"] <= 0).sum()),
        "no_remaining_term": int((live["remaining_months"] <= 0).sum()),
    }
    live = live[(live["balance"] > 0) & (live["remaining_months"] > 0)]
    stats["eligible"] = len(live)
    stats["eligible_by_status"] = live["loan_status"].value_counts()

    book = stratified_sample(live, "loan_status", min(n, len(live)), rng_sample).sort_values("loan_id")
    low = book["loan_status"].map(lambda s: OPEN_STATUS_DPD[s][0]).to_numpy()
    high = book["loan_status"].map(lambda s: OPEN_STATUS_DPD[s][1]).to_numpy()
    book["dpd"] = rng_dpd.integers(low, high + 1)  # upper bound is exclusive
    return book, stats


def to_output(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    out = df[columns].copy()
    for col in out.columns:
        if col in INT_COLUMNS:
            out[col] = out[col].round().astype("Int64")
        elif col in MONEY_COLUMNS or col == "dti":
            out[col] = out[col].round(2)
        elif col in ("int_rate", "revol_util"):
            out[col] = out[col].round(6)
        elif col == "current_fico":
            out[col] = out[col].round(1)
    return out


def write_profile(path: Path, raw_path: Path, statuses: pd.Series, dev_all: pd.DataFrame,
                  dev: pd.DataFrame, book: pd.DataFrame, live_stats: dict,
                  base: pd.Timestamp, base_source: str, settings: dict) -> None:
    def pct(x: float) -> str:
        return f"{x:.2%}"

    grade_all = dev_all.groupby("grade")["default_flag"].agg(["size", "mean"])
    grade_dev = dev.groupby("grade")["default_flag"].agg(["size", "mean"])
    vintage = dev.groupby([dev["issue_d"].dt.year, "term_months"]).size().unstack(fill_value=0)
    book_status = book.groupby("loan_status").agg(loans=("loan_id", "size"), balance=("balance", "sum"),
                                                  dpd_min=("dpd", "min"), dpd_max=("dpd", "max"))
    book_status = book_status.reindex([s for s in OPEN_STATUS_DPD if s in book_status.index])

    lines = [
        "# Data profile",
        "",
        f"Generated by `python/prepare_data.py` on {date.today():%Y-%m-%d} from `{raw_path.name}`. "
        f"Seed {settings['seed']}. Every number below comes from that run.",
        "",
        "## Raw file: loans by status",
        "",
        markdown.table(["Status", "Loans"], [[s, f"{c:,}"] for s, c in statuses.items()], right=[1]),
        "",
        f"Total: {statuses.sum():,} loans (summary lines without an id or status were dropped).",
        "",
        "## Development set (closed loans, matured vintages)",
        "",
        f"- Eligible: {len(dev_all):,} closed loans (36-month issued by Dec 2015, 60-month by Dec 2013).",
        f"- Sampled: {len(dev):,} with seed {settings['seed']}; default rate {pct(dev['default_flag'].mean())}.",
        "",
        "Default rate by grade:",
        "",
        markdown.table(
            ["Grade", "Eligible loans", "Eligible default rate", "Sampled loans", "Sampled default rate"],
            [[g, f"{grade_all.loc[g, 'size']:,}", pct(grade_all.loc[g, "mean"]),
              f"{grade_dev.loc[g, 'size']:,}", pct(grade_dev.loc[g, "mean"])] for g in grade_dev.index],
            right=[1, 2, 3, 4]),
        "",
        "Sampled loans by issue year and term:",
        "",
        markdown.table(["Issue year", *[f"{t} months" for t in vintage.columns]],
                       [[y, *[f"{v:,}" for v in row]] for y, row in vintage.iterrows()],
                       right=list(range(1, len(vintage.columns) + 1))),
        "",
        "## Live book (open loans)",
        "",
        f"- Base reporting date: **{base:%Y-%m-%d}** ({base_source}).",
        f"- Open loans in the file: {live_stats['open_loans']:,}. Dropped {live_stats['zero_balance']:,} with zero "
        f"balance and {live_stats['no_remaining_term']:,} with no remaining term (a loan can be in both groups); "
        f"{live_stats['eligible']:,} eligible.",
        f"- Sampled {len(book):,} keeping the status mix; total balance ${book['balance'].sum():,.2f}.",
        f"- Remaining term: {book['remaining_months'].min()} to {book['remaining_months'].max()} months "
        f"(median {book['remaining_months'].median():.0f}).",
        f"- Current FICO outside 300-850: {int((~book['current_fico'].between(300, 850)).sum()):,} loans "
        "(left as received; data quality rule DQ008 flags them).",
        f"- Forbearance flag Y: {int((book['forbearance_flag'] == 'Y').sum()):,} loans.",
        "",
        markdown.table(
            ["Status", "Eligible", "Sampled", "Balance", "Starting DPD"],
            [[r.Index, f"{live_stats['eligible_by_status'][r.Index]:,}", f"{r.loans:,}", f"${r.balance:,.2f}",
              f"{r.dpd_min}-{r.dpd_max}"] for r in book_status.itertuples()],
            right=[1, 2, 3]),
        "",
    ]
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", help="settings file (default config/settings.json)")
    parser.add_argument("--raw", help="raw accepted-loans CSV (default: found in data/raw)")
    args = parser.parse_args()

    settings = load_settings(args.config)
    seed = settings["seed"]
    # One independent random stream per job, so changing one step's draws can't
    # silently change another step's output.
    rng_dev, rng_live, rng_dpd = (np.random.default_rng([seed, k]) for k in (1, 2, 3))

    # Fail before any work if the feature list ever picks up a post-origination column.
    features.assert_no_leakage(features.model_inputs())

    raw_path = find_raw_file(args.raw)
    log.info("reading %s", raw_path)
    dev_all, live_all, statuses, max_last_payment = read_raw(raw_path)

    if settings.get("base_reporting_date"):
        base = pd.Timestamp(settings["base_reporting_date"])
        base_source = "override from settings.json"
    else:
        base = max_last_payment + pd.offsets.MonthEnd(0)
        base_source = f"month-end of the latest last_pymnt_d in the file, {max_last_payment:%b-%Y}"
    log.info("base reporting date %s (%s)", f"{base:%Y-%m-%d}", base_source)

    dev = dev_all.sample(n=min(settings["sampling"]["dev_loans"], len(dev_all)), random_state=rng_dev)
    dev = dev.sort_values("loan_id")
    book, live_stats = build_live_book(live_all, base, settings["sampling"]["live_loans"], rng_live, rng_dpd)

    # Checks: the script refuses to write output that breaks them.
    rates = dev.groupby("grade")["default_flag"].mean()
    assert list(rates.index) == list("ABCDEFG"), f"unexpected grades {list(rates.index)}"
    assert rates.is_monotonic_increasing, f"default rate does not rise from A to G: {rates.round(4).to_dict()}"
    assert book["loan_id"].notna().all() and book["loan_id"].is_unique, "live book loan ids missing or repeated"
    assert (book["balance"] > 0).all(), "live book has zero balances"
    assert (book["remaining_months"] > 0).all(), "live book has loans with no remaining term"

    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    dev_path, base_path = PROCESSED_DIR / "loans_dev.csv", PROCESSED_DIR / "portfolio_base.csv"
    to_output(dev, DEV_COLUMNS).to_csv(dev_path, index=False, date_format="%Y-%m-%d", lineterminator="\n")
    to_output(book, BASE_COLUMNS).to_csv(base_path, index=False, date_format="%Y-%m-%d", lineterminator="\n")
    write_profile(DOCS_DIR / "data_profile.md", raw_path, statuses, dev_all, dev, book, live_stats,
                  base, base_source, settings)

    log.info("dev set: %d of %d eligible closed loans, default rate %.4f -> %s",
             len(dev), len(dev_all), dev["default_flag"].mean(), dev_path.name)
    log.info("default rate by grade: %s", ", ".join(f"{g} {r:.2%}" for g, r in rates.items()))
    log.info("live book: %d of %d eligible open loans, balance %.2f -> %s",
             len(book), live_stats["eligible"], book["balance"].sum(), base_path.name)
    log.info("checks passed: no leakage columns, default rate rises A->G, "
             "live book has no missing ids, zero balances or zero remaining terms")


if __name__ == "__main__":
    main()
