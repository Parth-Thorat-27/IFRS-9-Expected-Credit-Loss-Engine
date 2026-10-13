-- Benchmark variant: run_v2's set-based query with exact NUMBER arithmetic
-- instead of BINARY_DOUBLE. It was the first version of run_v2; kept here so
-- python/benchmark_ecl.py can re-measure it. Writes ECL_RESULT_V1 so
-- pkg_ecl.compare_versions can check it against production to the cent.
-- Binds: :reporting_date, :run_id. Not part of the engine.
DECLARE
  l_step NUMBER;
  l_rows PLS_INTEGER;
BEGIN
  l_step := pkg_batch_log.start_step(:run_id, :reporting_date, 'BENCH_SET_BASED_NUMBER');
  INSERT /*+ APPEND */ INTO ecl_result_v1 (
    reporting_date, loan_id, stage, reason_code, balance, int_rate, remaining_months,
    horizon_months, dpd, restructured_flag, months_in_stage3, lgd, pd_12m,
    ecl_base, ecl_downside, ecl_severe, ecl_weighted, floor_rate, floor_amount,
    ecl_final, floor_applied, run_id)
  WITH loans AS (
    SELECT /*+ MATERIALIZE */ i.*,
           i.int_rate / 12 AS r,
           CASE WHEN i.int_rate = 0 THEN i.balance / i.remaining_months
                ELSE i.balance * (i.int_rate / 12) / (1 - POWER(1 + i.int_rate / 12, -i.remaining_months))
           END AS payment
      FROM v_ecl_input i
     WHERE i.reporting_date = :reporting_date
  ),
  loan_scenarios AS (
    SELECT l.loan_id, l.stage, l.balance, l.lgd, l.r, l.payment, l.remaining_months,
           l.horizon_months, s.scenario_code, s.weight,
           1 - POWER(1 - LEAST(l.pd_12m * s.pd_multiplier, l.pd_cap), 1 / 12) AS hazard
      FROM loans l CROSS JOIN param_scenario s
  ),
  monthly_loss AS (
    SELECT ls.loan_id, ls.scenario_code, ls.weight, ls.stage, ls.lgd, ls.balance,
           POWER(1 - ls.hazard, mi.t - 1) * ls.hazard * ls.lgd
           * GREATEST(0, CASE WHEN ls.r = 0 THEN ls.balance * (1 - (mi.t - 1) / ls.remaining_months)
                              ELSE ls.balance * POWER(1 + ls.r, mi.t - 1)
                                   - ls.payment * (POWER(1 + ls.r, mi.t - 1) - 1) / ls.r END)
           * POWER(1 + ls.r, -mi.t) AS loss
      FROM loan_scenarios ls
      LEFT JOIN month_idx mi ON mi.t <= ls.horizon_months
  ),
  scenario_ecl AS (
    SELECT loan_id, scenario_code, MAX(weight) AS weight,
           CASE WHEN MAX(stage) = 3 THEN MAX(lgd * balance) ELSE NVL(SUM(loss), 0) END AS ecl
      FROM monthly_loss
     GROUP BY loan_id, scenario_code
  ),
  weighted AS (
    SELECT loan_id,
           MAX(CASE scenario_code WHEN 'BASE'     THEN ecl END) AS ecl_base,
           MAX(CASE scenario_code WHEN 'DOWNSIDE' THEN ecl END) AS ecl_downside,
           MAX(CASE scenario_code WHEN 'SEVERE'   THEN ecl END) AS ecl_severe,
           SUM(weight * ecl) AS ecl_weighted
      FROM scenario_ecl
     GROUP BY loan_id
  )
  SELECT l.reporting_date, l.loan_id, l.stage, l.reason_code, l.balance, l.int_rate,
         l.remaining_months, l.horizon_months, l.dpd, l.restructured_flag, l.months_in_stage3,
         l.lgd, l.pd_12m,
         ROUND(w.ecl_base, 2), ROUND(w.ecl_downside, 2), ROUND(w.ecl_severe, 2), ROUND(w.ecl_weighted, 2),
         l.floor_rate, ROUND(l.floor_rate * l.balance, 2),
         GREATEST(ROUND(w.ecl_weighted, 2), ROUND(l.floor_rate * l.balance, 2)),
         CASE WHEN ROUND(l.floor_rate * l.balance, 2) > ROUND(w.ecl_weighted, 2) THEN 'Y' ELSE 'N' END,
         :run_id
    FROM loans l
    JOIN weighted w ON w.loan_id = l.loan_id;
  l_rows := SQL%ROWCOUNT;
  COMMIT;
  pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows, 'set-based, NUMBER arithmetic');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
    RAISE;
END;
