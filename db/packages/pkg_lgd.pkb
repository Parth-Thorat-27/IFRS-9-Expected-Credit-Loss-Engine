CREATE OR REPLACE PACKAGE BODY pkg_lgd AS

  PROCEDURE calibrate(p_run_id IN NUMBER) IS
    l_step         NUMBER;
    l_min_defaults NUMBER;
    l_rows         PLS_INTEGER;
    l_summary      VARCHAR2(4000);
  BEGIN
    l_step := pkg_batch_log.start_step(p_run_id, NULL, 'CALIBRATE_LGD');
    l_min_defaults := pkg_params.get_number('LGD_MIN_DEFAULTS');

    -- One statement does the whole calibration: per-loan LGD, the EAD-weighted
    -- average per grade and for the portfolio, and the small-sample fallback.
    MERGE INTO param_lgd t
    USING (
      WITH loan_lgd AS (
        SELECT grade,
               funded_amnt - total_rec_prncp AS ead,
               LEAST(1, GREATEST(0,
                 1 - (NVL(recoveries, 0) - NVL(collection_recovery_fee, 0))
                     / (funded_amnt - total_rec_prncp))) AS lgd
          FROM loan_dev
         WHERE default_flag = 1
           -- Nothing was owed at charge-off: LGD is undefined (division by zero).
           AND funded_amnt - total_rec_prncp > 0
      ),
      portfolio AS (
        SELECT SUM(lgd * ead) / SUM(ead) AS lgd, COUNT(*) AS defaults_count, SUM(ead) AS ead_total
          FROM loan_lgd
      ),
      by_grade AS (
        SELECT grade, SUM(lgd * ead) / SUM(ead) AS lgd, COUNT(*) AS defaults_count, SUM(ead) AS ead_total
          FROM loan_lgd
         GROUP BY grade
      ),
      -- Every grade the engine can meet gets a row, even one with no defaults at all.
      grades AS (
        SELECT grade FROM loan_dev UNION SELECT grade FROM loan_master
      )
      SELECT g.grade,
             CASE WHEN NVL(b.defaults_count, 0) < l_min_defaults THEN p.lgd ELSE b.lgd END AS lgd,
             NVL(b.lgd, p.lgd)            AS grade_lgd,
             NVL(b.defaults_count, 0)     AS defaults_count,
             NVL(b.ead_total, 0)          AS ead_total,
             CASE WHEN NVL(b.defaults_count, 0) < l_min_defaults THEN 'Y' ELSE 'N' END AS fallback_flag
        FROM grades g
        CROSS JOIN portfolio p
        LEFT JOIN by_grade b ON b.grade = g.grade
      UNION ALL
      SELECT 'ALL', lgd, lgd, defaults_count, ead_total, 'N' FROM portfolio
    ) s
       ON (t.grade = s.grade)
     WHEN MATCHED THEN UPDATE SET t.lgd = s.lgd, t.grade_lgd = s.grade_lgd,
                                  t.defaults_count = s.defaults_count, t.ead_total = s.ead_total,
                                  t.fallback_flag = s.fallback_flag, t.calibrated_ts = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (grade, lgd, grade_lgd, defaults_count, ead_total, fallback_flag)
                           VALUES (s.grade, s.lgd, s.grade_lgd, s.defaults_count, s.ead_total,
                                   s.fallback_flag);
    l_rows := SQL%ROWCOUNT;

    SELECT LISTAGG(grade || '=' || TO_CHAR(ROUND(lgd, 4), 'FM0.0000')
                   || CASE fallback_flag WHEN 'Y' THEN '(fallback)' END, ' ')
             WITHIN GROUP (ORDER BY CASE grade WHEN 'ALL' THEN 'Z' ELSE grade END)
      INTO l_summary
      FROM param_lgd;

    COMMIT;
    pkg_batch_log.end_step(l_step, 'SUCCESS', l_rows,
                           'LGD_MIN_DEFAULTS=' || l_min_defaults || ': ' || l_summary);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      pkg_batch_log.end_step(l_step, 'FAILED', NULL, pkg_batch_log.error_text);
      RAISE;
  END calibrate;

END pkg_lgd;
/
