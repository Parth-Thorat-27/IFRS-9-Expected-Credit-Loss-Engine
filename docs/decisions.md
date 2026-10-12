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
