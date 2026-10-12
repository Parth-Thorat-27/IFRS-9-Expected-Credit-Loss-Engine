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
