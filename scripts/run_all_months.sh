#!/usr/bin/env bash
# Run the monthly batch for every snapshot date waiting in data/incoming, in
# date order, and stop at the first failure. Order matters: each month's
# staging starts from the previous month's assessment.
#
# Usage: scripts/run_all_months.sh
# Exit codes: 0 all months succeeded, 1 a month failed (later months not run).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mapfile -t dates < <(find "$ROOT_DIR/data/incoming" -maxdepth 1 -name 'loan_snapshot_*.csv' -printf '%f\n' |
  sed -E 's/^loan_snapshot_([0-9]{4})([0-9]{2})([0-9]{2})\.csv$/\1-\2-\3/' | grep -E '^[0-9]{4}-' | sort)
((${#dates[@]} > 0)) || die "no loan_snapshot_*.csv in data/incoming (generate them with python/simulate_months.py)"

log "${#dates[@]} month(s) to run: ${dates[*]}"
for d in "${dates[@]}"; do
  if ! bash "$ROOT_DIR/scripts/run_monthly_batch.sh" "$d"; then
    die "the batch for $d failed; later months were not run (restart that month with --from-step)"
  fi
done
log "all ${#dates[@]} months completed"
