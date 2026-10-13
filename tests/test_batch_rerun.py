"""The monthly batch is re-runnable: a month run twice gives identical results,
and a run killed part-way, then restarted with --from-step, ends with the same
results as a clean run.

These run the real batch on the latest processed month (preflight brings its
input files back from data/archive), so they take a few minutes. Skip them with
    python -m pytest -m "not slow"
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from conftest import ROOT, scalar

pytestmark = pytest.mark.slow

# Every table the batch writes for a reporting date.
TABLES_BY_DATE = ["STG_LOAN_SNAPSHOT", "STG_CONTROL", "DQ_ERROR", "LOAN_SNAPSHOT", "PD_SCORE",
                  "LOAN_STAGE_HISTORY", "STAGE_CHANGE_AUDIT", "ECL_RESULT"]


def git_bash() -> tuple[str, dict]:
    """The bash that runs the scripts, and the environment to run it in.

    On Windows, `bash` on PATH can be WSL's launcher in System32, which would
    run the batch inside Linux, away from docker.exe and the venv. Git Bash's
    real shell is usr/bin/bash.exe: bin/bash.exe is only a launcher, and
    killing the launcher would leave the batch running.
    """
    env = os.environ.copy()
    if os.name != "nt":
        return shutil.which("bash") or "/bin/bash", env
    exec_path = subprocess.run(["git", "--exec-path"], capture_output=True, text=True,
                               check=True).stdout.strip()
    git_root = Path(exec_path).parents[2]          # <Git>/mingw64/libexec/git-core
    # The launcher would also put Git's tools first on PATH. Without them,
    # `find` in the scripts would be Windows' find.exe.
    env["PATH"] = os.pathsep.join([str(git_root / "usr" / "bin"), str(git_root / "mingw64" / "bin"),
                                   env["PATH"]])
    return str(git_root / "usr" / "bin" / "bash.exe"), env


def run_batch(*args: str) -> subprocess.CompletedProcess:
    bash, env = git_bash()
    return subprocess.run([bash, "scripts/run_monthly_batch.sh", *args], cwd=ROOT, env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          encoding="utf-8", errors="replace", timeout=900)


def table_fingerprint(cur, table: str, where: str = "", **binds) -> tuple:
    """Row count and an order-free hash of every column, except those that
    differ between runs by design: RUN_ID, identity keys and timestamps."""
    cur.execute("""SELECT column_name FROM user_tab_columns c
                    WHERE table_name = :t AND column_name <> 'RUN_ID'
                      AND data_type NOT LIKE 'TIMESTAMP%'
                      AND NOT EXISTS (SELECT 1 FROM user_tab_identity_cols i
                                       WHERE i.table_name = c.table_name
                                         AND i.column_name = c.column_name)
                    ORDER BY column_id""", t=table)
    row_text = " || '|' || ".join(name for (name,) in cur)
    cur.execute(f"SELECT COUNT(*), SUM(ORA_HASH({row_text})) FROM {table} {where}", binds)
    return cur.fetchone()


def fingerprint(cur, month) -> dict[str, tuple]:
    prints = {t: table_fingerprint(cur, t, "WHERE reporting_date = :d", d=month) for t in TABLES_BY_DATE}
    # One row per loan, not per date: the state the next month starts from.
    prints["LOAN_STAGE_CURRENT"] = table_fingerprint(cur, "LOAN_STAGE_CURRENT")
    return prints


def run_id_of(result: subprocess.CompletedProcess) -> int:
    return int(re.search(r"\brun id (\d+)", result.stdout).group(1))


@pytest.fixture(scope="module")
def month(conn):
    """The latest processed month: re-running it leaves LOAN_STAGE_CURRENT
    where it was. (The tests' own made-up dates are in 2000.)"""
    with conn.cursor() as cur:
        month = scalar(cur, "SELECT MAX(reporting_date) FROM ecl_result WHERE reporting_date > DATE '2010-01-01'")
    if month is None:
        pytest.skip("no month has been processed yet (run scripts/run_all_months.sh)")
    stamp = f"{month:%Y%m%d}"
    if not any((ROOT / "data" / folder / f"loan_snapshot_{stamp}.csv{ext}").exists()
               for folder, ext in (("incoming", ""), ("archive", ".gz"))):
        pytest.skip(f"the input files for {month:%Y-%m-%d} are in neither data/incoming nor data/archive")
    return month


@pytest.fixture(scope="module")
def clean_run(conn, month):
    """Run the month once from the top; the other runs must reproduce it."""
    result = run_batch(f"{month:%Y-%m-%d}")
    assert result.returncode == 0, result.stdout[-3000:]
    with conn.cursor() as cur:
        return fingerprint(cur, month)


def test_a_month_run_twice_gives_identical_results(cur, month, clean_run):
    again = run_batch(f"{month:%Y-%m-%d}")
    assert again.returncode == 0, again.stdout[-3000:]

    steps = scalar(cur, "SELECT COUNT(*) FROM batch_run WHERE run_id = :r", r=run_id_of(again))
    failed = scalar(cur, "SELECT COUNT(*) FROM batch_run WHERE run_id = :r AND status <> 'SUCCESS'",
                    r=run_id_of(again))
    assert steps > 0 and failed == 0
    assert fingerprint(cur, month) == clean_run


def test_a_killed_run_restarted_from_score_pd_matches_a_clean_run(cur, month, clean_run):
    day = f"{month:%Y-%m-%d}"
    last_run = scalar(cur, "SELECT NVL(MAX(run_id), 0) FROM batch_run")
    bash, env = git_bash()
    # Its output goes nowhere: a pipe would stay open in the orphaned step.
    victim = subprocess.Popen([bash, "scripts/run_monthly_batch.sh", day], cwd=ROOT, env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        # Kill it once scoring has started: data quality and the clean load
        # are done, and the scoring step is in flight.
        deadline = time.monotonic() + 300
        while scalar(cur, "SELECT COUNT(*) FROM batch_run WHERE run_id > :r AND step_name = 'SCORE_PD'",
                     r=last_run) == 0:
            assert victim.poll() is None, "the batch ended before scoring started"
            assert time.monotonic() < deadline, "scoring never started"
            time.sleep(0.2)
    finally:
        # SIGKILL on Linux, TerminateProcess on Windows: no traps, no cleanup.
        victim.kill()
        victim.wait()
    victim_run = scalar(cur, "SELECT MIN(run_id) FROM batch_run WHERE run_id > :r", r=last_run)
    assert scalar(cur, "SELECT COUNT(*) FROM batch_run WHERE run_id = :r AND step_name = 'RUN_ECL'",
                  r=victim_run) == 0, "the kill came too late to interrupt the run"

    # The scoring step carries on alone after the kill. The restart must
    # refuse to overlap it ("still running" with the mkdir lock, "holds the
    # lock" with flock, whose descriptor the step inherited), then go ahead
    # once it has finished.
    deadline = time.monotonic() + 300
    while True:
        restart = run_batch(day, "--from-step", "score_pd")
        refused = "still running" in restart.stdout or "holds the lock" in restart.stdout
        if restart.returncode == 0 or not refused or time.monotonic() > deadline:
            break
        time.sleep(2)
    assert restart.returncode == 0, restart.stdout[-3000:]
    assert fingerprint(cur, month) == clean_run
