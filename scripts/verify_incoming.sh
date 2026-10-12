#!/usr/bin/env bash
# Check every snapshot in data/incoming against its control file using only
# Unix tools: the row count with wc -l, the total balance with awk. This is
# the same test the batch's control reconciliation does inside Oracle, done
# on the file before it is loaded.
#
# Usage: scripts/verify_incoming.sh [YYYYMMDD ...]   (default: every snapshot present)
# Exit codes: 0 all match, 1 a file doesn't match its control file.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

incoming="$ROOT_DIR/data/incoming"
if (($# > 0)); then
  stamps=("$@")
else
  mapfile -t stamps < <(find "$incoming" -maxdepth 1 -name 'loan_snapshot_*.csv' -printf '%f\n' |
    sed -E 's/loan_snapshot_([0-9]{8})\.csv/\1/' | sort)
fi
((${#stamps[@]} > 0)) || die "no loan_snapshot_*.csv files in $incoming"

failed=0
printf '%-10s %9s %9s %18s %18s  %s\n' date rows control balance control result
for stamp in "${stamps[@]}"; do
  snapshot="$incoming/loan_snapshot_$stamp.csv"
  control="$incoming/control_$stamp.csv"
  [[ -f "$snapshot" && -f "$control" ]] || die "missing snapshot or control file for $stamp"

  rows=$(($(wc -l <"$snapshot") - 1))            # minus the header line
  # Sum in integer cents so 100,000 additions can't drift by a cent.
  balance=$(awk -F, 'NR > 1 { cents += sprintf("%.0f", $5 * 100) } END { printf "%.2f", cents / 100 }' "$snapshot")
  IFS=, read -r _ ctl_rows ctl_balance < <(sed -n '2p' "$control")

  if [[ "$rows" == "$ctl_rows" && "$balance" == "$ctl_balance" ]]; then
    result=OK
  else
    result=MISMATCH
    failed=1
  fi
  printf '%-10s %9s %9s %18s %18s  %s\n' "$stamp" "$rows" "$ctl_rows" "$balance" "$ctl_balance" "$result"
done
((failed == 0)) || die "at least one file does not match its control file"
log "all ${#stamps[@]} snapshot files match their control files"
