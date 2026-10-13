"""Phase 13: build reports/YYYYMMDD/ecl_report.html for one reporting date.

Sections, each backed by a table so nothing can only be read off a chart:
  1. Headline figures for the date, with the change since the previous month
  2. Final ECL and coverage by stage over every month to date (two charts)
  3. Stage migration from the previous month
  4. ECL movement by stage, opening to closing (IFRS 7 layout)
  5. RBI floor impact
  6. Scenario sensitivity
  7. Data quality
Self-contained: inline CSS, inline SVG charts and a few lines of script for
tooltips. Light and dark mode follow the reader's system setting. All numbers
come from the report views (V_ECL_BY_STAGE, V_STAGE_MIGRATION, ...).

Usage: python python/make_report.py --reporting-date YYYY-MM-DD
"""
from __future__ import annotations

import argparse
from datetime import date, datetime
from html import escape

import pandas as pd

from ecl import svgchart
from ecl.config import REPORTS_DIR
from ecl.db import connect, read_frame
from ecl.log import get_logger

log = get_logger("make_report")

STAGE_COLORS = {1: "var(--series-1)", 2: "var(--series-2)", 3: "var(--series-3)"}
STAGE_NAMES = {1: "Stage 1", 2: "Stage 2", 3: "Stage 3"}


def month(d) -> str:
    return pd.Timestamp(d).strftime("%b %Y")


def usd(v) -> str:
    return "" if pd.isna(v) else f"{v:,.2f}"


def table(headers: list[str], rows: list[list], numeric_from: int = 1, row_classes: list[str] | None = None) -> str:
    head = "".join(f'<th class="{"num" if i >= numeric_from else ""}">{escape(h)}</th>' for i, h in enumerate(headers))
    body = []
    for r_i, row in enumerate(rows):
        cls = f' class="{row_classes[r_i]}"' if row_classes and row_classes[r_i] else ""
        cells = "".join(f'<td class="{"num" if i >= numeric_from else ""}">{escape(str(v))}</td>'
                        for i, v in enumerate(row))
        body.append(f"<tr{cls}>{cells}</tr>")
    return f'<div class="table-wrap"><table><thead><tr>{head}</tr></thead><tbody>{"".join(body)}</tbody></table></div>'


def section(key: str, title: str, intro: str, content: str) -> str:
    return (f'<section id="{key}" data-section="{key}"><h2>{escape(title)}</h2>'
            f'<p class="intro">{escape(intro)}</p>{content}</section>')


def load(conn, rd: date) -> dict:
    q = lambda sql: read_frame(conn, sql, {"rd": rd})  # noqa: E731
    data = {
        "by_stage": q("SELECT * FROM v_ecl_by_stage WHERE reporting_date <= :rd ORDER BY reporting_date, stage"),
        "migration": q("SELECT * FROM v_stage_migration WHERE reporting_date = :rd"),
        "movement": q("SELECT * FROM v_ecl_movement WHERE reporting_date = :rd ORDER BY stage"),
        "floors": q("SELECT * FROM v_floor_impact WHERE reporting_date = :rd ORDER BY stage"),
        "scenarios": q("SELECT * FROM v_scenario_sensitivity WHERE reporting_date <= :rd ORDER BY reporting_date"),
        "dq": q("SELECT * FROM v_dq_summary WHERE reporting_date = :rd ORDER BY rule_id"),
        "source": q("SELECT data_source, COUNT(*) AS n FROM loan_snapshot WHERE reporting_date = :rd GROUP BY data_source"),
        "model": q("SELECT DISTINCT model_version FROM pd_score WHERE reporting_date = :rd"),
    }
    if data["by_stage"].empty or (data["by_stage"]["reporting_date"].max() != pd.Timestamp(rd)):
        raise SystemExit(f"no ECL results for {rd}: run the batch for that month first")
    return data


def headline(by_stage: pd.DataFrame, rd: date) -> str:
    totals = by_stage.groupby("reporting_date")[["loans", "balance", "ecl_final"]].sum()
    now = totals.loc[pd.Timestamp(rd)]
    prev = totals.iloc[-2] if len(totals) > 1 else None

    def delta(cur, before, fmt):
        if before is None:
            return '<span class="delta">first month</span>'
        diff = cur - before
        return f'<span class="delta">{"+" if diff >= 0 else "−"}{fmt(abs(diff))} vs {month(totals.index[-2])}</span>'

    coverage, prev_cov = now.ecl_final / now.balance, (prev.ecl_final / prev.balance if prev is not None else None)
    tiles = [
        ("Loans on the book", f"{int(now.loans):,}", delta(now.loans, None if prev is None else prev.loans, lambda v: f"{int(v):,}")),
        ("Outstanding balance", svgchart.money(now.balance), delta(now.balance, None if prev is None else prev.balance, svgchart.money)),
        ("Final ECL", svgchart.money(now.ecl_final), delta(now.ecl_final, None if prev is None else prev.ecl_final, svgchart.money)),
        ("Coverage (ECL ÷ balance)", f"{coverage:.2%}", delta(coverage, prev_cov, lambda v: f"{v * 100:.2f} pts")),
    ]
    return '<div class="tiles">' + "".join(
        f'<div class="tile"><div class="tile-label">{escape(label)}</div><div class="tile-value">{escape(value)}</div>{d}</div>'
        for label, value, d in tiles) + "</div>"


def trend(by_stage: pd.DataFrame) -> str:
    months = sorted(by_stage["reporting_date"].unique())
    labels = [month(m) for m in months]
    pivot = by_stage.pivot(index="reporting_date", columns="stage")
    series_ecl = [{"name": STAGE_NAMES[s], "color": STAGE_COLORS[s],
                   "values": [float(pivot[("ecl_final", s)].get(m, 0) or 0) for m in months]} for s in (1, 2, 3)]
    series_cov = [{"name": STAGE_NAMES[s], "color": STAGE_COLORS[s],
                   "values": [float(pivot[("coverage", s)].get(m, 0) or 0) for m in months]} for s in (1, 2, 3)]
    charts = (
        '<div class="charts">'
        f'<figure><figcaption>Final ECL by stage</figcaption>{svgchart.legend(series_ecl, "rect")}'
        f'{svgchart.stacked_columns("Final ECL by stage and month", labels, series_ecl)}</figure>'
        f'<figure><figcaption>Coverage by stage (ECL ÷ balance)</figcaption>{svgchart.legend(series_cov, "line")}'
        f'{svgchart.lines("Coverage by stage and month", labels, series_cov, y_top=1.0)}</figure>'
        "</div>"
    )
    rows = [[month(r.reporting_date), STAGE_NAMES[r.stage], f"{int(r.loans):,}", usd(r.balance), usd(r.ecl_final),
             f"{r.coverage:.2%}", f"{r.balance_share:.2%}"] for r in by_stage.itertuples()]
    return charts + ('<details><summary>Table view</summary>'
                     + table(["Month", "Stage", "Loans", "Balance (USD)", "Final ECL (USD)", "Coverage", "Share of balance"],
                             rows, numeric_from=2) + "</details>")


def migration(mig: pd.DataFrame, rd: date) -> str:
    froms, tos = ["1", "2", "3", "NEW"], ["1", "2", "3", "EXITED"]
    grid = mig.pivot_table(index="from_stage", columns="to_stage", values="loans", aggfunc="sum", fill_value=0)
    grid = grid.reindex(index=froms, columns=tos, fill_value=0)
    name = {"1": "Stage 1", "2": "Stage 2", "3": "Stage 3", "NEW": "New", "EXITED": "Exited"}
    prev = mig["prev_date"].dropna()
    rows, classes = [], []
    for f in froms:
        row_total = int(grid.loc[f].sum())
        rows.append([f"From {name[f]}"] + [f"{int(grid.loc[f, t]):,}" for t in tos] + [f"{row_total:,}"])
        classes.append("")
    rows.append(["Total"] + [f"{int(grid[t].sum()):,}" for t in tos] + [f"{int(grid.values.sum()):,}"])
    classes.append("total")
    since = month(prev.iloc[0]) if not prev.empty else "before the first month"
    note = (f'<p class="note">Rows: stage at {escape(since)}. Columns: stage at {escape(month(rd))}. '
            "The diagonal is loans that stayed in their stage; New and Exited are loans that joined or left the book "
            "(paid off, written off, or rejected by data quality that month).</p>")
    return table(["Loans"] + [f"To {name[t]}" for t in tos] + ["Total"], rows, numeric_from=1, row_classes=classes) + note


def movement(mov: pd.DataFrame) -> str:
    items = [("opening_ecl", "Opening ECL"), ("new_loans", "New loans"), ("transfers_in", "Transfers in"),
             ("transfers_out", "Transfers out"), ("exits", "Exits"), ("remeasurement", "Remeasurement"),
             ("closing_ecl", "Closing ECL"), ("difference", "Check: opening + movements − closing")]
    by_stage = mov.set_index("stage")
    rows, classes = [], []
    for col, label in items:
        values = [float(by_stage.loc[s, col]) if s in by_stage.index else 0.0 for s in (1, 2, 3)]
        rows.append([label] + [usd(v) for v in values] + [usd(sum(values))])
        classes.append("total" if col in ("opening_ecl", "closing_ecl") else ("check" if col == "difference" else ""))
    return table(["USD", "Stage 1", "Stage 2", "Stage 3", "Total"], rows, numeric_from=1, row_classes=classes)


def floors(fl: pd.DataFrame) -> str:
    rows = [[STAGE_NAMES[r.stage], f"{int(r.loans):,}", f"{int(r.loans_floored):,}", usd(r.model_ecl), usd(r.final_ecl),
             usd(r.ecl_added_by_floors)] for r in fl.itertuples()]
    rows.append(["Total", f"{int(fl.loans.sum()):,}", f"{int(fl.loans_floored.sum()):,}", usd(fl.model_ecl.sum()),
                 usd(fl.final_ecl.sum()), usd(fl.ecl_added_by_floors.sum())])
    return table(["Stage", "Loans", "Loans floored", "Model ECL (USD)", "Final ECL (USD)", "Added by floors (USD)"],
                 rows, row_classes=[""] * (len(rows) - 1) + ["total"])


def scenarios(sc: pd.DataFrame) -> str:
    rows = [[month(r.reporting_date), usd(r.ecl_base), usd(r.ecl_downside), usd(r.ecl_severe), usd(r.ecl_weighted),
             usd(r.ecl_final)] for r in sc.itertuples()]
    return table(["Month", "Base (USD)", "Downside (USD)", "Severe (USD)", "Weighted (USD)", "Final after floors (USD)"], rows)


def data_quality(dq: pd.DataFrame) -> str:
    rows = [[r.rule_id, r.rule_name, r.severity, f"{int(r.errors):,}", f"{r.share_of_rows:.3%}"] for r in dq.itertuples()]
    received = int(dq.rows_received.iloc[0]) if not dq.empty else 0
    return (table(["Rule", "Check", "Severity", "Rows failing", "Share of rows"], rows, numeric_from=3)
            + f'<p class="note">{received:,} rows received. REJECT rows are kept out of the calculation; '
            "WARN rows are loaded with the documented fix.</p>")


CSS = """
:root { color-scheme: light; --surface-1:#fcfcfb; --page:#f9f9f7; --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,0.10);
  --series-1:#2a78d6; --series-2:#eb6834; --series-3:#1baf7a; }
@media (prefers-color-scheme: dark) { :root:where(:not([data-theme="light"])) { color-scheme: dark;
  --surface-1:#1a1a19; --page:#0d0d0d; --ink:#f0efec; --ink-2:#c3c2b7; --muted:#898781; --grid:#2c2c2a;
  --axis:#383835; --border:rgba(255,255,255,0.10); --series-1:#3987e5; --series-2:#d95926; --series-3:#199e70; } }
:root[data-theme="dark"] { color-scheme: dark; --surface-1:#1a1a19; --page:#0d0d0d; --ink:#f0efec; --ink-2:#c3c2b7;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10); --series-1:#3987e5; --series-2:#d95926; --series-3:#199e70; }
* { box-sizing: border-box; }
body { margin:0; background:var(--page); color:var(--ink); font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif; }
main { max-width:1080px; margin:0 auto; padding:24px 16px 48px; }
header h1 { font-size:26px; margin:0 0 4px; font-weight:600; }
header p { margin:0; color:var(--ink-2); }
section { background:var(--surface-1); border:1px solid var(--border); border-radius:10px; padding:20px; margin-top:20px; }
h2 { font-size:18px; margin:0 0 4px; font-weight:600; }
.intro, .note { color:var(--ink-2); margin:0 0 14px; font-size:14px; }
.note { margin:10px 0 0; }
.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:12px; }
.tile { border:1px solid var(--border); border-radius:8px; padding:12px 14px; }
.tile-label { color:var(--ink-2); font-size:13px; }
.tile-value { font-size:26px; font-weight:600; margin:2px 0; }
.delta { color:var(--ink-2); font-size:13px; }
.charts { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,460px),1fr)); gap:20px; }
figure { margin:0; }
figcaption { font-weight:600; font-size:14px; margin-bottom:6px; }
.legend { display:flex; gap:16px; flex-wrap:wrap; font-size:13px; color:var(--ink-2); margin-bottom:4px; }
.legend-item { display:inline-flex; align-items:center; gap:6px; }
.key-rect { width:10px; height:10px; border-radius:2px; display:inline-block; }
.key-line { width:16px; height:2px; border-radius:1px; display:inline-block; }
svg.chart { width:100%; height:auto; display:block; overflow:visible; }
svg .grid { stroke:var(--grid); stroke-width:1; }
svg .axis { stroke:var(--axis); stroke-width:1; }
svg .tick { fill:var(--muted); font-size:11px; font-variant-numeric:tabular-nums; }
svg .value, svg .label { fill:var(--ink-2); font-size:12px; }
svg .line { fill:none; stroke-width:2; stroke-linejoin:round; stroke-linecap:round; }
svg .dot { stroke:var(--surface-1); stroke-width:2; }
svg .crosshair { stroke:var(--axis); stroke-width:1; }
svg .hit { fill:transparent; cursor:crosshair; }
svg .mark { cursor:default; }
svg .mark:hover, svg .mark:focus { opacity:0.8; outline:none; }
svg .hit:focus { outline:none; }
details { margin-top:14px; }
summary { cursor:pointer; color:var(--ink-2); font-size:14px; }
.table-wrap { overflow-x:auto; }
table { border-collapse:collapse; width:100%; font-size:14px; }
th, td { padding:6px 10px; border-bottom:1px solid var(--grid); text-align:left; white-space:nowrap; }
th { color:var(--ink-2); font-weight:600; }
.num { text-align:right; font-variant-numeric:tabular-nums; }
tr.total td { font-weight:600; }
tr.check td { color:var(--ink-2); }
#tip { position:fixed; pointer-events:none; background:var(--surface-1); color:var(--ink); border:1px solid var(--border);
  border-radius:8px; padding:8px 10px; font-size:13px; box-shadow:0 4px 16px rgba(0,0,0,0.12); z-index:10; }
.tip-title { color:var(--ink-2); margin-bottom:4px; }
.tip-row { display:flex; align-items:center; gap:8px; }
.tip-key { width:12px; height:2px; border-radius:1px; display:inline-block; }
.tip-row span:last-child { color:var(--ink-2); }
footer { color:var(--muted); font-size:13px; margin-top:24px; }
"""


def build(rd: date) -> str:
    with connect() as conn:
        d = load(conn, rd)
    sources = ", ".join(f"{r.data_source} ({int(r.n):,} loans)" for r in d["source"].itertuples())
    model = ", ".join(d["model"]["model_version"])
    prev = d["migration"]["prev_date"].dropna()
    since = f"since {month(prev.iloc[0])}" if not prev.empty else "(first month: every loan is new)"
    body = "".join([
        section("headline", f"Headline figures, {month(rd)}", "Final ECL is after RBI floors; changes are against the previous month.",
                headline(d["by_stage"], rd)),
        section("trend", "Final ECL and coverage by stage",
                "Every month to date. Two charts rather than one with two axes: amounts and ratios don't share a scale.",
                trend(d["by_stage"])),
        section("migration", f"Stage migration {since}", "Loans by stage last month (rows) and this month (columns).",
                migration(d["migration"], rd)),
        section("movement", f"ECL movement by stage {since}",
                "Opening to closing ECL. Transfers move a loan's opening ECL between stages; remeasurement is the change in "
                "ECL of loans on both books.", movement(d["movement"])),
        section("floors", "RBI floor impact", "Loans whose final ECL was set by the floor, and what the floors added.",
                floors(d["floors"])),
        section("scenarios", "Scenario sensitivity",
                "Total model ECL under each economic scenario, the probability-weighted ECL and the final ECL after floors.",
                scenarios(d["scenarios"])),
        section("dq", "Data quality", f"Checks on the {month(rd)} file before anything was loaded.", data_quality(d["dq"])),
    ])
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">'
            f"<title>ECL report {rd:%Y-%m-%d}</title><style>{CSS}</style></head><body><main>"
            f"<header><h1>IFRS 9 expected credit loss · {month(rd)}</h1>"
            f"<p>Reporting date {rd:%Y-%m-%d}. Data: {escape(sources)}. PD model {escape(model)}.</p></header>"
            f"{body}"
            f"<footer>Generated {datetime.now():%Y-%m-%d %H:%M} by python/make_report.py. A learning and portfolio "
            "project, not production software: months after March 2019 are simulated, and the RBI rules are applied to "
            "US Lending Club data as an exercise.</footer>"
            f'</main><div id="tip" role="status" hidden></div><script>{svgchart.TOOLTIP_SCRIPT}</script></body></html>')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reporting-date", required=True, type=date.fromisoformat)
    args = parser.parse_args()
    out_dir = REPORTS_DIR / f"{args.reporting_date:%Y%m%d}"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "ecl_report.html"
    path.write_text(build(args.reporting_date), encoding="utf-8", newline="\n")
    log.info("wrote %s", path.relative_to(REPORTS_DIR.parent))


if __name__ == "__main__":
    main()
