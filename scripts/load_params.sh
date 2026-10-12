#!/usr/bin/env bash
# Validate config/ecl_parameters.xml against its XSD, then load it into the
# PARAM_* tables with PKG_PARAMS. Validation runs first, so a broken file
# never reaches the database.
#
# Usage: scripts/load_params.sh [--run-id N] [--reporting-date YYYY-MM-DD]
#   Both options are passed by the monthly batch so the step is logged under
#   its run; run on its own, the load gets a run id of its own.
# Exit codes: 0 loaded, 1 validation or load failed, 2 bad arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

run_id="NULL" reporting_date="NULL"
while (($# > 0)); do
  case "$1" in
    --run-id) [[ "${2:-}" =~ ^[0-9]+$ ]] || die 2 "--run-id needs a number"; run_id="$2"; shift 2 ;;
    --reporting-date)
      [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die 2 "--reporting-date needs YYYY-MM-DD"
      reporting_date="DATE '$2'"; shift 2 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die 2 "unknown option '$1'" ;;
  esac
done

xml="$ROOT_DIR/config/ecl_parameters.xml"
log "validating $(basename "$xml") against the XSD"
"$PYTHON" "$ROOT_DIR/python/ecl/validate_xml.py" "$xml" --xsd "$ROOT_DIR/config/ecl_parameters.xsd"

log "loading parameters into the PARAM_* tables"
run_sql ECL - <<SQL
SET FEEDBACK OFF
EXEC pkg_params.load_from_xml('ecl_parameters.xml', $run_id, $reporting_date)
SQL
summary=$(sql_value ECL "SELECT message FROM batch_run WHERE batch_run_id = (SELECT MAX(batch_run_id) FROM batch_run WHERE step_name = 'LOAD_PARAMS')")
log "parameters loaded: $summary"
