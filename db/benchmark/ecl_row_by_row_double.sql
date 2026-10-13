-- Benchmark variant: run_v1's row-by-row loop with BINARY_DOUBLE arithmetic
-- instead of NUMBER, so the benchmark can separate the effect of the
-- processing style (loop vs one statement) from the effect of the number
-- type. Writes ECL_RESULT_V1 for pkg_ecl.compare_versions.
-- Binds: :reporting_date, :run_id. Not part of the engine.
DECLARE
  l_step     NUMBER;
  l_rows     PLS_INTEGER := 0;
  l_ecl      NUMBER;
  l_base     NUMBER;
  l_downside NUMBER;
  l_severe   NUMBER;
  l_weighted NUMBER;
  l_floor    NUMBER;

  FUNCTION ecl_double(p_balance BINARY_DOUBLE, p_annual_rate BINARY_DOUBLE, p_remaining PLS_INTEGER,
                      p_horizon PLS_INTEGER, p_pd BINARY_DOUBLE, p_lgd BINARY_DOUBLE,
                      p_stage PLS_INTEGER) RETURN BINARY_DOUBLE IS
    r        BINARY_DOUBLE := p_annual_rate / 12;
    payment  BINARY_DOUBLE;
    hazard   BINARY_DOUBLE;
    balance  BINARY_DOUBLE := p_balance;
    survival BINARY_DOUBLE := 1;
    discount BINARY_DOUBLE := 1;
    total    BINARY_DOUBLE := 0;
  BEGIN
    IF p_stage = 3 THEN
      RETURN p_lgd * p_balance;
    END IF;
    payment := CASE WHEN r = 0 THEN p_balance / p_remaining
                    ELSE p_balance * r / (1 - POWER(1 + r, -p_remaining)) END;
    hazard := 1 - POWER(1 - p_pd, 1D / 12);
    FOR t IN 1 .. p_horizon LOOP
      discount := discount / (1 + r);
      total    := total + survival * hazard * p_lgd * GREATEST(balance, 0) * discount;
      survival := survival * (1 - hazard);
      balance  := balance * (1 + r) - payment;
    END LOOP;
    RETURN total;
  END ecl_double;
BEGIN
  l_step := pkg_batch_log.start_step(:run_id, :reporting_date, 'BENCH_ROW_BY_ROW_DOUBLE');
  FOR l IN (SELECT * FROM v_ecl_input WHERE reporting_date = :reporting_date) LOOP
    l_weighted := 0;
    FOR s IN (SELECT scenario_code, weight, pd_multiplier FROM param_scenario) LOOP
      -- Stage 3 in exact NUMBER, as in run_v2; the schedule maths in BINARY_DOUBLE.
      l_ecl := CASE WHEN l.stage = 3 THEN l.lgd * l.balance
                    ELSE TO_NUMBER(ecl_double(l.balance, l.int_rate, l.remaining_months, l.horizon_months,
                                              LEAST(l.pd_12m * s.pd_multiplier, l.pd_cap), l.lgd, l.stage)) END;
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
      CASE WHEN l_floor > ROUND(l_weighted, 2) THEN 'Y' ELSE 'N' END, :run_id);
    l_rows := l_rows + 1;
  END LOOP;
  COMMIT;
  pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows, 'row by row, BINARY_DOUBLE arithmetic');
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
    RAISE;
END;
