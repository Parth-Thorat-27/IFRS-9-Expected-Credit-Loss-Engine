# IFRS 9 Expected Credit Loss Engine

> **Work in progress.** Built phase by phase from the specification in
> [docs/SPEC.md](docs/SPEC.md). This is a learning and portfolio project, not
> production software.

A small version of what a bank's IFRS 9 system does every month: take the loan
book, decide each loan's stage, and calculate how much to set aside for
expected credit losses. It runs on Oracle Database Free (PL/SQL), Python and
bash, using Lending Club's public loan data.

## Build status

| Phase | Scope | Status |
|---|---|---|
| 1 | Repo and environment | Done |
| 2 | Data preparation | To do |
| 3 | Oracle schema | To do |
| 4 | Historical load and LGD calibration | To do |
| 5 | PD model | To do |
| 6 | XML parameters | To do |
| 7 | Monthly snapshot simulator | To do |
| 8 | Staging load and data quality | To do |
| 9 | Monthly PD scoring | To do |
| 10 | Stage assignment and audit trigger | To do |
| 11 | ECL engine | To do |
| 12 | Batch orchestration and cron | To do |
| 13 | Reports | To do |
| 14 | Tests, docs and README | To do |

## Running what exists so far

Prerequisites: Docker Desktop, Python 3.11+, and a bash shell (Linux, WSL or
Git Bash on Windows).

```bash
cp .env.example .env                 # then set the two passwords
docker compose up -d                 # first start unpacks the database (~2-3 min)
python -m venv .venv                 # Windows: py -3.11 -m venv .venv
.venv/bin/python -m pip install -r python/requirements.txt   # Windows: .venv/Scripts/python.exe
scripts/smoke_test.sh                # SQL*Plus and python-oracledb both reach FREEPDB1
```

Changes from the spec, and why, are logged in [docs/decisions.md](docs/decisions.md).
