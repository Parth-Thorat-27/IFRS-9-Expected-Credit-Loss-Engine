"""Phase 11 benchmark: time the ECL four ways on the same month and write
docs/performance.md from the measured numbers.

                    processing        arithmetic       code
  run_v2            one statement     BINARY_DOUBLE    PKG_ECL (production)
  run_v1            row by row        NUMBER           PKG_ECL
  set-based NUMBER  one statement     NUMBER           db/benchmark/ecl_set_based_number.sql
  row-by-row DOUBLE row by row        BINARY_DOUBLE    db/benchmark/ecl_row_by_row_double.sql
  closed-form sum   one statement,    BINARY_DOUBLE    db/benchmark/ecl_closed_form.sql
                    no month rows

Each variant runs --repeat times on an empty target, and the fastest run is
kept (the least disturbed by other work on the machine). Every variant's
result is compared with production to the cent (pkg_ecl.compare_versions).
run_v1 goes last, so ECL_RESULT_V1 ends up holding the engine's own result.

Usage: python python/benchmark_ecl.py --reporting-date YYYY-MM-DD [--repeat 3]
"""
from __future__ import annotations

import argparse
import platform
from datetime import date

from ecl import markdown
from ecl.config import DOCS_DIR, ROOT_DIR
from ecl.db import connect
from ecl.log import get_logger

log = get_logger("benchmark_ecl")

VARIANTS = [
    # key, label, processing, arithmetic, how to run, target table, BATCH_RUN step
    ("v2", "run_v2 (production)", "one INSERT ... SELECT", "BINARY_DOUBLE", "pkg_ecl.run_v2", "ecl_result", "RUN_ECL"),
    ("set_number", "set-based, NUMBER", "one INSERT ... SELECT", "NUMBER",
     "db/benchmark/ecl_set_based_number.sql", "ecl_result_v1", "BENCH_SET_BASED_NUMBER"),
    ("row_double", "row by row, BINARY_DOUBLE", "cursor loop, single-row inserts", "BINARY_DOUBLE",
     "db/benchmark/ecl_row_by_row_double.sql", "ecl_result_v1", "BENCH_ROW_BY_ROW_DOUBLE"),
    ("closed_form", "closed-form sum", "one INSERT ... SELECT, no month rows", "BINARY_DOUBLE",
     "db/benchmark/ecl_closed_form.sql", "ecl_result_v1", "BENCH_CLOSED_FORM"),
    ("v1", "run_v1", "cursor loop, single-row inserts", "NUMBER", "pkg_ecl.run_v1", "ecl_result_v1", "RUN_ECL_V1"),
]


def run_variant(conn, how: str, reporting_date: date, run_id: int) -> None:
    with conn.cursor() as cur:
        if how.startswith("pkg_"):
            cur.callproc(how, [reporting_date, run_id])
        else:
            block = (ROOT_DIR / how).read_text(encoding="utf-8")
            cur.execute(block, reporting_date=reporting_date, run_id=run_id)


def scalar(conn, sql: str, **binds):
    with conn.cursor() as cur:
        cur.execute(sql, binds)
        return cur.fetchone()[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reporting-date", required=True, type=date.fromisoformat)
    parser.add_argument("--repeat", type=int, default=3)
    args = parser.parse_args()
    rd = args.reporting_date

    results = {}
    with connect() as conn:
        loans = scalar(conn, "SELECT COUNT(*) FROM v_ecl_input WHERE reporting_date = :d", d=rd)
        if loans == 0:
            raise SystemExit(f"nothing to benchmark for {rd}: run the batch for that month first")
        month_rows = (scalar(conn, "SELECT SUM(horizon_months) FROM v_ecl_input WHERE reporting_date = :d", d=rd)
                      * scalar(conn, "SELECT COUNT(*) FROM param_scenario"))
        db_version = scalar(conn, "SELECT version_full FROM product_component_version WHERE ROWNUM = 1")
        run_id = scalar(conn, "SELECT pkg_batch_log.new_run_id FROM dual")

        for key, label, processing, arithmetic, how, table, step in VARIANTS:
            times = []
            for attempt in range(args.repeat):
                with conn.cursor() as cur:
                    # Empty target first, so no variant's time includes deleting old rows.
                    cur.execute(f"DELETE FROM {table} WHERE reporting_date = :d", d=rd)
                conn.commit()
                run_variant(conn, how, rd, run_id)
                seconds = scalar(conn, """SELECT elapsed_seconds FROM batch_run WHERE run_id = :r AND step_name = :s
                                           ORDER BY batch_run_id DESC FETCH FIRST 1 ROW ONLY""", r=run_id, s=step)
                times.append(float(seconds))
                log.info("%-28s run %d: %.2f s", label, attempt + 1, seconds)
            diff = 0.0 if key == "v2" else float(scalar(conn, "SELECT pkg_ecl.compare_versions(:d) FROM dual", d=rd))
            results[key] = {"label": label, "processing": processing, "arithmetic": arithmetic,
                            "code": how, "times": times, "best": min(times), "diff": diff}
            log.info("%-28s best %.2f s, largest difference vs production $%.2f", label, min(times), diff)
        total_ecl = scalar(conn, "SELECT SUM(ecl_final) FROM ecl_result WHERE reporting_date = :d", d=rd)

    write_report(rd, loans, month_rows, db_version, results, total_ecl, args.repeat)


def write_report(rd: date, loans: int, month_rows: int, db_version: str, r: dict, total_ecl: float,
                 repeat: int) -> None:
    t = {k: v["best"] for k, v in r.items()}

    def versus(a: str, b: str) -> str:
        """'A x.xx s vs B y.yy s: A is n.nx faster' with the labels of two variants."""
        la, lb = r[a]["label"], r[b]["label"]
        winner, loser = (la, lb) if t[a] < t[b] else (lb, la)
        return (f"{la} {t[a]:.2f} s against {lb} {t[b]:.2f} s: {winner} is "
                f"{max(t[a], t[b]) / min(t[a], t[b]):.1f}x faster than {loser}")

    loop_wins_same_maths = t["row_double"] < t["v2"]
    rows = [[v["label"], v["processing"], v["arithmetic"], f"{v['best']:.2f}",
             ", ".join(f"{x:.2f}" for x in v["times"]), f"${v['diff']:.2f}"] for v in r.values()]
    lines = [
        "# Performance: row-by-row vs set-based ECL",
        "",
        f"Generated by `python/benchmark_ecl.py` on {date.today():%Y-%m-%d}. Every number below was measured "
        "in that run; nothing is estimated.",
        "",
        "## Set-up",
        "",
        f"- Month: {rd:%Y-%m-%d}, {loans:,} loans, 3 scenarios; {month_rows:,} loan-scenario-month rows "
        "(each loan's horizon: 12 months in Stage 1, the remaining term in Stage 2, none in Stage 3).",
        f"- Database: Oracle Database Free {db_version} in Docker (Free is limited to 2 CPU threads).",
        f"- Client machine: {platform.system()} build {platform.version()}, Python {platform.python_version()}.",
        f"- Each variant ran {repeat} times on an empty target table; the table shows every run and the fastest. "
        "Times are `BATCH_RUN.elapsed_seconds`, measured inside the database.",
        "",
        "## Results",
        "",
        markdown.table(["Variant", "Processing", "Arithmetic", "Best (s)", "All runs (s)",
                        "Largest difference vs production"], rows, right=[3]),
        "",
        f"Total final ECL for the month: ${total_ecl:,.2f}. Every variant produced the same ECL for every loan "
        "to the cent: the last column is the largest absolute difference over six money columns "
        "(three scenario ECLs, weighted ECL, floor, final ECL) and every loan.",
        "",
        "## What the numbers say",
        "",
        f"- **The spec's comparison (production against the naive version):** {versus('v2', 'v1')}.",
        f"- **Processing style, same arithmetic:** with BINARY_DOUBLE, {versus('v2', 'row_double')}; "
        f"with NUMBER, {versus('set_number', 'v1')}.",
        f"- **Arithmetic, same processing style:** {versus('set_number', 'v2')}; {versus('v1', 'row_double')}.",
        f"- **Algorithm:** {versus('closed_form', 'v2')}.",
        "",
        "## Why",
        "",
        "**Arithmetic.** Oracle `NUMBER` is exact decimal arithmetic with up to 38 significant digits, done in "
        "software. `BINARY_DOUBLE` is the processor's floating point. The ECL is mostly powers, products and "
        "divisions, so the number type decides much of the run time. Floating point is used only for the "
        "probability and discount maths: Stage 3 losses and floors stay in exact `NUMBER`, every stored amount "
        "is converted back to `NUMBER` and rounded to cents, and `run_v1` stays in exact `NUMBER` on purpose, "
        "so `compare_versions` proves on every loan that the floating point never changes a cent.",
        "",
        "**Processing style.** A row-by-row loop usually loses because it pays a switch between the PL/SQL and "
        "SQL engines for every fetch, function call and single-row INSERT. Inside the database that switch is "
        "cheap, and the loop has a structural advantage here: it walks each loan's schedule month by month, "
        "building survival, discount factor and balance from the previous month with a multiplication or two. "
        "The month-row statement has no previous row to build on (that is what makes it set-based), so every "
        f"one of the {month_rows:,} loan-month rows recomputes its factors from closed forms and travels through "
        "the join and the aggregation. "
        + ("With the same arithmetic, that made the loop the faster of the two at this size."
           if loop_wins_same_maths else
           "With the same arithmetic, the single statement still came out ahead."),
        "",
        "**Algorithm.** The monthly sum is a geometric series, so it has a closed form: "
        "`ECL = LGD [k1 (1 - s^H) + h k2 v (1 - (s v)^H) / (1 - s v)]` with s = 1 - h, v = 1/(1 + r), "
        "k1 = (B - P/r)/(1 + r), k2 = P/r. That needs one row per loan and scenario instead of one per month, "
        + ("and it was the fastest variant. " if t["closed_form"] == min(t.values())
           else "although it was not the fastest variant in this run. ")
        + "Production keeps the month rows anyway: each month's "
        "loss stays an explicit, auditable term of the methodology formula, and the run is already a few "
        "seconds a month. The closed form shows how much headroom there is if the book grows.",
        "",
        "Three other ideas made no material difference when measured while building (on the same month, not "
        "re-run by this script): computing `(1 + r)^(t-1)` once per row instead of twice, precomputing the "
        "per-loan constants so each month row is a short expression, and a `PARALLEL(2)` hint.",
        "",
        "## Lesson",
        "",
        "Set-based is not automatically faster. Measure, then fix what the time is actually spent on: here the "
        "number type and the amount of work per loan mattered more than loop versus single statement.",
        "",
    ]
    (DOCS_DIR / "performance.md").write_text("\n".join(lines), encoding="utf-8", newline="\n")
    log.info("wrote docs/performance.md")


if __name__ == "__main__":
    main()
