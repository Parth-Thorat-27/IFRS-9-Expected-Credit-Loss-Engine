# Decisions and changes from the spec

Every place the build differs from [SPEC.md](SPEC.md), and why. Newest entries
go at the bottom. Each entry gives the phase, what the spec says, what was done
instead, and the reason.

## Environment recorded in Phase 1

| Item | Value |
|---|---|
| Host | Windows 11 Home (10.0.26200) |
| Docker | Docker Desktop, engine 29.2.1, Compose v5.0.2, WSL2 backend (16 CPUs, 8 GB visible to Docker) |
| Database | `gvenzl/oracle-free:23.26.3`, banner "Oracle AI Database 26ai Free Release 23.26.3.0.0", service `FREEPDB1` |
| Python | 3.11.9 (Windows), project venv in `.venv/` |
| Shell | Git Bash: GNU bash 5.3.9 (ships with Git for Windows 2.54) |

---

## D-001 · Phase 1 · Bash runs from Git Bash until Ubuntu is installed in WSL

- **Spec:** on Windows, install WSL2 with Ubuntu and run everything from the Ubuntu terminal.
- **Found:** WSL2 is enabled (Docker Desktop uses it), but the only distribution is Docker's internal `docker-desktop`; there is no Ubuntu. Installing one is a system-wide change, which the build rules say to ask about first.
- **Done instead:** Phase 1 runs its bash scripts from Git Bash and Python from a Windows venv. The scripts stay portable so they run unchanged on Linux or WSL later:
  - `MSYS_NO_PATHCONV=1` stops Git Bash rewriting container paths such as `/opt/ecl/db` or `/nolog` before they reach `docker exec`;
  - with that rewriting off, `ROOT_DIR` is kept in `C:/Users/...` form (`cygpath -m`) so `python.exe` and `docker.exe` read paths correctly (without it Python looked for `C:\c\Users\...`);
  - `PYTHON` is found in `.venv/bin` (Linux) or `.venv/Scripts` (Windows);
  - `.env` is read with carriage returns stripped.
- **Decided after Phase 1:** stay on Git Bash for the whole build, so nothing is installed system-wide. Git Bash has no `flock` and no `cron`, so Phase 12 uses `flock` when it exists (Linux, WSL) and otherwise falls back to an atomic `mkdir` lock with the same behaviour. Cron is shipped as `scripts/crontab.example` and documented, but not scheduled on this machine. The spec says as much: the demo dates are historical, and `run_all_months.sh` is how the project actually runs.

## D-002 · Phase 1 · SPEC.md transcribed from the PDF

- **Spec:** the owner exports the doc as Markdown and saves it as `SPEC.md`.
- **Done instead:** no Markdown export was in the folder, so `docs/SPEC.md` was transcribed from the 32 PDF pages. The pipeline diagram became a Mermaid chart and the formulas became GitHub math blocks. The Uniqus and ICRA links were not recoverable from the page images and appear as plain citations.

## D-003 · Phase 1 · One settings file: `config/settings.json`

- **Spec:** the Data section says the roll-rate matrix is kept in `config/simulation.json`; the Repository layout and Configuration sections put it in `config/settings.json`.
- **Done:** `config/settings.json` only, because two of the three mentions and the full JSON example use that name.

## D-004 · Phase 1 · Pinned image tag and a fixed container name

- **Spec:** "regular `gvenzl/oracle-free` image", service `ecl-oracle`.
- **Done:** image pinned to `gvenzl/oracle-free:23.26.3` (the regular flavour; `-slim` drops XML DB and external tables). Without a pin, `latest` could change the database release between two runs of the same project. `container_name: ecl-oracle` makes the container name match the service, so scripts can run `docker exec ecl-oracle` directly.

## D-005 · Phase 1 · `./db` and `./config` are mounted read-only

- **Spec:** bind mounts for `./db`, `./config`, `./data/incoming` and `./data/processed`.
- **Done:** all four, with `db` and `config` read-only (`:ro`). The database only reads SQL scripts and the XML config, so nothing inside the container can change them. The two data folders stay read-write because external tables write `.log` and `.bad` files next to the CSVs they read.

## D-006 · Phase 1 · Small additions not named in the spec

- `.gitattributes` forces LF line endings. Git for Windows converts to CRLF on checkout by default, and a CRLF bash script or SQL file fails inside Linux.
- `python-dotenv` was added to `requirements.txt` so `python/ecl/db.py` reads the same `.env` as Docker Compose and bash.
- The Phase 1 smoke check is `scripts/smoke_test.sh` plus `python/smoke_db.py`; the spec asks for "a smoke script" without naming it.
- `run_sql` checks the SQL*Plus output as well as the exit code, because `WHENEVER SQLERROR` misses three kinds of failure: SQL*Plus's own `SP2-` errors, "created with compilation errors" warnings, and exit codes that wrap to 0 (the code is SQLCODE mod 256, so ORA-01536 would exit 0). It filters the output as a stream instead of writing a temp file, so a killed run leaves nothing behind.
- `run_sql` sends the password on stdin (`sqlplus /nolog` then `CONNECT`), so it never appears on a command line inside the container.

## D-007 · Phase 2 · Data downloaded from Kaggle's public endpoint

- **Spec:** the owner downloads the file from Kaggle with a free account, because Claude Code can't log in.
- **Done instead:** Kaggle's dataset download URL (`https://www.kaggle.com/api/v1/datasets/download/wordsforthewise/lending-club`) answered without a login and redirected to the bundle on Google Cloud Storage (1,356,507,910 bytes). Only `accepted_2007_to_2018Q4.csv` (1,675,133,810 bytes, 2,260,701 data lines) was extracted into `data/raw/`; the zip and the "rejected" files were discarded.

## D-008 · Phase 2 · Base reporting date is 2019-03-31

- **Spec:** base reporting date = month-end of the latest `last_pymnt_d` in the file; check it and record it here.
- **Result:** the latest `last_pymnt_d` is Mar-2019, so the base reporting date is **2019-03-31**. Check: 833,650 of the 912,609 open loans in the file made their last payment in Mar-2019, so the date matches the state of the book. `settings.json` keeps `base_reporting_date: null`.

## D-009 · Phase 2 · Small data-preparation choices

- `int_rate` and `revol_util` are stored as fractions (13.99% becomes 0.1399), because the ECL formulas use r = `int_rate` / 12 directly.
- The log features use `log1p` (log of 1 + x) instead of `log`: `annual_inc` and `revol_bal` both contain genuine zeros, and log(0) is undefined.
- Processed files rename `id` to `loan_id` and `term` to `term_months` (an integer), so the database columns say what they hold.
- `sub_grade` and `addr_state` are kept for reporting but are not model features. The spec's one-hot list doesn't include them, and `sub_grade` only refines `grade` and `int_rate`, which the model already has.
- Remaining term is counted in calendar months between the issue month and the base month.
- The live-book sample keeps the status mix exactly. Each status gets its proportional share, and the largest remainders absorb the rounding so the total is exactly 100,000.
- Each random step (dev sample, live sample, starting DPD) has its own seeded stream, so changing one can't silently change the others.

## D-010 · Phase 3 · Directory objects in their own script, run as SYSTEM

- **Spec:** `db/04_directories_external_tables.sql` holds both the directory objects and the external tables; `setup_db.sh` runs the directory part as SYSTEM and the rest as ECL.
- **Done instead:** two files. `db/00_directories.sql` (directories and grants, run as SYSTEM, first) and `db/04_external_tables.sql` (external tables, run as ECL). A single SQL*Plus script can't switch accounts without a password written in the file.
- **Also:** a fourth directory, `ECL_LOG_DIR`, over a new bind mount `./logs:/opt/ecl/logs`. The external-table access driver writes its `.log` and `.bad` files there, next to the batch logs, instead of filling `data/incoming` with them. The data directories are granted READ only.

## D-011 · Phase 3 · External tables are documented in EXT_TABLE_DOC

- **Spec:** `COMMENT ON TABLE` / `COMMENT ON COLUMN` for every table and column; a query on `USER_TAB_COMMENTS` and `USER_COL_COMMENTS` returns nothing uncommented.
- **Found:** Oracle 23.26 rejects both statements for external tables with ORA-30657 ("operation not supported on external organized table"), yet still lists their 83 columns in `USER_COL_COMMENTS` with empty comments.
- **Done instead:** their descriptions go into a small table, `EXT_TABLE_DOC`. The view `V_DATA_DICTIONARY` merges them with the normal comments, and the data dictionary generator reads that view. The Phase 3 check showed 0 uncommented normal tables, views or columns, and 0 undocumented columns in the merged view (370 columns in total).

## D-012 · Phase 3 · Extra tables: LOAN_STAGE_HISTORY, MONTH_IDX

- `LOAN_STAGE_HISTORY` keeps the stage decision for every loan and month, with the cure counter and stage dates. Each month's assessment starts from the previous month's row there, not from `LOAN_STAGE_CURRENT`. Re-running a month therefore gives the same answer instead of counting a cure month twice, as the "every script must be re-runnable" rule requires. `LOAN_STAGE_CURRENT` is still the latest stage per loan and still carries the audit trigger.
- `MONTH_IDX` (months 1 to 60) is the row source that `run_v2` joins to. The spec allows either it or `CONNECT BY LEVEL`; a real table gives the optimizer an accurate row count.
- `PKG_BATCH_LOG` and `BATCH_RUN` were built in Phase 3 rather than Phase 8, because the Phase 4 history load already logs to `BATCH_RUN`.

## D-013 · Phase 3 · Constraints that enforce the ECL rules

Beyond the spec's checks (stage 1-3, PD and LGD 0-1, Y/N flags), two check constraints enforce the floor logic on every ECL row:

- `ecl_final = GREATEST(ecl_weighted, floor_amount)`;
- `floor_applied = 'Y'` exactly when `floor_amount > ecl_weighted`.

With these in place, the Phase 11 check "floor_applied is Y exactly where the floor won" is guaranteed by the database, not just tested once.

## D-014 · Phase 3 · Shell and SQL*Plus details found while testing

- `@@packages/x.pks` inside `install.sql` failed with SP2-0310. SQL*Plus resolves `@@file` against the calling script's folder, but `@@folder/file` against its own working directory. `run_sql` now starts SQL*Plus in the script's folder (`docker exec -w`), so both forms mean "relative to this script". Run without `WHENEVER OSERROR`, the same failure only printed SP2 warnings and the install "succeeded" with exit code 0. That is the blind spot `run_sql`'s output scan exists for.
- A failing `$(...)` inside another command's arguments (`log "... $(sql_value ...)"`) does not stop a `set -e` script; only a failing assignment does. Scripts assign first and use the variable after, and `common.sh` sets `shopt -s inherit_errexit`.
- `WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK` (with an explicit ROLLBACK) is used, so a failed script never commits half its work on the way out.

## D-015 · Phase 6 · Built before Phases 4 and 5

- **Spec:** the phases run in order 1 to 14.
- **Done instead:** Phase 6 (XML parameters) was built straight after Phase 3. LGD calibration (Phase 4) needs `LGD_MIN_DEFAULTS`, and scoring the live book (Phase 5) needs `PD_FLOOR`. Both come from the XML config under the rule that nothing in the PL/SQL is hardcoded. The full run order is therefore: `setup_db.sh`, `load_params.sh`, `load_history.sh`, `train_pd_model.py`, `simulate_months.py`, `run_all_months.sh`.

## D-016 · Phase 6 · Parameter-loading details

- `PKG_PARAMS` has two entry points. `load_from_xml` reads the file through the `ECL_CONFIG_DIR` BFILE, as the spec says. `load_from_clob` takes the same XML as text, so tests can load deliberately broken copies without writing files into the read-only `config/` mount. Both call the same validation and MERGE code.
- PL/SQL checks run before anything is written, so a bad file never leaves a half-loaded set:
  - scenario weights sum to 1 (to 1e-9);
  - every setting the engine reads is present;
  - stage 1 and 2 floors carry `restructured` and stage 3 floors a months band;
  - every floor case exists;
  - DPD bands start at 0 and don't overlap.
- The XSD marks `restructured` and `monthsInStage3From`/`To` as optional, because the spec's own XML uses them only on some `floor` rows. XSD 1.0 can't say "required when stage is 3", so that rule is one of the PL/SQL checks above.
- A fourth audit trigger covers `PARAM_DPD_MULTIPLIER`. The spec names three tables, but the DPD multipliers are business parameters too.
- Audit rows are written only for values that really change. A reload rewrites every row, so without that filter each load would log every parameter as "changed".
- `scripts/load_params.sh` validates then loads, and is shared by the history load and the monthly batch.
- Stage 3 floor bands are half-open: `monthsInStage3From` is inclusive and `monthsInStage3To` is exclusive. Months 0-11 get 40% and month 12 onwards gets 100%. The spec says "up to 1 year" and "over 1 year", which leaves the exact 12-month point open, so this convention is a choice.

## D-017 · Phase 5 · PD model choices

- **Numeric features are capped at the training 1st and 99th percentiles before scaling (winsorising).** Without the caps, the first model scored 214 live loans at a 12-month PD of 50% or more, up to 0.9884. They had `dti = 999`, Lending Club's placeholder for an undefined debt-to-income ratio (income near zero), far outside the training maximum of 672.5. A logistic model extrapolates in a straight line, so such inputs push the PD towards 100%. With the caps, the live-book maximum is 0.3681 and the out-of-time test metrics barely move (AUC 0.6862 to 0.6863). The caps are learned from training data only and saved inside the pipeline (`ClipToTrainingRange` in `python/ecl/features.py`).
- **The level of the PDs is not recalibrated.** On the 2015 test vintage the model ranks well: the observed default rate rises in every decile, from 3.45% to 30.54%. But it under-predicts the level: 12.64% mean predicted against 14.82% observed. The spec asks for this model and no recalibration, so it is kept and the gap is stated in `docs/model_report.md`. A production model would be recalibrated to recent vintages or carry a margin of conservatism.
- The model files have fixed names, `models/pd_model.joblib` (git-ignored) and `models/pd_model.json` (committed), with the version recorded inside the JSON and in `MODEL_REGISTRY`. Older versions stay in the registry with `active_flag = 'N'`.
- `train_pd_model.py` also scores the live book (`pd_12m_orig`) in the same run, as Phase 5 asks. Both steps log to `BATCH_RUN` through `PKG_BATCH_LOG`, using `python/ecl/batchlog.py`.

## D-018 · Phase 8 · Data quality design

- **Rules are written against a view, `V_DQ_INPUT`.** The view is one staged row plus the facts rules need beyond the row: the loan id as a number, its copy number within the file (one window function), and its `LOAN_MASTER` data (one outer join). Every rule stays a short predicate and runs as a single set-based pass. A first sketch with a correlated `EXISTS` per row for duplicates would have been 100,000 x 100,000 comparisons a month.
- **Two rules beyond the spec's ten:** DQ011 (remaining term not a whole number of at least 1) and DQ012 (data source not `LC_ACTUAL` or `SIMULATED`). With them, every column `load_clean` converts is guarded by a rule, so a bad value is rejected with a reason instead of failing the whole typed load.
- **Lineage:** `LOAN_SNAPSHOT.source_row_num` records the file line each clean row came from. "No rejected row reaches `LOAN_SNAPSHOT`" can then be proved directly by a join, not inferred from loan ids.
- **WARN fixes follow the column, not a rule id:** a WARN on `CURRENT_FICO` loads the FICO as null (scoring then uses the origination FICO), and a WARN on `FORBEARANCE_FLAG` loads N.
- **`reconcile_control` and `run_checks` are separate steps** in `BATCH_RUN` (`RECONCILE_CONTROL`, `DQ_CHECKS`), so a failure says which check stopped the batch.
- **Each monthly step checks its prerequisite** (`pkg_batch_log.require_step`): reconciliation needs a successful staging load, DQ checks a successful reconciliation since that load, and the clean load successful DQ checks. A restart from the wrong step fails with ORA-20005 instead of producing results from unchecked data.
- `row_num` comes from `ROWNUM` over a serial (`NO_PARALLEL`) scan of the external table, which returns a single file's lines in order.
- The reject-share limit is strict: the batch stops when the rejected share is *above* `DQ_MAX_REJECT_SHARE` (1%), not when it equals it.
- `purge_date` deletes everything derived from a date. It never deletes from the audit tables (`STAGE_CHANGE_AUDIT`, `PARAM_AUDIT`, `BATCH_RUN`), which are append-only.
- `tests/test_dq.py` builds its own file for an out-of-range date (2000-01-31) that breaks each rule exactly once, runs the real PL/SQL steps on it, and removes it again. The `BATCH_RUN` rows of those test runs stay, like every other log row.

## D-019 · Phase 9 · Monthly scoring details

- `PD_SCORE` also stores the FICO value fed to the model (`fico_used`) and where it came from (`fico_source` = CURRENT or ORIGINATION). That makes the DQ008 fallback visible per loan. In every month the ORIGINATION count equals that month's DQ008 warnings (137 in March 2019).
- `score_pd.py` refuses to run if `models/pd_model.json` is not the version `MODEL_REGISTRY` marks active, or if the date's clean load has not succeeded since it was last staged. A month is never scored with a model the registry doesn't know, or on half-loaded data.
- The FICO-band check compares current FICO with the midpoint of the origination FICO range. "Unchanged" means exactly equal.

## D-020 · Phase 10 · FICO is exempt from the feature caps (revises D-017)

- **Found in Phase 10:** with every numeric feature capped (D-017), no loan in any month met the PD-deterioration test. The largest `pd_12m_current / pd_12m_orig` across 642,335 loan-months was 1.76, below the 2x threshold. Lending Club only lent at FICO 660 and above, so the cap set FICO's floor near the training minimum, and a current FICO of 362 was scored as if it were about 660. One loan whose FICO fell from 722 to 362 had its PD rise only 26%.
- **Change:** FICO gets its own pipeline branch (impute and scale, no cap); every other numeric feature keeps the caps, which still handle `dti = 999`. The methodology deliberately feeds today's FICO into a model trained on origination FICO, so FICO is the one input meant to go beyond its training range.
- **Result:** the out-of-time metrics barely move (test AUC 0.6863 to 0.6861). The largest PD ratio is now 4.49, PD_DETERIORATION stages 127 to 176 loans per month, and the highest `pd_12m_current` is 0.3813.
- After the change the database was rebuilt from scratch. `STAGE_CHANGE_AUDIT` is append-only, so changing the model and re-staging old months in place would mix audit rows from two models.

## D-021 · Phase 10 · Staging implementation details

- `fn_assign_stage` returns an object type, `stage_decision_t` (stage, reason code, updated cure counter). One pure function can then return all three, and SQL can still read each part. It is `DETERMINISTIC` and has `PRAGMA UDF`, because `assign_stages` calls it once per loan from SQL. A seven-argument overload reads the thresholds from the parameters, for tests and ad-hoc use.
- `assign_stages` is two set-based statements plus the exit update, not literally "one MERGE". The decisions go into `LOAN_STAGE_HISTORY`, starting from each loan's latest previous assessment (D-012). Then one MERGE copies them into `LOAN_STAGE_CURRENT`, which fires the audit trigger. Re-running a month gives an identical history (checked with an `ORA_HASH` over the month) and writes no new audit rows.
- A loan missing from a month's clean snapshot is marked `exited_flag = 'Y'`, not deleted. If it returns the next month (its row was rejected by data quality, for example), its stage continues from its last assessment. That is why, in a few cases a month, the audit compares against an assessment two months back. The Phase 10 check counts changes against the previous assessment and matched every month.
- `stage3_since` is backdated by the DPD beyond 90 the first time a loan is seen in Stage 3: a loan at 125 DPD crossed 90 days 34 days earlier. The time-in-Stage-3 floor then counts from the real crossing day, not from the first reporting date the engine saw.
- Re-running an older month while later months exist rebuilds that month's history only and leaves `LOAN_STAGE_CURRENT` alone. The later months must then be re-run too (runbook).

## D-022 · Phase 11 · ECL engine: arithmetic, benchmark and inputs

- **`run_v2` does its per-month maths in `BINARY_DOUBLE`.** The first `run_v2` used Oracle `NUMBER` throughout and was slower than the row-by-row `run_v1`. The benchmark measured the set-based `NUMBER` version at 32.91 s against `run_v1` at 8.61 s on the base month. Profiling showed the cost was the software arithmetic, not the joins: reading the inputs took 0.25 s and generating the 3.4M loan-month rows 0.58 s. The probability and discount maths now runs in `BINARY_DOUBLE`. Stage 3 losses and floors stay exact `NUMBER`, every stored amount is converted back to `NUMBER` and rounded to cents, and `run_v1` stays exact `NUMBER`. `compare_versions` has shown $0.00 difference on every loan of every month compared.
- **The benchmark covers five variants**, so it can separate the effect of the processing style from that of the arithmetic: the two engines, set-based `NUMBER`, row-by-row `BINARY_DOUBLE`, and a closed-form sum with no month rows. The extra three live in `db/benchmark/` and are re-measured by `python/benchmark_ecl.py`, which writes `docs/performance.md` from the run, including the comparative sentences. Measured result: production `run_v2` beats the spec's naive `run_v1`. With the same arithmetic, though, the row-by-row loop was faster than the month-row statement, because it builds each month from the previous one. The closed form was fastest of all. Production keeps the spec's month-row design so each month's loss stays an auditable term of the formula.
- `V_ECL_INPUT` gathers every ECL input (stage, balance, rate, horizon, LGD, measurement PD, floor) in one row per loan. Both engines read it, so they can only differ in how they calculate. `run_v2` adds `MATERIALIZE` so the view is evaluated once.
- The XSD now requires exactly three scenarios (`minOccurs = maxOccurs = 3`), because `ECL_RESULT` stores one column per scenario code.
- Both engines check that every scored loan got exactly one ECL row. Without the check, a missing LGD or floor for some case would silently drop loans.
- The golden test runs the whole engine on three golden loans under a test date. For the spec's table it temporarily loads base-only weights through `PKG_PARAMS` and sets grade A's LGD to 80%, restoring both in a `finally` block. A second test uses the real parameters against the independent Python implementation (`python/ecl/ecl_math.py`).
- **Environment note:** one monthly ECL step recorded 4,767 s of elapsed time. Windows' power log shows the machine entered Modern Standby during the step and woke 79 minutes later. `V$SQL` showed the statement itself used about 6 s. The runbook covers telling the two apart.

## D-023 · Phase 12 · Batch orchestration details

- **Each step runs in a child bash** (`run_monthly_batch.sh --internal-step NAME DATE RUN_ID`), not as a function call. Bash ignores `set -e` inside a function whose exit status the caller tests (`if step; then ...` or `step || rc=$?`). A failing command in the middle of a step would then let the step carry on and report success. In a child process strict mode works as usual, and the parent only reads the exit code.
- **Lock:** `flock` where it exists (Linux, WSL). Git Bash has no `flock` (D-001), so there the lock is an atomic `mkdir` of `logs/.batch.lock.d` holding the run's PID. A lock whose PID is no longer running is stale and is removed with a warning.
- **Found while writing the kill test:** killing a run doesn't kill the step it started; that child process carries on alone. Under `flock` the child inherits the lock descriptor, so the lock stays held until the child finishes. The `mkdir` lock now behaves the same way. Each step writes its PID to `step_pid` in the lock folder, and a restart refuses to start while that process is alive. In `tests/test_batch_rerun.py` the run is killed during `score_pd`. The first restart was refused ("its step (pid 823) is still running"), and the retry two seconds later finished with results identical to the clean run. One small gap remains: a kill in the fraction of a second between the parent starting a step and the step writing its PID.
- **Exit codes are normalised in the EXIT trap.** Anything other than 0 or 2 becomes 1: a failed step, a held lock, or an unreachable database (`run_sql` exits 3 on an Oracle error). That matches the spec's "1 when a step fails", and 2 stays reserved for bad arguments.
- **Every step appears in `BATCH_RUN`.** PL/SQL and Python steps log themselves. The shell-only steps (export, archive, log cleanup, summary) call `pkg_batch_log.start_step` and `end_step` from bash. Preflight runs before there is a run id, because it is the step that checks the database is reachable. It appears in the log file but not in `BATCH_RUN`.
- **Preflight restores archived inputs.** The archive step gzips a date's files into `data/archive/`, so a date that was already processed has nothing left in `data/incoming/`. When the files are missing, preflight brings them back from the archive with `gzip -dc`. Re-running or restarting a month then needs no manual step. `run_all_months.sh` still only runs the dates waiting in `data/incoming/`, as the spec says. To re-run every month, regenerate the files with `simulate_months.py`, which writes byte-identical files (Phase 7).
- **`reports/` is mounted into the container** (`./reports:/opt/ecl/reports`), so SQL*Plus can `SPOOL` the CSV exports straight into `reports/YYYYMMDD/`. The host creates the folder first, because `SPOOL` can't create folders.
- **Lesson: never edit a script while the batch is running it.** Bash reads a script as it goes, not all at once. Editing `export_reports.sh` during the August run made bash read part of the old file and part of the new one, and the export step died with a syntax error. A restart with `--from-step export_reports` finished the month. The runbook says so.
- `shellcheck` 0.10.0 runs from its Docker image (`koalaman/shellcheck:v0.10.0`), so nothing is installed on the host. `.shellcheckrc` makes it follow `lib/common.sh` from each script's folder.
- `tests/test_batch_rerun.py` runs Git Bash's real shell (`usr/bin/bash.exe`) with Git's tools first on `PATH`. On this machine `bash` on `PATH` can be WSL's launcher, and `bin/bash.exe` is only a launcher that would outlive a killed batch.

## D-024 · Phase 13 · Reports: inline SVG charts, migration and movement conventions

- **Charts are inline SVG, not matplotlib.** The spec lists matplotlib in the stack. `make_report.py` instead draws its two charts as inline SVG (`python/ecl/svgchart.py`), so the report is one self-contained HTML file with no image files beside it. The charts follow the reader's light or dark mode through CSS variables, carry hover and keyboard tooltips, and stay sharp at any zoom. Nothing imports matplotlib, so it is removed from `python/requirements.txt`.
- **Chart rules followed:** one y-axis per chart (ECL amounts and coverage ratios get two charts, never a dual axis), legends plus a few direct labels, and a table view under the charts. The three stage colours passed a palette validator for colour-vision separation in light and dark mode. Stage 3's green is below 3:1 contrast on the light background, which is another reason every series is labelled and every chart has a table.
- **Visual check:** the September report was rendered with headless Chrome in light mode, dark mode and at a 390 px phone width. The phone render ran inside a 390 px iframe, because desktop Chrome won't open a window that narrow. Tiles and charts stack, wide tables scroll inside their own box, and the browser console showed no script errors.
- **Stage migration:** rows are the stage at the previous reporting date, plus NEW for loans that weren't on that book. Columns are the stage now, plus EXITED for loans no longer on the book. "Previous" is the previous date in `ECL_RESULT`. A loan rejected by data quality for one month shows as EXITED that month and NEW when it comes back, because it really is missing from that month's book.
- **ECL movement (IFRS 7 style):** a transfer moves the loan's *opening* ECL from its old stage to its new one. Remeasurement is closing minus opening ECL for loans on both books, booked in the closing stage. New loans come in at closing ECL, and exits go out at opening ECL. The other common convention transfers at closing ECL. Either way, the stage totals don't change. With this layout, `DIFFERENCE` is zero by construction. `tests/test_reports.py` therefore also ties every month's opening ECL to the previous month's `V_ECL_BY_STAGE`, and closing ECL to this month's. That proves the walk covers the whole book.
- **CSV format:** SQL*Plus `SET MARKUP CSV ON QUOTE ON`, dates in ISO form through `NLS_DATE_FORMAT`. Numbers come out without a leading zero (`.0789`), which Power BI and pandas both read.
- **The committed sample report leaves out `ecl_detail.csv`.** It is 13.8 MB of loan-level rows, and the spec keeps generated data out of git. `docs/sample_report/` has the HTML, the eight summary CSVs and a screenshot, because GitHub shows HTML files as source.
- **`docs/powerbi_guide.md` hasn't been tried in Power BI.** Power BI Desktop isn't installed on the build machine, so the guide is written from the CSV layout and says so at the top.
