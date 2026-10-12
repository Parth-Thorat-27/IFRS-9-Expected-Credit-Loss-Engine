CREATE OR REPLACE PACKAGE BODY pkg_batch_log AS

  FUNCTION new_run_id RETURN NUMBER IS
  BEGIN
    RETURN batch_run_id_seq.NEXTVAL;
  END new_run_id;

  FUNCTION start_step(p_run_id         IN NUMBER,
                      p_reporting_date IN DATE,
                      p_step_name      IN VARCHAR2) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_id batch_run.batch_run_id%TYPE;
  BEGIN
    INSERT INTO batch_run (run_id, reporting_date, step_name, status, started_ts, db_user)
    VALUES (p_run_id, p_reporting_date, UPPER(p_step_name), 'RUNNING', SYSTIMESTAMP,
            SYS_CONTEXT('USERENV', 'SESSION_USER'))
    RETURNING batch_run_id INTO l_id;
    COMMIT;
    RETURN l_id;
  END start_step;

  PROCEDURE end_step(p_batch_run_id IN NUMBER,
                     p_status       IN VARCHAR2 DEFAULT 'SUCCESS',
                     p_rows         IN NUMBER   DEFAULT NULL,
                     p_message      IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_now TIMESTAMP := SYSTIMESTAMP;
  BEGIN
    UPDATE batch_run
       SET status          = p_status,
           ended_ts        = l_now,
           -- A TIMESTAMP difference is an INTERVAL; turn it into plain seconds.
           elapsed_seconds = ROUND(  EXTRACT(DAY    FROM (l_now - started_ts)) * 86400
                                   + EXTRACT(HOUR   FROM (l_now - started_ts)) * 3600
                                   + EXTRACT(MINUTE FROM (l_now - started_ts)) * 60
                                   + EXTRACT(SECOND FROM (l_now - started_ts)), 3),
           rows_processed  = p_rows,
           message         = SUBSTR(p_message, 1, 4000)
     WHERE batch_run_id = p_batch_run_id;
    COMMIT;
  END end_step;

  FUNCTION error_text RETURN VARCHAR2 IS
  BEGIN
    -- FORMAT_ERROR_STACK has the ORA- messages; FORMAT_ERROR_BACKTRACE adds the
    -- package line numbers, which SQLERRM alone loses.
    RETURN SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
  END error_text;

  PROCEDURE require_step(p_reporting_date IN DATE, p_step_name IN VARCHAR2) IS
    l_loaded  batch_run.started_ts%TYPE;
    l_done    PLS_INTEGER;
  BEGIN
    SELECT MAX(started_ts) INTO l_loaded
      FROM batch_run
     WHERE reporting_date = p_reporting_date AND step_name = 'LOAD_SNAPSHOT' AND status = 'SUCCESS';

    SELECT COUNT(*) INTO l_done
      FROM batch_run
     WHERE reporting_date = p_reporting_date AND step_name = UPPER(p_step_name)
       AND status = 'SUCCESS' AND started_ts >= l_loaded;

    IF l_loaded IS NULL OR l_done = 0 THEN
      RAISE_APPLICATION_ERROR(-20005, 'step ' || UPPER(p_step_name) || ' has not succeeded for '
        || TO_CHAR(p_reporting_date, 'YYYY-MM-DD') || ' since its snapshot was last loaded; '
        || 'run the batch from that step');
    END IF;
  END require_step;

END pkg_batch_log;
/
