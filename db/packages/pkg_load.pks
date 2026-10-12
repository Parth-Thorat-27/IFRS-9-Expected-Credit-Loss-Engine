CREATE OR REPLACE PACKAGE pkg_load AS
  -- Moves file data into typed tables.
  --   load_history   one-off: processed CSVs -> LOAN_DEV and LOAN_MASTER
  --   load_snapshot  monthly: incoming CSVs -> STG_LOAN_SNAPSHOT and STG_CONTROL (raw text)
  --   load_clean     monthly: staged rows with no REJECT error -> LOAN_SNAPSHOT (typed)
  --   purge_date     clears one reporting date so a re-run starts clean
  -- The monthly routines log themselves to BATCH_RUN through PKG_BATCH_LOG.

  -- Reload LOAN_DEV and LOAN_MASTER from the processed CSVs (re-runnable).
  -- Refuses once monthly data exists, because LOAN_SNAPSHOT refers to LOAN_MASTER.
  PROCEDURE load_history(p_run_id IN NUMBER);

  -- Purge the date, point the external tables at its files
  -- (loan_snapshot_YYYYMMDD.csv, control_YYYYMMDD.csv) and stage every row
  -- exactly as received, numbered in file order.
  PROCEDURE load_snapshot(p_reporting_date IN DATE, p_run_id IN NUMBER);

  -- Typed copy of the staged rows that have no REJECT error. Rows with a WARN
  -- get the documented fix: invalid current FICO -> null (scoring then uses
  -- the origination FICO), invalid forbearance flag -> N.
  PROCEDURE load_clean(p_reporting_date IN DATE, p_run_id IN NUMBER);

  -- Delete everything derived from one reporting date: ECL results, stage
  -- history, PD scores, the clean snapshot, DQ errors and staging. Audit
  -- tables (STAGE_CHANGE_AUDIT, PARAM_AUDIT, BATCH_RUN) are append-only and
  -- are never purged. Returns the number of rows deleted.
  FUNCTION purge_date(p_reporting_date IN DATE) RETURN NUMBER;
END pkg_load;
/
