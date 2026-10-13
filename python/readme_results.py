"""Write the measured results into README.md.

Everything between <!-- results:start --> and <!-- results:end --> is
replaced with numbers read from the database (the report views, DQ_ERROR,
STAGE_CHANGE_AUDIT, MODEL_REGISTRY), from the seeded-error manifests and from
docs/performance.md (written by benchmark_ecl.py). The README then only ever
shows what the last run produced; rerun this after the batch.

Usage: python python/readme_results.py
"""
from __future__ import annotations

import re

import pandas as pd

from ecl.config import DOCS_DIR, PROCESSED_DIR, ROOT_DIR
from ecl.db import connect, read_frame
from ecl.markdown import table

START, END = "<!-- results:start -->", "<!-- results:end -->"
# The tests' own made-up dates are in 2000; the real months start in 2019.
REAL_MONTHS = "reporting_date > DATE '2010-01-01'"


def month(d) -> str:
    return pd.Timestamp(d).strftime("%b %Y")


def millions(v: float) -> str:
    return f"${v / 1e6:,.1f}M"


def dollars(v: float) -> str:
    return f"${v:,.0f}"


def benchmark() -> tuple[str, int, dict[str, float]]:
    """Best times from the table benchmark_ecl.py wrote, and the month it timed."""
    text = (DOCS_DIR / "performance.md").read_text(encoding="utf-8")
    setup = re.search(r"^- Month: (\d{4}-\d{2}-\d{2}), ([\d,]+) loans", text, re.M)
    best = {}
    for name in ("run_v2 (production)", "run_v1", "closed-form sum"):
        row = re.search(rf"^\| {re.escape(name)} \|[^|]*\|[^|]*\| ([\d.]+) \|", text, re.M)
        if setup is None or row is None:
            raise SystemExit("docs/performance.md has no results table: run python/benchmark_ecl.py first")
        best[name] = float(row.group(1))
    return setup.group(1), int(setup.group(2).replace(",", "")), best


def seeded_errors_caught(conn, dates) -> tuple[int, int]:
    """Seeded errors in the manifests, and how many DQ_ERROR caught with the intended rule."""
    seeded = caught = 0
    for d in dates:
        manifest = PROCESSED_DIR / f"seeded_errors_{pd.Timestamp(d):%Y%m%d}.csv"
        if not manifest.exists():
            continue
        expected = pd.read_csv(manifest)
        found = read_frame(conn, "SELECT row_num, rule_id FROM dq_error WHERE reporting_date = :d", {"d": d})
        hits = expected.merge(found, left_on=["row_num", "expected_rule"], right_on=["row_num", "rule_id"])
        seeded += len(expected)
        caught += len(hits.drop_duplicates(["row_num", "expected_rule"]))
    return seeded, caught


def results(conn) -> str:
    q = lambda sql, **binds: read_frame(conn, sql, binds)  # noqa: E731
    by_stage = q(f"SELECT * FROM v_ecl_by_stage WHERE {REAL_MONTHS} ORDER BY reporting_date, stage")
    if by_stage.empty:
        raise SystemExit("no ECL results yet: run scripts/run_all_months.sh first")
    dates = sorted(by_stage.reporting_date.unique())
    first, last = dates[0], dates[-1]

    monthly = by_stage.groupby("reporting_date")[["loans", "balance", "ecl_final"]].sum()
    dq = q(f"""SELECT s.reporting_date, s.received, NVL(r.rejected, 0) AS rejected
                 FROM (SELECT reporting_date, COUNT(*) AS received FROM stg_loan_snapshot
                        WHERE {REAL_MONTHS} GROUP BY reporting_date) s
                 LEFT JOIN (SELECT reporting_date, COUNT(DISTINCT row_num) AS rejected FROM dq_error
                             WHERE severity = 'REJECT' GROUP BY reporting_date) r
                   ON r.reporting_date = s.reporting_date""").set_index("reporting_date")
    changes = q(f"""SELECT reporting_date, COUNT(*) AS changes FROM stage_change_audit
                     WHERE {REAL_MONTHS} GROUP BY reporting_date""").set_index("reporting_date")
    floors = q("SELECT * FROM v_floor_impact WHERE reporting_date = :d ORDER BY stage", d=last)
    scen = q("SELECT * FROM v_scenario_sensitivity WHERE reporting_date = :d", d=last).iloc[0]
    weights = q("SELECT scenario_code, weight FROM param_scenario").set_index("scenario_code").weight
    model = q("SELECT * FROM model_registry WHERE active_flag = 'Y'").iloc[0]
    sources = q(f"""SELECT data_source, MIN(reporting_date) AS first_date, MAX(reporting_date) AS last_date
                      FROM loan_snapshot WHERE {REAL_MONTHS} GROUP BY data_source ORDER BY 2""")
    bench_month, bench_loans, best = benchmark()
    seeded, caught = seeded_errors_caught(conn, dates)

    latest = by_stage[by_stage.reporting_date == last]
    total = monthly.loc[last]
    real = sources[sources.data_source == "LC_ACTUAL"]
    simulated = sources[sources.data_source == "SIMULATED"]
    out = []

    out.append(f"The last full run covered {len(dates)} month-ends, {month(first)} to {month(last)}. ")
    if not real.empty and not simulated.empty:
        out[-1] += (f"{month(real.first_date.iloc[0])} is the real Lending Club book; "
                    f"{month(simulated.first_date.iloc[0])} to {month(simulated.last_date.iloc[0])} "
                    "are simulated from it (see the limitations below).")
    out.append("")
    out.append(f"**{month(last)}:** {int(total.loans):,} loans with a balance of {millions(total.balance)} and a "
               f"final ECL of {millions(total.ecl_final)}, a coverage of {total.ecl_final / total.balance:.2%}.")
    out.append("")
    rows = [[f"Stage {int(r.stage)}", f"{int(r.loans):,}", millions(r.balance), f"{r.balance_share:.2%}",
             millions(r.ecl_final), f"{r.coverage:.2%}"] for r in latest.itertuples()]
    rows.append(["**Total**", f"**{int(total.loans):,}**", f"**{millions(total.balance)}**",
                 f"**{latest.balance_share.sum():.2%}**",
                 f"**{millions(total.ecl_final)}**", f"**{total.ecl_final / total.balance:.2%}**"])
    out.append(table(["Stage", "Loans", "Balance", "Share of balance", "Final ECL", "Coverage"], rows,
                     right=[1, 2, 3, 4, 5]))
    out.append("")

    out.append("**Month by month.** Rows rejected by data quality never reach the calculation. Stage changes "
               "are the rows `TRG_STAGE_CHANGE_AUDIT` wrote; the first month has none because there is no "
               "earlier stage to change from.")
    out.append("")
    rows = []
    for d in dates:
        m = monthly.loc[d]
        rows.append([month(d), f"{int(dq.received.get(d, 0)):,}", f"{int(dq.rejected.get(d, 0)):,}",
                     f"{int(m.loans):,}", millions(m.balance), millions(m.ecl_final),
                     f"{m.ecl_final / m.balance:.2%}", f"{int(changes.changes.get(d, 0)):,}"])
    out.append(table(["Month", "Rows received", "Rows rejected", "Loans", "Balance", "Final ECL", "Coverage",
                      "Stage changes"], rows, right=[1, 2, 3, 4, 5, 6, 7]))
    out.append("")
    if seeded:
        out.append(f"The simulator seeded {seeded:,} deliberate errors into the {len(dates)} files; data quality "
                   f"caught {caught:,} of them, each with the rule meant to catch it.")
        out.append("")

    added = floors.ecl_added_by_floors.sum()
    out.append(f"**RBI floors, {month(last)}.** The floor set the final ECL of {int(floors.loans_floored.sum()):,} "
               f"loans and added {dollars(added)} ({added / scen.ecl_final:.2%} of the final ECL).")
    out.append("")
    rows = [[f"Stage {int(r.stage)}", f"{int(r.loans_floored):,}", dollars(r.ecl_added_by_floors)]
            for r in floors.itertuples()]
    out.append(table(["Stage", "Loans floored", "Added by floors"], rows, right=[1, 2]))
    out.append("")

    out.append(f"**Scenarios, {month(last)}.** Total model ECL under each scenario, then weighted "
               f"({weights['BASE']:.0%} / {weights['DOWNSIDE']:.0%} / {weights['SEVERE']:.0%}) and floored.")
    out.append("")
    out.append(table(["Base", "Downside", "Severe", "Weighted", "Final after floors"],
                     [[millions(scen.ecl_base), millions(scen.ecl_downside), millions(scen.ecl_severe),
                       millions(scen.ecl_weighted), millions(scen.ecl_final)]], right=[0, 1, 2, 3, 4]))
    out.append("")

    out.append(f"**PD model.** Logistic regression trained on loans issued {pd.Timestamp(model.train_from):%Y}"
               f" to {pd.Timestamp(model.train_to):%Y} and tested out of time on "
               f"{pd.Timestamp(model.test_from):%Y} issues ({int(model.test_rows):,} loans): AUC "
               f"{model.auc_test:.4f}, Gini {model.gini_test:.4f}, KS {model.ks_test:.4f}, Brier "
               f"{model.brier_test:.4f}. Details in [docs/model_report.md](docs/model_report.md).")
    out.append("")
    v1, v2 = best["run_v1"], best["run_v2 (production)"]
    out.append(f"**ECL engine, v1 against v2.** On {month(bench_month)} ({bench_loans:,} loans, best of three "
               f"runs): set-based `run_v2` {v2:.2f} s, row-by-row `run_v1` {v1:.2f} s, the same ECL to the "
               f"cent on every loan. A closed-form variant took {best['closed-form sum']:.2f} s. "
               "[docs/performance.md](docs/performance.md) explains why set-based SQL isn't automatically "
               "faster here.")
    return "\n".join(out)


def main() -> None:
    path = ROOT_DIR / "README.md"
    text = path.read_text(encoding="utf-8")
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    with connect() as conn:
        block = results(conn)
    path.write_text(f"{head}{START}\n{block}\n{END}{tail}", encoding="utf-8", newline="\n")
    print(f"updated the results in {path.name}")


if __name__ == "__main__":
    main()
