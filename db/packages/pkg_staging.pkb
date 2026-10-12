CREATE OR REPLACE PACKAGE BODY pkg_staging AS

  FUNCTION fn_assign_stage(p_dpd               IN NUMBER,
                           p_loan_status       IN VARCHAR2,
                           p_forbearance_flag  IN VARCHAR2,
                           p_pd_12m_orig       IN NUMBER,
                           p_pd_12m_current    IN NUMBER,
                           p_prev_stage        IN NUMBER,
                           p_prev_cure_months  IN NUMBER,
                           p_stage2_dpd        IN NUMBER,
                           p_stage3_dpd        IN NUMBER,
                           p_sicr_relative     IN NUMBER,
                           p_sicr_absolute     IN NUMBER,
                           p_cure_months       IN NUMBER) RETURN stage_decision_t DETERMINISTIC IS
    -- Compiled for calls from SQL: assign_stages calls it once per loan.
    PRAGMA UDF;
    l_cure NUMBER;
  BEGIN
    -- Credit-impaired.
    IF p_dpd > p_stage3_dpd THEN
      RETURN stage_decision_t(3, 'DPD_90', 0);
    ELSIF p_loan_status = 'Default' THEN
      RETURN stage_decision_t(3, 'DEFAULT_STATUS', 0);
    END IF;

    -- Significant increase in credit risk.
    IF p_dpd > p_stage2_dpd THEN
      RETURN stage_decision_t(2, 'DPD_30', 0);
    ELSIF p_forbearance_flag = 'Y' THEN
      RETURN stage_decision_t(2, 'FORBEARANCE', 0);
    ELSIF p_pd_12m_current >= p_sicr_relative * p_pd_12m_orig
          AND p_pd_12m_current - p_pd_12m_orig >= p_sicr_absolute THEN
      -- Both tests: doubling a tiny PD (0.1% -> 0.2%) is not a significant
      -- increase, and neither is a small relative move on a high PD.
      RETURN stage_decision_t(2, 'PD_DETERIORATION', 0);
    END IF;

    -- Every Stage 1 condition is met this month. A loan coming out of Stage 2
    -- or 3 must show CURE_MONTHS good months in a row before it moves back.
    IF p_prev_stage IN (2, 3) THEN
      l_cure := NVL(p_prev_cure_months, 0) + 1;
      IF l_cure < p_cure_months THEN
        RETURN stage_decision_t(2, 'CURE_PROBATION', l_cure);
      END IF;
    END IF;
    RETURN stage_decision_t(1, 'PERFORMING', 0);
  END fn_assign_stage;

  FUNCTION fn_assign_stage(p_dpd               IN NUMBER,
                           p_loan_status       IN VARCHAR2,
                           p_forbearance_flag  IN VARCHAR2,
                           p_pd_12m_orig       IN NUMBER,
                           p_pd_12m_current    IN NUMBER,
                           p_prev_stage        IN NUMBER,
                           p_prev_cure_months  IN NUMBER) RETURN stage_decision_t IS
  BEGIN
    RETURN fn_assign_stage(p_dpd, p_loan_status, p_forbearance_flag, p_pd_12m_orig, p_pd_12m_current,
                           p_prev_stage, p_prev_cure_months,
                           pkg_params.get_number('STAGE2_DPD'), pkg_params.get_number('STAGE3_DPD'),
                           pkg_params.get_number('SICR_RELATIVE'), pkg_params.get_number('SICR_ABSOLUTE'),
                           pkg_params.get_number('CURE_MONTHS'));
  END fn_assign_stage;

  ----------------------------------------------------------------------------
  PROCEDURE assign_stages(p_reporting_date IN DATE, p_run_id IN NUMBER) IS
    l_step       NUMBER;
    l_stage2_dpd NUMBER;
    l_stage3_dpd NUMBER;
    l_relative   NUMBER;
    l_absolute   NUMBER;
    l_cure       NUMBER;
    l_assessed   PLS_INTEGER;
    l_exited     PLS_INTEGER := 0;
    l_changes    PLS_INTEGER;
    l_later      PLS_INTEGER;
    l_mix        VARCHAR2(400);
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'ASSIGN_STAGES');
    pkg_batch_log.require_step(p_reporting_date, 'SCORE_PD');
    -- Thresholds are read once, here, and passed to the function as values:
    -- one lookup per run instead of five per loan, and the function stays pure.
    l_stage2_dpd := pkg_params.get_number('STAGE2_DPD');
    l_stage3_dpd := pkg_params.get_number('STAGE3_DPD');
    l_relative   := pkg_params.get_number('SICR_RELATIVE');
    l_absolute   := pkg_params.get_number('SICR_ABSOLUTE');
    l_cure       := pkg_params.get_number('CURE_MONTHS');

    -- Re-runnable: the date's decisions are rebuilt from the previous
    -- assessment, never from this date's own first attempt.
    DELETE FROM loan_stage_history WHERE reporting_date = p_reporting_date;

    -- 1. Decide every loan in the snapshot. A loan's previous state is its
    --    latest assessment before this date (normally last month; earlier if
    --    last month's row was rejected by data quality).
    INSERT INTO loan_stage_history (reporting_date, loan_id, stage, reason_code, prev_stage,
                                    cure_months, stage_since, stage3_since, run_id)
    SELECT p_reporting_date, x.loan_id, x.d.stage, x.d.reason_code, x.prev_stage, x.d.cure_months,
           -- Same stage as before: keep the entry date. New stage: it starts now.
           CASE WHEN x.d.stage = x.prev_stage THEN x.prev_stage_since ELSE p_reporting_date END,
           CASE
             WHEN x.d.stage <> 3 THEN NULL
             WHEN x.prev_stage = 3 THEN x.prev_stage3_since
             -- First time in Stage 3: DPD says when it crossed 90 days, so the
             -- time-in-Stage-3 floor counts from that day, not from today.
             WHEN x.dpd > l_stage3_dpd THEN p_reporting_date - (x.dpd - l_stage3_dpd - 1)
             ELSE p_reporting_date
           END,
           p_run_id
      FROM (SELECT /*+ NO_MERGE */ s.loan_id, s.dpd,
                   h.stage AS prev_stage, h.stage_since AS prev_stage_since,
                   h.stage3_since AS prev_stage3_since,
                   pkg_staging.fn_assign_stage(s.dpd, s.loan_status, s.forbearance_flag,
                                               p.pd_12m_orig, p.pd_12m_current,
                                               h.stage, h.cure_months,
                                               l_stage2_dpd, l_stage3_dpd, l_relative,
                                               l_absolute, l_cure) AS d
              FROM loan_snapshot s
              JOIN pd_score p
                ON p.reporting_date = s.reporting_date AND p.loan_id = s.loan_id
              LEFT JOIN (SELECT loan_id, stage, cure_months, stage_since, stage3_since
                           FROM (SELECT h.*, ROW_NUMBER() OVER (PARTITION BY loan_id
                                                                ORDER BY reporting_date DESC) AS rn
                                   FROM loan_stage_history h
                                  WHERE h.reporting_date < p_reporting_date)
                          WHERE rn = 1) h
                ON h.loan_id = s.loan_id
             WHERE s.reporting_date = p_reporting_date) x;
    l_assessed := SQL%ROWCOUNT;

    -- Re-running an older month must not overwrite the current state of a
    -- later month: then only the history is rebuilt (re-run the later months too).
    SELECT COUNT(*) INTO l_later FROM loan_stage_history
     WHERE reporting_date > p_reporting_date AND ROWNUM = 1;

    IF l_later = 0 THEN
      -- 2. One MERGE brings LOAN_STAGE_CURRENT up to date. When a stage
      --    changes, TRG_STAGE_CHANGE_AUDIT writes the STAGE_CHANGE_AUDIT row.
      MERGE INTO loan_stage_current t
      USING (SELECT * FROM loan_stage_history WHERE reporting_date = p_reporting_date) s
         ON (t.loan_id = s.loan_id)
       WHEN MATCHED THEN UPDATE SET
              t.reporting_date = s.reporting_date, t.stage = s.stage, t.reason_code = s.reason_code,
              t.cure_months = s.cure_months, t.stage_since = s.stage_since,
              t.stage3_since = s.stage3_since, t.exited_flag = 'N', t.exited_date = NULL,
              t.updated_ts = SYSTIMESTAMP
       WHEN NOT MATCHED THEN INSERT (loan_id, reporting_date, stage, reason_code, cure_months,
                                     stage_since, stage3_since)
                             VALUES (s.loan_id, s.reporting_date, s.stage, s.reason_code,
                                     s.cure_months, s.stage_since, s.stage3_since);

      -- 3. Loans missing from this month's clean snapshot have left the book
      --    (paid off, written off, or rejected this month): marked, not deleted.
      UPDATE loan_stage_current t
         SET t.exited_flag = 'Y', t.exited_date = p_reporting_date, t.updated_ts = SYSTIMESTAMP
       WHERE t.exited_flag = 'N'
         AND t.reporting_date < p_reporting_date
         AND NOT EXISTS (SELECT 1 FROM loan_snapshot s
                          WHERE s.reporting_date = p_reporting_date AND s.loan_id = t.loan_id);
      l_exited := SQL%ROWCOUNT;
    END IF;

    SELECT COUNT(*) INTO l_changes FROM loan_stage_history
     WHERE reporting_date = p_reporting_date AND stage <> prev_stage;
    SELECT LISTAGG('stage ' || stage || '=' || n, ', ') WITHIN GROUP (ORDER BY stage) INTO l_mix
      FROM (SELECT stage, COUNT(*) n FROM loan_stage_history
             WHERE reporting_date = p_reporting_date GROUP BY stage);

    COMMIT;
    pkg_batch_log.end_step(l_step, 'SUCCESS', l_assessed,
      l_assessed || ' loans staged (' || l_mix || '); ' || l_changes || ' stage changes; '
      || l_exited || ' loans exited' || CASE WHEN l_later > 0
         THEN '; later months exist, so LOAN_STAGE_CURRENT was left as it is' END);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END assign_stages;

END pkg_staging;
/
