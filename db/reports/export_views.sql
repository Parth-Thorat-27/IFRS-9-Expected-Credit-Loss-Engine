-- export_views.sql: one reporting date's management reports as CSV files,
-- one per report view. Power BI and the HTML report read the same numbers.
-- &1 = reporting date (YYYY-MM-DD), &2 = folder name (YYYYMMDD)
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
WHENEVER OSERROR EXIT FAILURE ROLLBACK
SET TERMOUT OFF FEEDBACK OFF VERIFY OFF ECHO OFF HEADING ON
SET MARKUP CSV ON QUOTE ON
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

-- SPOOL to a new file closes the previous one, so each report is one file.
SPOOL /opt/ecl/reports/&2/ecl_by_stage.csv
SELECT * FROM v_ecl_by_stage WHERE reporting_date = DATE '&1' ORDER BY stage;

SPOOL /opt/ecl/reports/&2/ecl_by_grade.csv
SELECT * FROM v_ecl_by_grade WHERE reporting_date = DATE '&1' ORDER BY grade, stage;

SPOOL /opt/ecl/reports/&2/ecl_by_state.csv
SELECT * FROM v_ecl_by_state WHERE reporting_date = DATE '&1' ORDER BY addr_state, stage;

SPOOL /opt/ecl/reports/&2/stage_migration.csv
SELECT * FROM v_stage_migration WHERE reporting_date = DATE '&1' ORDER BY from_stage, to_stage;

SPOOL /opt/ecl/reports/&2/ecl_movement.csv
SELECT * FROM v_ecl_movement WHERE reporting_date = DATE '&1' ORDER BY stage;

SPOOL /opt/ecl/reports/&2/floor_impact.csv
SELECT * FROM v_floor_impact WHERE reporting_date = DATE '&1' ORDER BY stage;

SPOOL /opt/ecl/reports/&2/scenario_sensitivity.csv
SELECT * FROM v_scenario_sensitivity WHERE reporting_date = DATE '&1';

SPOOL /opt/ecl/reports/&2/dq_summary.csv
SELECT * FROM v_dq_summary WHERE reporting_date = DATE '&1' ORDER BY rule_id;

SPOOL OFF
