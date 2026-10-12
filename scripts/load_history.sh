#!/usr/bin/env bash
# Load the one-off history into Oracle and calibrate LGD.
#
#   1. load_params.sh               the LGD calibration reads LGD_MIN_DEFAULTS
#   2. PKG_LOAD.load_history        loans_dev.csv -> LOAN_DEV, portfolio_base.csv -> LOAN_MASTER
#   3. PKG_LGD.calibrate            PARAM_LGD by grade
#
# Then it checks the result: Oracle row counts must equal the CSV line counts
# (minus the header), and every grade must have an LGD between 0 and 1.
# Each step is logged to BATCH_RUN under one run id.
#
# Usage: scripts/load_history.sh
# Exit codes: 0 success, 1 a step or check failed.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

dev_csv="$ROOT_DIR/data/processed/loans_dev.csv"
base_csv="$ROOT_DIR/data/processed/portfolio_base.csv"
for f in "$dev_csv" "$base_csv"; do
  [[ -f "$f" ]] || die "missing $f: run python/prepare_data.py first"
done

require_env APP_USER APP_USER_PASSWORD
wait_for_db 300
run_id=$(sql_value ECL "SELECT pkg_batch_log.new_run_id FROM dual")
log "run $run_id: parameters"
bash "$ROOT_DIR/scripts/load_params.sh" --run-id "$run_id"

log "run $run_id: loading LOAN_DEV and LOAN_MASTER from the processed CSVs"
run_sql ECL - <<SQL
SET FEEDBACK OFF
EXEC pkg_load.load_history($run_id)
SQL

log "run $run_id: calibrating LGD"
run_sql ECL - <<SQL
SET FEEDBACK OFF
EXEC pkg_lgd.calibrate($run_id)
SQL

# ----------------------------------------------------------------- checks
# wc -l counts newline characters: the header line plus one line per loan.
check_count() {
  local table="$1" csv="$2" in_file in_db
  in_file=$(($(wc -l <"$csv") - 1))
  in_db=$(sql_value ECL "SELECT COUNT(*) FROM $table")
  if ((in_db != in_file)); then
    die "$table has $in_db rows but $(basename "$csv") has $in_file"
  fi
  log "check passed: $table $in_db rows = $(basename "$csv") $in_file data lines"
}
check_count loan_dev "$dev_csv"
check_count loan_master "$base_csv"

bad=$(sql_value ECL "SELECT COUNT(*) FROM (SELECT grade FROM loan_master UNION SELECT grade FROM loan_dev) g
                      WHERE NOT EXISTS (SELECT 1 FROM param_lgd p WHERE p.grade = g.grade AND p.lgd BETWEEN 0 AND 1)")
((bad == 0)) || die "$bad grade(s) without an LGD between 0 and 1"
log "check passed: every grade has an LGD between 0 and 1"

run_sql ECL - <<'SQL'
SET FEEDBACK OFF PAGESIZE 50 LINESIZE 120 TAB OFF
COLUMN grade        FORMAT A5   HEADING 'Grade'
COLUMN lgd          FORMAT 0.0000 HEADING 'LGD used'
COLUMN grade_lgd    FORMAT 0.0000 HEADING 'Grade LGD'
COLUMN defaults     FORMAT 999,990 HEADING 'Defaults'
COLUMN ead_total    FORMAT 999,999,999,990 HEADING 'EAD total USD'
COLUMN fallback     FORMAT A8   HEADING 'Fallback'
SELECT grade, lgd, grade_lgd, defaults_count AS defaults, ROUND(ead_total) AS ead_total,
       CASE fallback_flag WHEN 'Y' THEN 'YES' ELSE '-' END AS fallback
  FROM param_lgd
 ORDER BY CASE grade WHEN 'ALL' THEN 'Z' ELSE grade END;
SQL
