CREATE OR REPLACE PACKAGE pkg_load AS
  -- Moves file data into typed tables.
  --   load_history   one-off: processed CSVs -> LOAN_DEV and LOAN_MASTER
  --   load_snapshot  monthly: incoming CSVs -> STG_LOAN_SNAPSHOT and STG_CONTROL (raw text)
  --   load_clean     monthly: staged rows with no REJECT error -> LOAN_SNAPSHOT (typed)
  --   purge_date     clears one reporting date so a re-run starts clean
  -- Each logs itself to BATCH_RUN through PKG_BATCH_LOG.

  -- Reload LOAN_DEV and LOAN_MASTER from the processed CSVs (re-runnable).
  -- Refuses once monthly data exists, because LOAN_SNAPSHOT refers to LOAN_MASTER.
  PROCEDURE load_history(p_run_id IN NUMBER);
END pkg_load;
/
