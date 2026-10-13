#!/usr/bin/env bash
# Export one reporting date's reports to reports/YYYYMMDD/:
#   ecl_detail.csv              every loan's ECL (the base for Power BI)
#   ecl_by_stage.csv ...        one CSV per report view (V_ECL_BY_STAGE, ...)
#   ecl_report.html             the management report (python/make_report.py)
#
# SQL*Plus runs inside the container and SPOOLs straight into the bind-mounted
# reports/ folder with SET MARKUP CSV ON.
#
# Usage: scripts/export_reports.sh YYYY-MM-DD
# Exit codes: 0 success, 1 an export failed, 2 bad arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RD="${1:-}"
[[ "$RD" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die 2 "usage: scripts/export_reports.sh YYYY-MM-DD"
stamp="${RD//-/}"
out="$ROOT_DIR/reports/$stamp"
# SPOOL can't create folders, so the host makes it; the container sees it
# at once through the bind mount.
mkdir -p "$out"

run_sql ECL db/reports/export_ecl_detail.sql "$RD" "$stamp"
run_sql ECL db/reports/export_views.sql "$RD" "$stamp"

rows=$(($(wc -l <"$out/ecl_detail.csv") - 1))
loans=$(sql_value ECL "SELECT COUNT(*) FROM ecl_result WHERE reporting_date = DATE '$RD'")
((rows == loans)) || die "ecl_detail.csv has $rows rows but ECL_RESULT has $loans loans for $RD"

"$PYTHON" "$ROOT_DIR/python/make_report.py" --reporting-date "$RD"

files=$(find "$out" -maxdepth 1 -type f | wc -l)
log "exported $files files to reports/$stamp/ (ecl_detail.csv: $rows loans)"
