CREATE OR REPLACE PACKAGE pkg_batch_log AS
  -- Step logging for the batch: one BATCH_RUN row per step.
  --
  -- Every write here is an autonomous transaction: it commits on its own,
  -- independent of the caller's transaction. A step that fails and rolls back
  -- its work therefore still leaves its FAILED row (with the error) behind,
  -- which is exactly the row you need when troubleshooting.
  --
  -- Usage inside a step:
  --   l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'LOAD_SNAPSHOT');
  --   ... work ...; COMMIT;
  --   pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows, 'loaded 100,000 rows');
  -- and in the exception handler:
  --   pkg_batch_log.end_step(l_step, 'FAILED', NULL, <error stack>); RAISE;

  -- A new id that groups all the steps of one batch run.
  FUNCTION new_run_id RETURN NUMBER;

  -- Insert a RUNNING row and return its BATCH_RUN_ID.
  FUNCTION start_step(p_run_id         IN NUMBER,
                      p_reporting_date IN DATE,
                      p_step_name      IN VARCHAR2) RETURN NUMBER;

  -- Close the row: status SUCCESS or FAILED, timings, rows and message.
  PROCEDURE end_step(p_batch_run_id IN NUMBER,
                     p_status       IN VARCHAR2 DEFAULT 'SUCCESS',
                     p_rows         IN NUMBER   DEFAULT NULL,
                     p_message      IN VARCHAR2 DEFAULT NULL);

  -- The current error stack plus where it was raised, sized for BATCH_RUN.message.
  -- Call it inside an exception handler.
  FUNCTION error_text RETURN VARCHAR2;

  -- Raise unless p_step_name has succeeded for the date since the latest
  -- successful LOAD_SNAPSHOT of that date. Each monthly step calls this for
  -- its predecessor, so a step can't run on data the previous step hasn't
  -- processed (for example after a restart from the wrong step).
  PROCEDURE require_step(p_reporting_date IN DATE, p_step_name IN VARCHAR2);
END pkg_batch_log;
/
