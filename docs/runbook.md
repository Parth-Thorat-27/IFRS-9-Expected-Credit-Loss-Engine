# Runbook

How to run the monthly batch, check it, restart it, and what to do when it
stops. The messages quoted below were copied from real runs of this project,
including the test suite's deliberately broken files.

## Running

The database must be up: `docker compose up -d`, then `docker compose ps`
should show `ecl-oracle` as `healthy`.

```bash
scripts/run_monthly_batch.sh 2019-09-30 --dry-run    # print the plan, run nothing
scripts/run_monthly_batch.sh 2019-09-30              # one reporting date
scripts/run_all_months.sh                            # every date waiting in data/incoming, oldest first
```

The batch runs these steps in order, each in its own child process:

| Step | What it does |
|---|---|
| `preflight` | Database reachable, input files present (restored from `data/archive/` if the date was processed before), at least 1 GB free (`MIN_FREE_MB`), run lock taken |
| `params` | Validates `config/ecl_parameters.xml` against the XSD, loads the `PARAM_*` tables |
| `load_snapshot` | External tables → `STG_LOAN_SNAPSHOT` and `STG_CONTROL` |
| `dq` | Control reconciliation, then the data quality rules |
| `load_clean` | Rows with no REJECT error → `LOAN_SNAPSHOT` |
| `score_pd` | Origination and current 12-month PD → `PD_SCORE` (Python) |
| `assign_stages` | Stage 1/2/3 with reason codes → `LOAN_STAGE_HISTORY`, `LOAN_STAGE_CURRENT` |
| `run_ecl` | Scenario-weighted ECL with RBI floors → `ECL_RESULT` (`PKG_ECL.run_v2`) |
| `export_reports` | CSV exports and the HTML report → `reports/YYYYMMDD/` |
| `archive` | Gzips the date's input files into `data/archive/` |
| `cleanup_logs` | Deletes `logs/*.log` older than 30 days |
| `summary` | Prints step times and the key figures, read back from the log |

Exit codes: 0 success, 1 a step failed or the lock is held, 2 bad arguments.

## Checking a run

- **The summary** at the end of the run lists each step's time, the rows received and rejected, the loans, the balance and the final ECL.
- **The log:** `logs/batch_YYYYMMDD_<started>.log`, one per run. `grep -E 'ERROR|WARN' logs/batch_*.log` finds problems.
- **In Oracle:** every step has a row in `BATCH_RUN`, with status, timings, row count and message.

  ```sql
  SELECT * FROM v_batch_status WHERE reporting_date = DATE '2019-09-30';
  SELECT step_name, status, elapsed_seconds, rows_processed, message
    FROM batch_run WHERE run_id = :run_id ORDER BY batch_run_id;
  ```

  For a SQL prompt, run `docker exec -it ecl-oracle sqlplus ECL@FREEPDB1` (in Git Bash, put `winpty` in front). It asks for `APP_USER_PASSWORD` from `.env`.
- **External table problems** leave `logs/ext_loan_snapshot.log` and `.bad` files. The log shows what the access driver read and rejected.

## Restarting

When a step fails, the batch stops and prints the command to resume:

```
[ERROR] run stopped. Fix the cause, then restart with: scripts/run_monthly_batch.sh 2019-09-30 --from-step score_pd
```

- `--from-step` skips the steps before the one named. Each database step still checks in `BATCH_RUN` that the step before it succeeded for the date. Restarting too late fails at once: `ORA-20005: step RECONCILE_CONTROL has not succeeded for 2000-02-29 since its snapshot was last loaded; run the batch from that step`. That message came from the test suite's truncated file. Restart from the step it names.
- A restart doesn't run `preflight`, so it doesn't bring archived input files back. A failed run never reaches `archive`, so its files are still in `data/incoming`. To redo a date that already finished, run it from the top instead: preflight restores the files.
- Re-running a whole date is safe. Each step replaces that date's rows, and staging starts again from the previous month's assessment, so a re-run gives identical results (`tests/test_batch_rerun.py`). Re-running an *older* month while later months exist rebuilds only that month's staging history. Then re-run the later months too, in date order.
- Start over completely with `scripts/setup_db.sh --reset`, then follow the README from `load_history.sh`. `--reset` drops every table, including the audit tables.

## When the batch stops

### Database not ready

```
[ERROR] database not ready after 120s (check: docker logs ecl-oracle)
```

**Cause:** the container is stopped or still starting. The first start creates the database and takes a few minutes; later starts are quicker. Docker Desktop itself may not be running.
**Fix:** `docker compose up -d`, then wait until `docker compose ps` shows `healthy`. If it never does, read `docker logs ecl-oracle`. Then rerun the date: nothing was done yet.

### ORA-29913 or file not found on an external table

```
ORA-29913: error while processing ODCIEXTTABLEOPEN routine
ORA-29400: data cartridge error
KUP-04040: file loan_snapshot_20191031.csv in ECL_INCOMING_DIR not found
```

**Cause:** the file isn't where Oracle looks. Either the name is wrong (it must be `loan_snapshot_YYYYMMDD.csv` and `control_YYYYMMDD.csv` for the reporting date), the file is missing (archived by an earlier run, see Restarting), or the container can't see the mounted folder. Oracle reads `/opt/ecl/data/incoming` inside the container, which `docker-compose.yml` mounts from `data/incoming`.
**Fix:** compare `ls data/incoming` with `docker exec ecl-oracle ls /opt/ecl/data/incoming`. If the container's list is empty or different, the bind mount is broken. Check the Docker Desktop file sharing settings and run `docker compose up -d` from the project folder. Then rerun from `load_snapshot`.

### Permission denied on a directory object

```
ORA-06564: Object ECL_INCOMING_DIR does not exist or is not accessible to the user.
```

**Cause:** the ECL account lacks the grant on the directory object, or the directory was never created. `db/00_directories.sql` creates the four directory objects as SYSTEM and grants READ (and WRITE on `ECL_LOG_DIR`). An `ORA-29913` whose `KUP-` line says a file can't be opened or written points to folder permissions instead. The `oracle` user inside the container must be able to read `data/incoming` and write `logs/`.
**Fix:** run `scripts/setup_db.sh` on an empty schema, or run the `GRANT` lines from `db/00_directories.sql` as SYSTEM. Check with `SELECT * FROM all_tab_privs WHERE table_name LIKE 'ECL%DIR'`. On a Linux host, make `data/incoming` readable and `logs/` writable for the container's user. Then rerun from `load_snapshot`.

### Control total mismatch

```
ORA-20030: control totals do not match: staged 1,991 rows and balance 6,484,396.28, but control_20000229.csv
expects 2,001 rows and 6,535,918.38 (10 rows missing). The file is truncated or is not the file the control
describes: get a fresh copy; never force the load.
```

**Cause:** the snapshot is truncated, or it isn't the file the control file describes. The message above is from `tests/test_dq.py`, which cuts the last 10 lines off a test file.
**Fix:** check the file before loading it with `scripts/verify_incoming.sh 20190930`. It compares the row count (`wc -l`) and the balance total (`awk`) with the control file. Get a fresh copy from the source and rerun from `load_snapshot`. Never edit the control file to make the totals match.

### XSD validation failure

```
INVALID config/ecl_parameters.xml against config/ecl_parameters.xsd:
  line 23: Element 'scenario', attribute 'weight': 'ten' is not a valid value of the atomic type 'unitDecimal'.
```

**Cause:** the parameter file breaks its schema. The batch stops before anything reaches the database. Rules the XSD can't express are checked by `PKG_PARAMS`, which stops with `ORA-20010: parameter file rejected: ...`. Examples: scenario weights that don't add up to 1, or a missing floor.
**Fix:** correct `config/ecl_parameters.xml`, then `scripts/run_monthly_batch.sh DATE --from-step params`. Every value that changes is recorded in `PARAM_AUDIT`.

### Lock already held

```
[ERROR] another batch run (pid 314) holds the lock (.../logs/.batch.lock.d); wait for it to finish
```

**Cause:** another run is active. Only one batch may run at a time.
**Fix:** wait for it to finish. `ls -t logs/batch_*.log | head -1` shows the newest log.

A crash leaves a **stale lock** behind:

- **Linux and WSL (`flock`):** the kernel releases the lock when the process dies.
- **Git Bash (`mkdir` lock):** the next run checks the PID in the lock folder and clears the lock itself, printing `[WARN] removing a stale lock left by pid 2174, which is no longer running`.

If the killed run left a step working on its own, the next run waits for it:

```
[ERROR] the run holding the lock has gone, but its step (pid 823) is still running; wait for it to finish, then restart
```

Remove `logs/.batch.lock.d` by hand only if you are sure no batch or step is running. Windows can reuse a dead process's PID, which is the one case where the automatic check can be fooled.

### Reject share above the threshold

```
ORA-20031: rejected 84 of 83,804 rows (0.100%), above DQ_MAX_REJECT_SHARE 0.050%: check V_DQ_SUMMARY, fix the
source, rerun the date
```

**Cause:** too much of the file failed data quality, so the whole month is stopped rather than loaded with holes in it. This message comes from September 2019 with the limit lowered to 0.05% to show it; at the configured 1% the month passes.
**Fix:** see which rules failed and on which rows:

```sql
SELECT * FROM v_dq_summary WHERE reporting_date = DATE '2019-09-30' ORDER BY errors DESC;
SELECT row_num, rule_id, column_name, bad_value, message FROM dq_error
 WHERE reporting_date = DATE '2019-09-30' AND severity = 'REJECT' ORDER BY row_num;
```

Fix the source and get a corrected file, then rerun the date from the top. Change the threshold in the XML only if the business agrees the limit itself was wrong.

## Other things seen while building

- **A step takes far longer than usual.** On a laptop, look for sleep first. One `run_ecl` step recorded 4,767 s because Windows went into Modern Standby mid-step: the power log showed a 79-minute sleep, and `V$SQL` showed the statement itself used about 6 s. Keep the machine awake during a run.
- **A syntax error in a step that worked before.** Someone edited a script while the batch was running it. Bash reads a script as it runs, so it read part of the old file and part of the new one. Never edit scripts mid-run. Restart from the failed step.
- **`score_pd` refuses to run** with `models/pd_model.joblib is ... but the active model is ...: retrain or reactivate`. The saved model and `MODEL_REGISTRY` disagree. Run `python python/train_pd_model.py`.
- **`ORA-20041: ECL_RESULT got N rows ... but M loans were scored`.** Some loans found no LGD or floor. Check that `PARAM_LGD` covers every grade and `PARAM_FLOOR` every stage, then rerun from `run_ecl`.
