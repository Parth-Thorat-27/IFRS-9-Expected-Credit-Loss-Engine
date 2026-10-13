#!/usr/bin/env bash
# The monthly IFRS 9 batch for one reporting date.
#
# Usage: scripts/run_monthly_batch.sh YYYY-MM-DD [--from-step NAME] [--dry-run]
#
#   --from-step NAME   restart a failed run at NAME (earlier steps are skipped;
#                      each step still checks in BATCH_RUN that its
#                      prerequisite succeeded, so a wrong restart point fails)
#   --dry-run          print the plan and exit without running anything
#
# Exit codes: 0 success, 1 a step failed (or the lock is held), 2 bad arguments.
# One log file per run in logs/; every step is also recorded in BATCH_RUN.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STEPS=(preflight params load_snapshot dq load_clean score_pd assign_stages run_ecl
       export_reports archive cleanup_logs summary)
declare -A ABOUT=(
  [preflight]="database reachable, input files present, free disk space, run lock"
  [params]="validate config/ecl_parameters.xml against the XSD, load PARAM_* tables"
  [load_snapshot]="stage the snapshot and control file (external tables -> STG_*)"
  [dq]="control reconciliation, then the data quality rules (stop above DQ_MAX_REJECT_SHARE)"
  [load_clean]="rows with no REJECT error -> LOAN_SNAPSHOT"
  [score_pd]="current and origination 12-month PD -> PD_SCORE (Python)"
  [assign_stages]="stage 1/2/3 with reason codes -> LOAN_STAGE_HISTORY / LOAN_STAGE_CURRENT"
  [run_ecl]="scenario-weighted ECL with RBI floors -> ECL_RESULT (PKG_ECL.run_v2)"
  [export_reports]="CSV exports and the HTML report -> reports/YYYYMMDD/"
  [archive]="gzip the input files into data/archive/"
  [cleanup_logs]="delete logs older than 30 days"
  [summary]="print a summary built from this run's log"
)
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
INCOMING="$ROOT_DIR/data/incoming"
ARCHIVE="$ROOT_DIR/data/archive"

usage() { sed -n '2,13p' "$0"; }

# --------------------------------------------------------------- steps
# Each runs in a child bash with strict mode (see run_step), so the first
# failing command ends the step.

step_preflight() {
  wait_for_db 120
  local stamp="${RD//-/}" f
  for f in "loan_snapshot_$stamp.csv" "control_$stamp.csv"; do
    if [[ ! -f "$INCOMING/$f" && -f "$ARCHIVE/$f.gz" ]]; then
      # A date that was already processed: bring its files back from the archive.
      gzip -dc "$ARCHIVE/$f.gz" >"$INCOMING/$f"
      log "restored $f from data/archive"
    fi
    [[ -f "$INCOMING/$f" ]] || die "input file missing: data/incoming/$f"
  done
  local free_mb
  free_mb=$(df -Pk "$ROOT_DIR" | awk 'NR == 2 { printf "%d", $4 / 1024 }')
  ((free_mb >= MIN_FREE_MB)) || die "only ${free_mb} MB free on the project disk; need ${MIN_FREE_MB} MB"
  log "preflight ok: database reachable, input files present, ${free_mb} MB free"
}

step_params() {
  bash "$ROOT_DIR/scripts/load_params.sh" --run-id "$RUN_ID" --reporting-date "$RD"
}

plsql_step() {
  run_sql ECL - <<SQL
SET FEEDBACK OFF
EXEC $1(DATE '$RD', $RUN_ID)
SQL
}

step_load_snapshot() { plsql_step pkg_load.load_snapshot; }
step_dq() {
  plsql_step pkg_dq.reconcile_control
  plsql_step pkg_dq.run_checks
  local counts
  counts=$(sql_value ECL "SELECT 'rows_received=' || (SELECT COUNT(*) FROM stg_loan_snapshot WHERE reporting_date = DATE '$RD')
    || ' rows_rejected=' || (SELECT COUNT(DISTINCT row_num) FROM dq_error WHERE reporting_date = DATE '$RD' AND severity = 'REJECT')
    FROM dual")
  metric "$counts"
}
step_load_clean() { plsql_step pkg_load.load_clean; }
step_score_pd() { "$PYTHON" "$ROOT_DIR/python/score_pd.py" --reporting-date "$RD" --run-id "$RUN_ID"; }
step_assign_stages() { plsql_step pkg_staging.assign_stages; }
step_run_ecl() {
  plsql_step pkg_ecl.run_v2
  local totals
  totals=$(sql_value ECL "SELECT 'loans=' || COUNT(*) || ' balance=' || TO_CHAR(SUM(balance), 'FM999999999990.00')
    || ' final_ecl=' || TO_CHAR(SUM(ecl_final), 'FM999999999990.00') FROM ecl_result WHERE reporting_date = DATE '$RD'")
  metric "$totals"
}
step_export_reports() { bash "$ROOT_DIR/scripts/export_reports.sh" "$RD"; }

step_archive() {
  mkdir -p "$ARCHIVE"
  local stamp="${RD//-/}" f
  for f in "loan_snapshot_$stamp.csv" "control_$stamp.csv"; do
    # gzip replaces the file with file.gz; then it moves to the archive.
    gzip -f "$INCOMING/$f"
    mv -f "$INCOMING/$f.gz" "$ARCHIVE/"
  done
  log "archived the input files for $RD to data/archive/"
}

step_cleanup_logs() {
  local old
  old=$(find "$ROOT_DIR/logs" -maxdepth 1 -type f -name '*.log' -mtime +30 | wc -l)
  find "$ROOT_DIR/logs" -maxdepth 1 -type f -name '*.log' -mtime +30 -delete
  log "deleted $old log file(s) older than 30 days"
}

# Built from this run's log with grep and awk, as an operator would.
step_summary() {
  echo
  echo "Batch summary for $RD (run $RUN_ID)"
  echo "-----------------------------------------------"
  grep -E '\[(INFO|ERROR)\] STEP [a-z_]+ (done|FAILED)' "$LOG_FILE" |
    awk '{ secs = $NF; sub(/s$/, "", secs); total += secs
           printf "  %-16s %-7s %6ss\n", $5, ($6 == "done" ? "ok" : "FAILED"), secs }
         END { printf "  %-16s %-7s %6ss\n", "total", "", total }'
  echo
  grep -oE 'METRIC .*' "$LOG_FILE" | sed 's/^METRIC /  /' | tr ' ' '\n' | grep -E '=' | sed 's/^/  /' || true
  echo
}

metric() { log "METRIC $*"; }

# --------------------------------------------------------------- BATCH_RUN for bash steps
# PL/SQL and Python steps log themselves; these wrap the steps that only run
# shell commands, so every step of the run appears in BATCH_RUN.
SELF_LOGGING=" load_snapshot dq load_clean score_pd assign_stages run_ecl params "

batch_log_start() {
  sql_value ECL "SELECT pkg_batch_log.start_step($RUN_ID, DATE '$RD', '$(tr '[:lower:]' '[:upper:]' <<<"$1")') FROM dual"
}
batch_log_end() {
  local message="${4//\'/\'\'}"
  run_sql ECL - >/dev/null <<SQL
EXEC pkg_batch_log.end_step($1, '$2', NULL, '${message:0:3900}')
SQL
}

# --------------------------------------------------------------- running a step
run_step() {
  local name="$1" started=$SECONDS step_id="" rc=0
  log "STEP $name started: ${ABOUT[$name]}"
  if [[ "$SELF_LOGGING" != *" $name "* && "$name" != preflight ]]; then
    step_id=$(batch_log_start "$name")
  fi
  # A child bash: inside it set -e works normally. (Bash ignores set -e in
  # any function whose exit status the caller tests, so calling the step
  # function directly in an if would let a failed command carry on.)
  bash "$0" --internal-step "$name" "$RD" "$RUN_ID" || rc=$?
  local secs=$((SECONDS - started))
  if ((rc == 0)); then
    log "STEP $name done in ${secs}s"
    [[ -z "$step_id" ]] || batch_log_end "$step_id" SUCCESS "" "$name done in ${secs}s"
  else
    log ERROR "STEP $name FAILED in ${secs}s (exit $rc)"
    [[ -z "$step_id" ]] || batch_log_end "$step_id" FAILED "" "$name failed (exit $rc); see $(basename "$LOG_FILE")"
    log ERROR "run stopped. Fix the cause, then restart with: scripts/run_monthly_batch.sh $RD --from-step $name"
    exit 1
  fi
}

# --------------------------------------------------------------- locking
LOCK_FILE="$ROOT_DIR/logs/.batch.lock"
LOCK_DIR="$ROOT_DIR/logs/.batch.lock.d"

take_lock() {
  if command -v flock >/dev/null 2>&1; then
    # The kernel releases an flock when the process ends, even after kill -9,
    # so a crash can never leave a stale lock behind. Steps inherit
    # descriptor 9, so if this run is killed, the lock stays held until the
    # step it was running has finished as well.
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another batch run holds the lock ($LOCK_FILE); wait for it to finish"
  else
    # Git Bash has no flock. mkdir is atomic: exactly one process can create
    # the directory. The PIDs inside let a later run spot a stale lock left
    # by a crashed run.
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      local holder step
      holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
        die "another batch run (pid $holder) holds the lock ($LOCK_DIR); wait for it to finish"
      fi
      # Killing a run doesn't kill the step it started: that child carries on
      # alone. Restarting now would run two steps on the same date at once.
      step=$(cat "$LOCK_DIR/step_pid" 2>/dev/null || echo "")
      if [[ -n "$step" ]] && kill -0 "$step" 2>/dev/null; then
        die "the run holding the lock has gone, but its step (pid $step) is still running; wait for it to finish, then restart"
      fi
      log WARN "removing a stale lock left by pid ${holder:-unknown}, which is no longer running"
      rm -f "$LOCK_DIR/pid" "$LOCK_DIR/step_pid"
      rmdir "$LOCK_DIR"
      mkdir "$LOCK_DIR" || die "could not take the lock ($LOCK_DIR)"
    fi
    echo "$$" >"$LOCK_DIR/pid"
    LOCK_HELD="mkdir"
    # Each step writes its own PID here (see the child mode below).
    export STEP_PID_FILE="$LOCK_DIR/step_pid"
  fi
}

LOCK_HELD=""
on_exit() {
  local rc=$?
  if [[ "$LOCK_HELD" == mkdir ]]; then
    rm -f "$LOCK_DIR/pid" "$LOCK_DIR/step_pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  # The documented exit codes: 0 success, 2 bad arguments, 1 anything else
  # (a failed step, a held lock, an unreachable database).
  if ((rc != 0 && rc != 2)); then exit 1; fi
}

# --------------------------------------------------------------- arguments
if [[ "${1:-}" == --internal-step ]]; then
  # Child mode (see run_step): run exactly one step and exit with its status.
  # Arguments: --internal-step NAME YYYY-MM-DD RUN_ID
  step_name="$2" RD="$3" RUN_ID="$4"
  LOG_FILE="${LOG_FILE:-}"
  if [[ -n "${STEP_PID_FILE:-}" ]]; then echo "$$" >"$STEP_PID_FILE"; fi
  "step_$step_name"
  exit 0
fi

RD="" FROM_STEP="" DRY_RUN=false
while (($# > 0)); do
  case "$1" in
    --from-step) [[ -n "${2:-}" ]] || die 2 "--from-step needs a step name"; FROM_STEP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die 2 "unknown option '$1'" ;;
    *) [[ -z "$RD" ]] || die 2 "only one reporting date, please"; RD="$1"; shift ;;
  esac
done
[[ -n "$RD" ]] || { usage >&2; die 2 "reporting date missing"; }
[[ "$RD" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$(date -d "$RD" +%F 2>/dev/null)" == "$RD" ]] \
  || die 2 "not a valid date: $RD (use YYYY-MM-DD)"
start_index=0
if [[ -n "$FROM_STEP" ]]; then
  for i in "${!STEPS[@]}"; do [[ "${STEPS[$i]}" == "$FROM_STEP" ]] && start_index=$i; done
  [[ "${STEPS[$start_index]}" == "$FROM_STEP" ]] || die 2 "unknown step '$FROM_STEP' (steps: ${STEPS[*]})"
fi

if $DRY_RUN; then
  echo "Plan for $RD$([[ -n "$FROM_STEP" ]] && echo " (restart at $FROM_STEP)"):"
  for i in "${!STEPS[@]}"; do
    if ((i < start_index)); then
      printf '  %2d. %-15s skipped (before --from-step)\n' $((i + 1)) "${STEPS[$i]}"
    else
      printf '  %2d. %-15s %s\n' $((i + 1)) "${STEPS[$i]}" "${ABOUT[${STEPS[$i]}]}"
    fi
  done
  exit 0
fi

# --------------------------------------------------------------- the run
mkdir -p "$ROOT_DIR/logs"
LOG_FILE="$ROOT_DIR/logs/batch_${RD//-/}_$(date +%Y%m%d_%H%M%S).log"
export LOG_FILE RD
trap on_exit EXIT
log "batch for $RD started (log $(basename "$LOG_FILE"))"
take_lock
require_env APP_USER APP_USER_PASSWORD
# The run id is taken after preflight's database check when starting from the
# top; a restart needs the database anyway.
((start_index == 0)) && run_step_preflight_first=true || run_step_preflight_first=false
if $run_step_preflight_first; then
  RUN_ID=0
  run_step preflight
  start_index=1
fi
RUN_ID=$(sql_value ECL "SELECT pkg_batch_log.new_run_id FROM dual")
export RUN_ID
log "run id $RUN_ID"

for ((i = start_index; i < ${#STEPS[@]}; i++)); do
  run_step "${STEPS[$i]}"
done
log "batch for $RD finished"
