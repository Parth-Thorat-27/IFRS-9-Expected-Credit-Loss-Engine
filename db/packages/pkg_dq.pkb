CREATE OR REPLACE PACKAGE BODY pkg_dq AS

  FUNCTION fmt_int(p_value IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_value, 'FM999,999,999,990');
  END fmt_int;

  FUNCTION fmt_money(p_value IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_value, 'FM999,999,999,990.00');
  END fmt_money;

  ----------------------------------------------------------------------------
  PROCEDURE reconcile_control(p_reporting_date IN DATE, p_run_id IN NUMBER) IS
    l_step         NUMBER;
    l_rows         NUMBER;
    l_balance      NUMBER;
    l_exp_rows     stg_control.expected_rows%TYPE;
    l_exp_balance  stg_control.expected_balance%TYPE;
    l_control      stg_control.control_file%TYPE;
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'RECONCILE_CONTROL');
    pkg_batch_log.require_step(p_reporting_date, 'LOAD_SNAPSHOT');
    EXECUTE IMMEDIATE q'[ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,']';

    SELECT expected_rows, expected_balance, control_file
      INTO l_exp_rows, l_exp_balance, l_control
      FROM stg_control
     WHERE reporting_date = p_reporting_date;

    -- Balances are summed as numbers where they are numbers; a non-numeric
    -- balance then can't match the sender's total, which is the point.
    SELECT COUNT(*), NVL(SUM(TO_NUMBER(balance DEFAULT NULL ON CONVERSION ERROR)), 0)
      INTO l_rows, l_balance
      FROM stg_loan_snapshot
     WHERE reporting_date = p_reporting_date;

    IF l_rows <> l_exp_rows OR ABS(l_balance - l_exp_balance) >= 0.005 THEN
      RAISE_APPLICATION_ERROR(-20030,
        'control totals do not match: staged ' || fmt_int(l_rows) || ' rows and balance '
        || fmt_money(l_balance) || ', but ' || l_control || ' expects ' || fmt_int(l_exp_rows)
        || ' rows and ' || fmt_money(l_exp_balance) || ' (' || fmt_int(l_exp_rows - l_rows)
        || ' rows missing). The file is truncated or is not the file the control describes: '
        || 'get a fresh copy; never force the load.');
    END IF;

    pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows,
      'rows ' || fmt_int(l_rows) || ' and balance ' || fmt_money(l_balance) || ' match ' || l_control);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, 'no control totals staged for '
                             || TO_CHAR(p_reporting_date, 'YYYY-MM-DD'));
      RAISE;
    WHEN OTHERS THEN
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END reconcile_control;

  ----------------------------------------------------------------------------
  PROCEDURE run_checks(p_reporting_date IN DATE, p_run_id IN NUMBER) IS
    l_step      NUMBER;
    l_sql       VARCHAR2(32767);
    l_errors    PLS_INTEGER := 0;
    l_rules     PLS_INTEGER := 0;
    l_received  NUMBER;
    l_rejected  NUMBER;
    l_warned    NUMBER;
    l_max_share NUMBER;
    l_share     NUMBER;
    l_by_rule   VARCHAR2(4000);
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'DQ_CHECKS');
    pkg_batch_log.require_step(p_reporting_date, 'RECONCILE_CONTROL');
    EXECUTE IMMEDIATE q'[ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,']';
    l_max_share := pkg_params.get_number('DQ_MAX_REJECT_SHARE');

    -- Re-runnable: this date's errors are rebuilt from scratch.
    DELETE FROM dq_error WHERE reporting_date = p_reporting_date;

    FOR r IN (SELECT rule_id, severity, column_name, predicate, message
                FROM dq_rule
               WHERE active_flag = 'Y'
               ORDER BY rule_id) LOOP
      -- The predicate is concatenated in: it is rule metadata maintained like
      -- code, not user input. Every value (run, rule, message, date) goes in
      -- as a bind variable, and the column name must pass DBMS_ASSERT as a
      -- plain identifier before it is used as one.
      l_sql := 'INSERT INTO dq_error (reporting_date, run_id, rule_id, severity, row_num, loan_id,'
            || ' column_name, bad_value, message)'
            || ' SELECT s.reporting_date, :run_id, :rule_id, :severity, s.row_num, SUBSTR(s.loan_id, 1, 200),'
            || ' :column_name, '
            || CASE WHEN r.column_name IS NULL THEN 'NULL'
                    ELSE 'SUBSTR(s.' || DBMS_ASSERT.SIMPLE_SQL_NAME(r.column_name) || ', 1, 200)' END
            || ', :message FROM v_dq_input s WHERE s.reporting_date = :reporting_date AND ('
            || r.predicate || ')';
      EXECUTE IMMEDIATE l_sql
        USING p_run_id, r.rule_id, r.severity, r.column_name, r.message, p_reporting_date;
      l_errors := l_errors + SQL%ROWCOUNT;
      l_rules := l_rules + 1;
    END LOOP;

    SELECT COUNT(*) INTO l_received FROM stg_loan_snapshot WHERE reporting_date = p_reporting_date;
    SELECT COUNT(DISTINCT CASE WHEN severity = 'REJECT' THEN row_num END),
           COUNT(DISTINCT CASE WHEN severity = 'WARN' THEN row_num END)
      INTO l_rejected, l_warned
      FROM dq_error
     WHERE reporting_date = p_reporting_date;
    SELECT LISTAGG(rule_id || '=' || n, ' ') WITHIN GROUP (ORDER BY rule_id) INTO l_by_rule
      FROM (SELECT rule_id, COUNT(*) n FROM dq_error WHERE reporting_date = p_reporting_date GROUP BY rule_id);

    -- Keep the errors even if the share check below fails: they explain why.
    COMMIT;

    l_share := CASE WHEN l_received > 0 THEN l_rejected / l_received ELSE 1 END;
    IF l_share > l_max_share THEN
      RAISE_APPLICATION_ERROR(-20031,
        'rejected ' || fmt_int(l_rejected) || ' of ' || fmt_int(l_received) || ' rows ('
        || TO_CHAR(l_share * 100, 'FM990.000') || '%), above DQ_MAX_REJECT_SHARE '
        || TO_CHAR(l_max_share * 100, 'FM990.000') || '%: check V_DQ_SUMMARY, fix the source, rerun the date');
    END IF;

    pkg_batch_log.end_step(l_step, 'SUCCESS', l_received,
      l_rules || ' rules on ' || fmt_int(l_received) || ' rows: rejected ' || fmt_int(l_rejected)
      || ' (' || TO_CHAR(l_share * 100, 'FM990.000') || '%), warned ' || fmt_int(l_warned)
      || '; errors by rule ' || NVL(l_by_rule, 'none'));
  EXCEPTION
    WHEN OTHERS THEN
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END run_checks;

END pkg_dq;
/
