CREATE OR REPLACE PACKAGE BODY pkg_load AS

  -- The CSVs write numbers with a "." decimal point. Pin the session to
  -- that, so TO_NUMBER can't misread them under a client with other settings.
  PROCEDURE set_number_format IS
  BEGIN
    EXECUTE IMMEDIATE q'[ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,']';
  END set_number_format;

  ----------------------------------------------------------------------------
  PROCEDURE load_history(p_run_id IN NUMBER) IS
    l_step     NUMBER;
    l_monthly  PLS_INTEGER;
    l_dev      PLS_INTEGER;
    l_master   PLS_INTEGER;
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, NULL, 'LOAD_HISTORY');
    set_number_format;

    SELECT COUNT(*) INTO l_monthly FROM loan_snapshot WHERE ROWNUM = 1;
    IF l_monthly > 0 THEN
      RAISE_APPLICATION_ERROR(-20020, 'monthly data already refers to LOAN_MASTER; '
                              || 'run setup_db.sh --reset before reloading the history');
    END IF;

    -- Re-runnable: clear, then reload. LOAN_DEV has no dependants, so TRUNCATE
    -- (instant, resets the space). LOAN_MASTER is the parent of foreign keys,
    -- which TRUNCATE refuses even when the child tables are empty, so DELETE.
    EXECUTE IMMEDIATE 'TRUNCATE TABLE loan_dev';
    DELETE FROM loan_stage_current;
    DELETE FROM loan_master;
    COMMIT;

    -- APPEND = direct-path insert: rows are written straight into new blocks
    -- above the table's high-water mark, skipping the buffer cache. Much faster
    -- for bulk loads; the price is that the table can't be read in this
    -- transaction until COMMIT.
    INSERT /*+ APPEND */ INTO loan_dev (
      loan_id, loan_status, default_flag, issue_d, term_months, loan_amnt, funded_amnt,
      int_rate, installment, grade, sub_grade, emp_length, home_ownership, annual_inc,
      verification_status, purpose, addr_state, dti, delinq_2yrs, earliest_cr_line,
      fico_range_low, fico_range_high, inq_last_6mths, open_acc, pub_rec, revol_bal,
      revol_util, total_acc, mort_acc, pub_rec_bankruptcies, application_type,
      total_rec_prncp, recoveries, collection_recovery_fee)
    SELECT TO_NUMBER(loan_id), loan_status, TO_NUMBER(default_flag),
           TO_DATE(issue_d, 'YYYY-MM-DD'), TO_NUMBER(term_months), TO_NUMBER(loan_amnt),
           TO_NUMBER(funded_amnt), TO_NUMBER(int_rate), TO_NUMBER(installment), grade, sub_grade,
           TO_NUMBER(emp_length), home_ownership, TO_NUMBER(annual_inc), verification_status,
           purpose, addr_state, TO_NUMBER(dti), TO_NUMBER(delinq_2yrs),
           TO_DATE(earliest_cr_line, 'YYYY-MM-DD'), TO_NUMBER(fico_range_low),
           TO_NUMBER(fico_range_high), TO_NUMBER(inq_last_6mths), TO_NUMBER(open_acc),
           TO_NUMBER(pub_rec), TO_NUMBER(revol_bal), TO_NUMBER(revol_util), TO_NUMBER(total_acc),
           TO_NUMBER(mort_acc), TO_NUMBER(pub_rec_bankruptcies), application_type,
           TO_NUMBER(total_rec_prncp), TO_NUMBER(recoveries), TO_NUMBER(collection_recovery_fee)
      FROM ext_loan_dev;
    l_dev := SQL%ROWCOUNT;
    COMMIT;

    -- Only the application columns go into LOAN_MASTER. The base-month state
    -- (balance, DPD, current FICO, ...) reaches the database through the
    -- monthly snapshot file, like every other month.
    INSERT /*+ APPEND */ INTO loan_master (
      loan_id, issue_d, term_months, loan_amnt, funded_amnt, int_rate, installment, grade,
      sub_grade, emp_length, home_ownership, annual_inc, verification_status, purpose,
      addr_state, dti, delinq_2yrs, earliest_cr_line, fico_range_low, fico_range_high,
      inq_last_6mths, open_acc, pub_rec, revol_bal, revol_util, total_acc, mort_acc,
      pub_rec_bankruptcies, application_type)
    SELECT TO_NUMBER(loan_id), TO_DATE(issue_d, 'YYYY-MM-DD'), TO_NUMBER(term_months),
           TO_NUMBER(loan_amnt), TO_NUMBER(funded_amnt), TO_NUMBER(int_rate),
           TO_NUMBER(installment), grade, sub_grade, TO_NUMBER(emp_length), home_ownership,
           TO_NUMBER(annual_inc), verification_status, purpose, addr_state, TO_NUMBER(dti),
           TO_NUMBER(delinq_2yrs), TO_DATE(earliest_cr_line, 'YYYY-MM-DD'),
           TO_NUMBER(fico_range_low), TO_NUMBER(fico_range_high), TO_NUMBER(inq_last_6mths),
           TO_NUMBER(open_acc), TO_NUMBER(pub_rec), TO_NUMBER(revol_bal), TO_NUMBER(revol_util),
           TO_NUMBER(total_acc), TO_NUMBER(mort_acc), TO_NUMBER(pub_rec_bankruptcies),
           application_type
      FROM ext_portfolio_base;
    l_master := SQL%ROWCOUNT;
    COMMIT;

    pkg_batch_log.end_step(l_step, 'SUCCESS', l_dev + l_master,
                           'LOAN_DEV ' || l_dev || ' rows, LOAN_MASTER ' || l_master || ' rows');
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END load_history;

  ----------------------------------------------------------------------------
  FUNCTION purge_date(p_reporting_date IN DATE) RETURN NUMBER IS
    l_deleted NUMBER := 0;
  BEGIN
    -- Children before parents, following the foreign keys back to LOAN_SNAPSHOT.
    DELETE FROM ecl_result         WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    DELETE FROM ecl_result_v1      WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    DELETE FROM loan_stage_history WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    DELETE FROM pd_score           WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    DELETE FROM loan_snapshot      WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    DELETE FROM dq_error           WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    DELETE FROM stg_control        WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    DELETE FROM stg_loan_snapshot  WHERE reporting_date = p_reporting_date; l_deleted := l_deleted + SQL%ROWCOUNT;
    -- LOAN_STAGE_CURRENT is not touched: the next assessment of the date
    -- starts from LOAN_STAGE_HISTORY and overwrites it. The caller commits.
    RETURN l_deleted;
  END purge_date;

  ----------------------------------------------------------------------------
  PROCEDURE load_snapshot(p_reporting_date IN DATE, p_run_id IN NUMBER) IS
    l_step     NUMBER;
    l_stamp    VARCHAR2(8) := TO_CHAR(p_reporting_date, 'YYYYMMDD');
    l_snapshot VARCHAR2(100) := 'loan_snapshot_' || l_stamp || '.csv';
    l_control  VARCHAR2(100) := 'control_' || l_stamp || '.csv';
    l_purged   NUMBER;
    l_rows     PLS_INTEGER;
    l_controls PLS_INTEGER;
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'LOAD_SNAPSHOT');
    set_number_format;

    -- A re-run of the date starts from nothing, so it can't create duplicates.
    l_purged := purge_date(p_reporting_date);
    COMMIT;

    -- Point the external tables at this date's files. ALTER TABLE is DDL (it
    -- commits), which is why the purge above was committed first. Only one
    -- batch runs at a time (the batch takes a lock), so nobody else can be
    -- reading the tables while they are repointed.
    EXECUTE IMMEDIATE 'ALTER TABLE ext_loan_snapshot LOCATION (' || DBMS_ASSERT.ENQUOTE_LITERAL(l_snapshot) || ')';
    EXECUTE IMMEDIATE 'ALTER TABLE ext_control LOCATION (' || DBMS_ASSERT.ENQUOTE_LITERAL(l_control) || ')';

    -- ROWNUM numbers the rows in the order the file is read: a serial scan of
    -- one file returns the lines in file order, so row_num is the line number
    -- (NO_PARALLEL makes sure the scan is serial).
    INSERT /*+ APPEND */ INTO stg_loan_snapshot (
      reporting_date, row_num, run_id, raw_reporting_date, loan_id, loan_status, dpd,
      balance, current_fico, forbearance_flag, remaining_months, data_source)
    SELECT /*+ NO_PARALLEL(e) */ p_reporting_date, ROWNUM, p_run_id, e.reporting_date, e.loan_id,
           e.loan_status, e.dpd, e.balance, e.current_fico, e.forbearance_flag,
           e.remaining_months, e.data_source
      FROM ext_loan_snapshot e;
    l_rows := SQL%ROWCOUNT;
    COMMIT;

    INSERT INTO stg_control (reporting_date, run_id, control_file, expected_rows, expected_balance)
    SELECT p_reporting_date, p_run_id, l_control, TO_NUMBER(c.row_count), TO_NUMBER(c.total_balance)
      FROM ext_control c;
    l_controls := SQL%ROWCOUNT;
    IF l_controls <> 1 THEN
      RAISE_APPLICATION_ERROR(-20021, l_control || ' must hold exactly one data row; it has ' || l_controls);
    END IF;
    COMMIT;

    pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows,
                           'staged ' || l_rows || ' rows from ' || l_snapshot
                           || CASE WHEN l_purged > 0 THEN '; purged ' || l_purged || ' rows of an earlier run' END);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, l_snapshot || ': ' || pkg_batch_log.error_text);
      RAISE;
  END load_snapshot;

  ----------------------------------------------------------------------------
  PROCEDURE load_clean(p_reporting_date IN DATE, p_run_id IN NUMBER) IS
    l_step     NUMBER;
    l_received PLS_INTEGER;
    l_rows     PLS_INTEGER;
    l_fixed    PLS_INTEGER;
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'LOAD_CLEAN');
    set_number_format;
    -- Never load rows the data quality checks haven't looked at.
    pkg_batch_log.require_step(p_reporting_date, 'DQ_CHECKS');

    SELECT COUNT(*) INTO l_received FROM stg_loan_snapshot WHERE reporting_date = p_reporting_date;

    -- Re-runnable on its own: clear this date's clean rows and what was
    -- derived from them (the foreign keys require that order).
    DELETE FROM ecl_result         WHERE reporting_date = p_reporting_date;
    DELETE FROM ecl_result_v1      WHERE reporting_date = p_reporting_date;
    DELETE FROM loan_stage_history WHERE reporting_date = p_reporting_date;
    DELETE FROM pd_score           WHERE reporting_date = p_reporting_date;
    DELETE FROM loan_snapshot      WHERE reporting_date = p_reporting_date;
    COMMIT;

    -- One pass over the day's errors gives, per staged row, whether it was
    -- rejected and which WARN fixes apply; the insert then keeps only the
    -- rows without a REJECT. The WARN fixes follow the column the warning
    -- was raised on, not a hardcoded rule id.
    INSERT /*+ APPEND */ INTO loan_snapshot (
      reporting_date, loan_id, loan_status, dpd, balance, current_fico, forbearance_flag,
      remaining_months, data_source, source_row_num, run_id)
    WITH flags AS (
      SELECT row_num,
             MAX(CASE WHEN severity = 'REJECT' THEN 1 ELSE 0 END) AS rejected,
             MAX(CASE WHEN severity = 'WARN' AND column_name = 'CURRENT_FICO' THEN 1 ELSE 0 END) AS bad_fico,
             MAX(CASE WHEN severity = 'WARN' AND column_name = 'FORBEARANCE_FLAG' THEN 1 ELSE 0 END) AS bad_forbearance
        FROM dq_error
       WHERE reporting_date = p_reporting_date
       GROUP BY row_num
    )
    SELECT s.reporting_date,
           TO_NUMBER(TRIM(s.loan_id)),
           TRIM(s.loan_status),
           TO_NUMBER(TRIM(s.dpd)),
           TO_NUMBER(s.balance),
           CASE WHEN f.bad_fico = 1 THEN NULL ELSE TO_NUMBER(s.current_fico) END,
           CASE WHEN f.bad_forbearance = 1 THEN 'N' ELSE TRIM(s.forbearance_flag) END,
           TO_NUMBER(TRIM(s.remaining_months)),
           TRIM(s.data_source),
           s.row_num,
           p_run_id
      FROM stg_loan_snapshot s
      LEFT JOIN flags f ON f.row_num = s.row_num
     WHERE s.reporting_date = p_reporting_date
       AND NVL(f.rejected, 0) = 0;
    l_rows := SQL%ROWCOUNT;
    COMMIT;

    SELECT COUNT(DISTINCT row_num) INTO l_fixed
      FROM dq_error
     WHERE reporting_date = p_reporting_date AND severity = 'WARN'
       AND row_num NOT IN (SELECT row_num FROM dq_error
                            WHERE reporting_date = p_reporting_date AND severity = 'REJECT');

    pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows,
                           'accepted ' || l_rows || ' of ' || l_received || ' staged rows; rejected '
                           || (l_received - l_rows) || '; loaded with a warning fix ' || l_fixed);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END load_clean;

END pkg_load;
/
