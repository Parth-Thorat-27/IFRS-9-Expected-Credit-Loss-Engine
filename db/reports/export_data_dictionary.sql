-- export_data_dictionary.sql: every table, external table and view with its
-- columns and descriptions, as tab-separated lines that
-- scripts/generate_data_dictionary.sh turns into docs/data_dictionary.md.
-- &1 = file name to write in /opt/ecl/logs
--
-- It writes to a file instead of the screen because some descriptions quote
-- Oracle error codes, and run_sql treats any ORA- line it sees as a failure.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
WHENEVER OSERROR EXIT FAILURE ROLLBACK
SET TERMOUT OFF FEEDBACK OFF VERIFY OFF ECHO OFF HEADING OFF PAGESIZE 0
SET LINESIZE 32767 TRIMSPOOL ON TAB OFF

SPOOL /opt/ecl/logs/&1
-- A T line for each object, followed by a C line for each of its columns.
-- Tables first, then external tables, then views; by name within each.
SELECT line
  FROM (SELECT DISTINCT
               DECODE(object_type, 'TABLE', 1, 'EXTERNAL TABLE', 2, 3) AS type_order,
               table_name, 0 AS column_id,
               'T' || CHR(9) || object_type || CHR(9) || table_name || CHR(9) || table_comment AS line
          FROM v_data_dictionary
        UNION ALL
        SELECT DECODE(object_type, 'TABLE', 1, 'EXTERNAL TABLE', 2, 3),
               table_name, column_id,
               'C' || CHR(9) || column_name || CHR(9) || data_type || CHR(9) || nullable
                   || CHR(9) || column_comment
          FROM v_data_dictionary)
 ORDER BY type_order, table_name, column_id;
SPOOL OFF
