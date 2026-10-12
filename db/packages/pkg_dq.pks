CREATE OR REPLACE PACKAGE pkg_dq AS
  -- Data quality for the monthly snapshot, in the order the batch runs them:
  --
  --   reconcile_control  the staged file matches its control file: same row
  --                      count and same total balance, to the cent. A
  --                      truncated or wrong file stops the batch here.
  --   run_checks         every active DQ_RULE against the staged rows; each
  --                      failure becomes a DQ_ERROR row with the bad value
  --                      and the reason. Stops the batch if the share of
  --                      rejected rows passes DQ_MAX_REJECT_SHARE.
  --
  -- Both log to BATCH_RUN; a failure is logged as FAILED with the reason and
  -- re-raised so the batch exits non-zero.
  PROCEDURE reconcile_control(p_reporting_date IN DATE, p_run_id IN NUMBER);
  PROCEDURE run_checks(p_reporting_date IN DATE, p_run_id IN NUMBER);
END pkg_dq;
/
