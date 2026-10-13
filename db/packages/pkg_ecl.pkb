CREATE OR REPLACE PACKAGE BODY pkg_ecl AS

  ----------------------------------------------------------------------------
  -- One loan, one scenario. Walks the schedule month by month the way the
  -- methodology is written: B_t = B_{t-1}(1 + r) - P, EAD_t = B_{t-1}.
  ----------------------------------------------------------------------------
  FUNCTION fn_ecl_loan(p_balance          IN NUMBER,
                       p_annual_rate      IN NUMBER,
                       p_remaining_months IN NUMBER,
                       p_horizon_months   IN NUMBER,
                       p_pd_12m           IN NUMBER,
                       p_lgd              IN NUMBER,
                       p_stage            IN NUMBER) RETURN NUMBER DETERMINISTIC IS
    l_r        NUMBER := p_annual_rate / 12;
    l_payment  NUMBER;
    l_hazard   NUMBER;
    l_balance  NUMBER := p_balance;   -- B_{t-1}
    l_survival NUMBER := 1;           -- (1 - h)^(t-1)
    l_discount NUMBER := 1;           -- (1 + r)^-t, built up month by month
    l_ecl      NUMBER := 0;
  BEGIN
    IF p_stage = 3 THEN
      -- Credit-impaired: the loss is expected now, on today's balance.
      RETURN p_lgd * p_balance;
    END IF;

    l_payment := CASE WHEN l_r = 0 THEN p_balance / p_remaining_months
                      ELSE p_balance * l_r / (1 - POWER(1 + l_r, -p_remaining_months)) END;
    l_hazard := 1 - POWER(1 - p_pd_12m, 1 / 12);

    FOR t IN 1 .. p_horizon_months LOOP
      l_discount := l_discount / (1 + l_r);
      l_ecl      := l_ecl + l_survival * l_hazard * p_lgd * GREATEST(l_balance, 0) * l_discount;
      l_survival := l_survival * (1 - l_hazard);
      l_balance  := l_balance * (1 + l_r) - l_payment;
    END LOOP;
    RETURN l_ecl;
  END fn_ecl_loan;

  ----------------------------------------------------------------------------
  PROCEDURE check_complete(p_reporting_date IN DATE, p_table IN VARCHAR2, p_rows IN NUMBER) IS
    l_scored NUMBER;
  BEGIN
    -- Every scored loan must get exactly one ECL row: a missing parameter (no
    -- LGD for a grade, no floor for a case) would otherwise drop loans silently.
    SELECT COUNT(*) INTO l_scored FROM pd_score WHERE reporting_date = p_reporting_date;
    IF p_rows <> l_scored THEN
      RAISE_APPLICATION_ERROR(-20041, p_table || ' got ' || p_rows || ' rows for '
        || TO_CHAR(p_reporting_date, 'YYYY-MM-DD') || ' but ' || l_scored
        || ' loans were scored: check PARAM_LGD and PARAM_FLOOR cover every loan');
    END IF;
  END check_complete;

  ----------------------------------------------------------------------------
  PROCEDURE run_v2(p_reporting_date IN DATE, p_run_id IN NUMBER) IS
    l_step NUMBER;
    l_rows PLS_INTEGER;
    l_ecl  NUMBER;
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'RUN_ECL');
    pkg_batch_log.require_step(p_reporting_date, 'ASSIGN_STAGES');

    DELETE FROM ecl_result WHERE reporting_date = p_reporting_date;
    COMMIT;

    -- Arithmetic: the per-month probabilities, balances and discount factors
    -- are BINARY_DOUBLE (hardware floating point). Oracle NUMBER is exact
    -- decimal arithmetic done in software, and with millions of powers and
    -- divisions it made this query 2.7x slower than the row-by-row loop
    -- (docs/performance.md). Money is still NUMBER: Stage 3 losses and floors
    -- are computed exactly, and every stored amount is converted back to
    -- NUMBER and rounded to cents. run_v1 works in NUMBER throughout, so
    -- compare_versions proves the floating point never changes a cent.
    INSERT /*+ APPEND */ INTO ecl_result (
      reporting_date, loan_id, stage, reason_code, balance, int_rate, remaining_months,
      horizon_months, dpd, restructured_flag, months_in_stage3, lgd, pd_12m,
      ecl_base, ecl_downside, ecl_severe, ecl_weighted, floor_rate, floor_amount,
      ecl_final, floor_applied, run_id)
    WITH loans AS (
      -- MATERIALIZE: the joined input view is read once into a temporary
      -- result; the CTE is used twice below and would otherwise be re-run.
      SELECT /*+ MATERIALIZE */ i.*,
             TO_BINARY_DOUBLE(i.int_rate) / 12 AS r_d,
             TO_BINARY_DOUBLE(i.balance)       AS balance_d,
             TO_BINARY_DOUBLE(i.lgd)           AS lgd_d
        FROM v_ecl_input i
       WHERE i.reporting_date = p_reporting_date
    ),
    loan_scenarios AS (
      SELECT l.loan_id, l.stage, l.balance, l.lgd, l.balance_d, l.lgd_d, l.r_d,
             l.remaining_months, l.horizon_months, s.scenario_code, s.weight,
             -- Level payment that clears today's balance over the remaining term.
             CASE WHEN l.r_d = 0 THEN l.balance_d / l.remaining_months
                  ELSE l.balance_d * l.r_d / (1 - POWER(1 + l.r_d, -l.remaining_months)) END AS payment,
             -- Monthly hazard from the scenario's 12-month PD (capped).
             1 - POWER(1 - LEAST(TO_BINARY_DOUBLE(l.pd_12m * s.pd_multiplier), TO_BINARY_DOUBLE(l.pd_cap)),
                       1D / 12) AS hazard
        FROM loans l
        CROSS JOIN param_scenario s
    ),
    monthly_loss AS (
      -- One row per loan, scenario and month t of the horizon. Stage 3 loans
      -- have no months (horizon 0); the outer join keeps them with t null.
      SELECT ls.loan_id, ls.scenario_code, ls.weight, ls.stage, ls.lgd, ls.balance,
             POWER(1 - ls.hazard, mi.t - 1) * ls.hazard     -- survive t-1 months, default in month t
             * ls.lgd_d
             * GREATEST(0,                                  -- EAD_t: balance after t-1 payments (closed form)
                 CASE WHEN ls.r_d = 0
                      THEN ls.balance_d * (1 - (mi.t - 1) / ls.remaining_months)
                      ELSE ls.balance_d * POWER(1 + ls.r_d, mi.t - 1)
                           - ls.payment * (POWER(1 + ls.r_d, mi.t - 1) - 1) / ls.r_d
                 END)
             * POWER(1 + ls.r_d, -mi.t)                     -- discounted to the reporting date
             AS loss
        FROM loan_scenarios ls
        LEFT JOIN month_idx mi ON mi.t <= ls.horizon_months
    ),
    scenario_ecl AS (
      SELECT loan_id, scenario_code, MAX(weight) AS weight,
             CASE WHEN MAX(stage) = 3 THEN MAX(lgd * balance)     -- exact NUMBER
                  ELSE TO_NUMBER(NVL(SUM(loss), 0)) END AS ecl
        FROM monthly_loss
       GROUP BY loan_id, scenario_code
    ),
    weighted AS (
      SELECT loan_id,
             MAX(CASE scenario_code WHEN 'BASE'     THEN ecl END) AS ecl_base,
             MAX(CASE scenario_code WHEN 'DOWNSIDE' THEN ecl END) AS ecl_downside,
             MAX(CASE scenario_code WHEN 'SEVERE'   THEN ecl END) AS ecl_severe,
             SUM(weight * ecl)                                    AS ecl_weighted
        FROM scenario_ecl
       GROUP BY loan_id
    )
    SELECT l.reporting_date, l.loan_id, l.stage, l.reason_code, l.balance, l.int_rate,
           l.remaining_months, l.horizon_months, l.dpd, l.restructured_flag, l.months_in_stage3,
           l.lgd, l.pd_12m,
           ROUND(w.ecl_base, 2), ROUND(w.ecl_downside, 2), ROUND(w.ecl_severe, 2),
           ROUND(w.ecl_weighted, 2),
           l.floor_rate,
           ROUND(l.floor_rate * l.balance, 2),
           GREATEST(ROUND(w.ecl_weighted, 2), ROUND(l.floor_rate * l.balance, 2)),
           CASE WHEN ROUND(l.floor_rate * l.balance, 2) > ROUND(w.ecl_weighted, 2) THEN 'Y' ELSE 'N' END,
           p_run_id
      FROM loans l
      JOIN weighted w ON w.loan_id = l.loan_id;
    l_rows := SQL%ROWCOUNT;
    COMMIT;
    check_complete(p_reporting_date, 'ECL_RESULT', l_rows);

    SELECT SUM(ecl_final) INTO l_ecl FROM ecl_result WHERE reporting_date = p_reporting_date;
    pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows,
      l_rows || ' loans, final ECL ' || TO_CHAR(l_ecl, 'FM999,999,999,990.00'));
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END run_v2;

  ----------------------------------------------------------------------------
  PROCEDURE run_v1(p_reporting_date IN DATE, p_run_id IN NUMBER) IS
    l_step     NUMBER;
    l_rows     PLS_INTEGER := 0;
    l_ecl      NUMBER;
    l_base     NUMBER;
    l_downside NUMBER;
    l_severe   NUMBER;
    l_weighted NUMBER;
    l_floor    NUMBER;
    l_total    NUMBER;
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, p_reporting_date, 'RUN_ECL_V1');
    pkg_batch_log.require_step(p_reporting_date, 'ASSIGN_STAGES');

    DELETE FROM ecl_result_v1 WHERE reporting_date = p_reporting_date;
    COMMIT;

    -- The slow way on purpose: a cursor over the loans, a query for the
    -- scenarios inside it, a PL/SQL function call per loan per scenario, and
    -- one single-row INSERT per loan. Every step is a switch between the SQL
    -- and PL/SQL engines; run_v2 does the same work in one statement.
    FOR l IN (SELECT * FROM v_ecl_input WHERE reporting_date = p_reporting_date) LOOP
      l_weighted := 0;
      FOR s IN (SELECT scenario_code, weight, pd_multiplier FROM param_scenario) LOOP
        l_ecl := fn_ecl_loan(l.balance, l.int_rate, l.remaining_months, l.horizon_months,
                             LEAST(l.pd_12m * s.pd_multiplier, l.pd_cap), l.lgd, l.stage);
        CASE s.scenario_code
          WHEN 'BASE'     THEN l_base     := l_ecl;
          WHEN 'DOWNSIDE' THEN l_downside := l_ecl;
          WHEN 'SEVERE'   THEN l_severe   := l_ecl;
        END CASE;
        l_weighted := l_weighted + s.weight * l_ecl;
      END LOOP;
      l_floor := ROUND(l.floor_rate * l.balance, 2);

      INSERT INTO ecl_result_v1 (
        reporting_date, loan_id, stage, reason_code, balance, int_rate, remaining_months,
        horizon_months, dpd, restructured_flag, months_in_stage3, lgd, pd_12m,
        ecl_base, ecl_downside, ecl_severe, ecl_weighted, floor_rate, floor_amount,
        ecl_final, floor_applied, run_id)
      VALUES (
        l.reporting_date, l.loan_id, l.stage, l.reason_code, l.balance, l.int_rate, l.remaining_months,
        l.horizon_months, l.dpd, l.restructured_flag, l.months_in_stage3, l.lgd, l.pd_12m,
        ROUND(l_base, 2), ROUND(l_downside, 2), ROUND(l_severe, 2), ROUND(l_weighted, 2),
        l.floor_rate, l_floor, GREATEST(ROUND(l_weighted, 2), l_floor),
        CASE WHEN l_floor > ROUND(l_weighted, 2) THEN 'Y' ELSE 'N' END, p_run_id);
      l_rows := l_rows + 1;
    END LOOP;
    COMMIT;
    check_complete(p_reporting_date, 'ECL_RESULT_V1', l_rows);

    SELECT SUM(ecl_final) INTO l_total FROM ecl_result_v1 WHERE reporting_date = p_reporting_date;
    pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows,
      l_rows || ' loans row by row, final ECL ' || TO_CHAR(l_total, 'FM999,999,999,990.00'));
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END run_v1;

  ----------------------------------------------------------------------------
  FUNCTION compare_versions(p_reporting_date IN DATE) RETURN NUMBER IS
    l_unmatched NUMBER;
    l_max_diff  NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_unmatched
      FROM (SELECT loan_id FROM ecl_result    WHERE reporting_date = p_reporting_date
            MINUS
            SELECT loan_id FROM ecl_result_v1 WHERE reporting_date = p_reporting_date
            UNION ALL
            (SELECT loan_id FROM ecl_result_v1 WHERE reporting_date = p_reporting_date
             MINUS
             SELECT loan_id FROM ecl_result    WHERE reporting_date = p_reporting_date));
    IF l_unmatched > 0 THEN
      RAISE_APPLICATION_ERROR(-20042, l_unmatched || ' loans are in only one of ECL_RESULT and '
                              || 'ECL_RESULT_V1 for ' || TO_CHAR(p_reporting_date, 'YYYY-MM-DD'));
    END IF;

    SELECT MAX(GREATEST(ABS(a.ecl_base - b.ecl_base), ABS(a.ecl_downside - b.ecl_downside),
                        ABS(a.ecl_severe - b.ecl_severe), ABS(a.ecl_weighted - b.ecl_weighted),
                        ABS(a.floor_amount - b.floor_amount), ABS(a.ecl_final - b.ecl_final)))
      INTO l_max_diff
      FROM ecl_result a
      JOIN ecl_result_v1 b ON b.reporting_date = a.reporting_date AND b.loan_id = a.loan_id
     WHERE a.reporting_date = p_reporting_date;
    RETURN l_max_diff;
  END compare_versions;

END pkg_ecl;
/
