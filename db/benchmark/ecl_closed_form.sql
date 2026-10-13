-- Benchmark variant: set-based, but with no month rows at all.
--
-- The monthly sum is a geometric series, so it has a closed form. With
-- s = 1 - h (monthly survival), v = 1 / (1 + r) (monthly discount), P the
-- level payment and B the balance, the balance and discount factor fold
-- together as
--     EAD_t (1 + r)^-t = k1 + k2 v^t,   k1 = (B - P/r) / (1 + r),   k2 = P/r
-- and the ECL over H months becomes
--     ECL = LGD [ k1 (1 - s^H) + h k2 v (1 - (s v)^H) / (1 - s v) ]
-- One row per loan and scenario instead of one per loan, scenario and month.
-- Same results as production (checked to the cent), far less work; run_v2
-- keeps the month rows because each month's loss stays visible and auditable.
-- Loans at 0% interest (none in this data) would need the straight-line
-- schedule, so this variant refuses to run if it meets one.
-- Binds: :reporting_date, :run_id. Writes ECL_RESULT_V1. Not part of the engine.
DECLARE
  l_step NUMBER;
  l_rows PLS_INTEGER;
  l_zero PLS_INTEGER;
BEGIN
  l_step := pkg_batch_log.start_step(:run_id, :reporting_date, 'BENCH_CLOSED_FORM');
  SELECT COUNT(*) INTO l_zero FROM v_ecl_input WHERE reporting_date = :reporting_date AND int_rate = 0;
  IF l_zero > 0 THEN
    RAISE_APPLICATION_ERROR(-20043, l_zero || ' loans at 0% interest: the closed-form variant does not handle them');
  END IF;

  INSERT /*+ APPEND */ INTO ecl_result_v1 (
    reporting_date, loan_id, stage, reason_code, balance, int_rate, remaining_months,
    horizon_months, dpd, restructured_flag, months_in_stage3, lgd, pd_12m,
    ecl_base, ecl_downside, ecl_severe, ecl_weighted, floor_rate, floor_amount,
    ecl_final, floor_applied, run_id)
  WITH loans AS (
    SELECT /*+ MATERIALIZE */ i.*,
           TO_BINARY_DOUBLE(i.int_rate) / 12 AS r,
           TO_BINARY_DOUBLE(i.balance)       AS b,
           TO_BINARY_DOUBLE(i.lgd)           AS lgd_d
      FROM v_ecl_input i
     WHERE i.reporting_date = :reporting_date
  ),
  terms AS (
    SELECT x.*,
           (x.b - x.payment / x.r) / (1 + x.r) AS k1,
           x.payment / x.r                     AS k2,
           1 - x.hazard                        AS s,
           1 / (1 + x.r)                       AS v
      FROM (SELECT l.loan_id, l.stage, l.balance, l.lgd, l.b, l.r, l.lgd_d, l.horizon_months,
                   sc.scenario_code, sc.weight,
                   l.b * l.r / (1 - POWER(1 + l.r, -l.remaining_months)) AS payment,
                   1 - POWER(1 - LEAST(TO_BINARY_DOUBLE(l.pd_12m * sc.pd_multiplier), TO_BINARY_DOUBLE(l.pd_cap)),
                             1D / 12) AS hazard
              FROM loans l CROSS JOIN param_scenario sc) x
  ),
  scenario_ecl AS (
    SELECT loan_id, scenario_code, weight,
           CASE WHEN stage = 3 THEN lgd * balance
                ELSE TO_NUMBER(lgd_d * (k1 * (1 - POWER(s, horizon_months))
                               + hazard * k2 * v * (1 - POWER(s * v, horizon_months)) / (1 - s * v)))
           END AS ecl
      FROM terms
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
  pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows, 'set-based, closed-form sum, BINARY_DOUBLE');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
    RAISE;
END;
