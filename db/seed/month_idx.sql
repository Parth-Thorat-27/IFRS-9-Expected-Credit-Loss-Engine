-- Months 1 to 60: one row per month of the longest possible remaining term
-- (60-month loans). Re-runnable: MERGE inserts only the missing months.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

MERGE INTO month_idx m
USING (SELECT LEVEL AS t FROM dual CONNECT BY LEVEL <= 60) s
   ON (m.t = s.t)
 WHEN NOT MATCHED THEN INSERT (t) VALUES (s.t);

COMMIT;
