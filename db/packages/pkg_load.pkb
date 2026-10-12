CREATE OR REPLACE PACKAGE BODY pkg_load AS

  -- The CSVs write numbers with a "." decimal point. Pin the session to
  -- that, so TO_NUMBER can't misread them under a client with other settings.
  PROCEDURE set_number_format IS
  BEGIN
    EXECUTE IMMEDIATE q'[ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,']';
  END set_number_format;

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

END pkg_load;
/
