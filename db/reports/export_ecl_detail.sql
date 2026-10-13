-- export_ecl_detail.sql: one reporting date's ECL, loan by loan, as CSV.
-- The detail file is the base for the Power BI dashboard (docs/powerbi_guide.md).
-- &1 = reporting date (YYYY-MM-DD), &2 = folder name (YYYYMMDD)
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
WHENEVER OSERROR EXIT FAILURE ROLLBACK
-- TERMOUT OFF keeps 100,000 rows out of the batch log; they only go to the file.
SET TERMOUT OFF FEEDBACK OFF VERIFY OFF ECHO OFF HEADING ON
SET MARKUP CSV ON QUOTE ON
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

SPOOL /opt/ecl/reports/&2/ecl_detail.csv
SELECT e.reporting_date, e.loan_id, m.grade, m.sub_grade, m.addr_state, m.purpose,
       e.stage, e.reason_code, e.balance, e.int_rate, e.remaining_months, e.horizon_months,
       e.dpd, e.restructured_flag, e.months_in_stage3, e.lgd, e.pd_12m,
       e.ecl_base, e.ecl_downside, e.ecl_severe, e.ecl_weighted,
       e.floor_rate, e.floor_amount, e.ecl_final, e.floor_applied
  FROM ecl_result e
  JOIN loan_master m ON m.loan_id = e.loan_id
 WHERE e.reporting_date = DATE '&1'
 ORDER BY e.loan_id;
SPOOL OFF
