-- 04_external_tables.sql: external tables over the CSV files.
--
-- An external table is a table definition over a file: SELECT reads the file
-- through the ORACLE_LOADER access driver, nothing is stored in the database.
-- Every column is text so a malformed value can still be read and judged by
-- data quality instead of failing the read. The directory objects come from
-- 00_directories.sql (run as SYSTEM). The access driver writes its .log and
-- .bad files to logs/ through ECL_LOG_DIR.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

------------------------------------------------------------------ one-off history files
CREATE TABLE ext_loan_dev (
  loan_id VARCHAR2(100), loan_status VARCHAR2(100), default_flag VARCHAR2(100),
  issue_d VARCHAR2(100), term_months VARCHAR2(100), loan_amnt VARCHAR2(100),
  funded_amnt VARCHAR2(100), int_rate VARCHAR2(100), installment VARCHAR2(100),
  grade VARCHAR2(100), sub_grade VARCHAR2(100), emp_length VARCHAR2(100),
  home_ownership VARCHAR2(100), annual_inc VARCHAR2(100), verification_status VARCHAR2(100),
  purpose VARCHAR2(100), addr_state VARCHAR2(100), dti VARCHAR2(100),
  delinq_2yrs VARCHAR2(100), earliest_cr_line VARCHAR2(100), fico_range_low VARCHAR2(100),
  fico_range_high VARCHAR2(100), inq_last_6mths VARCHAR2(100), open_acc VARCHAR2(100),
  pub_rec VARCHAR2(100), revol_bal VARCHAR2(100), revol_util VARCHAR2(100),
  total_acc VARCHAR2(100), mort_acc VARCHAR2(100), pub_rec_bankruptcies VARCHAR2(100),
  application_type VARCHAR2(100), total_rec_prncp VARCHAR2(100), recoveries VARCHAR2(100),
  collection_recovery_fee VARCHAR2(100)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY ecl_processed_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE ecl_log_dir:'ext_loan_dev.bad'
    LOGFILE ecl_log_dir:'ext_loan_dev.log'
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('loans_dev.csv')
)
-- Our own generated file: any unreadable line is a bug, so fail the read.
REJECT LIMIT 0;

CREATE TABLE ext_portfolio_base (
  loan_id VARCHAR2(100), loan_status VARCHAR2(100), issue_d VARCHAR2(100),
  term_months VARCHAR2(100), loan_amnt VARCHAR2(100), funded_amnt VARCHAR2(100),
  int_rate VARCHAR2(100), installment VARCHAR2(100), grade VARCHAR2(100),
  sub_grade VARCHAR2(100), emp_length VARCHAR2(100), home_ownership VARCHAR2(100),
  annual_inc VARCHAR2(100), verification_status VARCHAR2(100), purpose VARCHAR2(100),
  addr_state VARCHAR2(100), dti VARCHAR2(100), delinq_2yrs VARCHAR2(100),
  earliest_cr_line VARCHAR2(100), fico_range_low VARCHAR2(100), fico_range_high VARCHAR2(100),
  inq_last_6mths VARCHAR2(100), open_acc VARCHAR2(100), pub_rec VARCHAR2(100),
  revol_bal VARCHAR2(100), revol_util VARCHAR2(100), total_acc VARCHAR2(100),
  mort_acc VARCHAR2(100), pub_rec_bankruptcies VARCHAR2(100), application_type VARCHAR2(100),
  balance VARCHAR2(100), current_fico VARCHAR2(100), forbearance_flag VARCHAR2(100),
  remaining_months VARCHAR2(100), dpd VARCHAR2(100), last_pymnt_d VARCHAR2(100),
  reporting_date VARCHAR2(100)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY ecl_processed_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE ecl_log_dir:'ext_portfolio_base.bad'
    LOGFILE ecl_log_dir:'ext_portfolio_base.log'
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('portfolio_base.csv')
)
REJECT LIMIT 0;

------------------------------------------------------------------ monthly files
-- LOCATION is a placeholder: PKG_LOAD.load_snapshot repoints both tables at
-- the reporting date's files with ALTER TABLE ... LOCATION before reading.
CREATE TABLE ext_loan_snapshot (
  reporting_date    VARCHAR2(200),
  loan_id           VARCHAR2(200),
  loan_status       VARCHAR2(200),
  dpd               VARCHAR2(200),
  balance           VARCHAR2(200),
  current_fico      VARCHAR2(200),
  forbearance_flag  VARCHAR2(200),
  remaining_months  VARCHAR2(200),
  data_source       VARCHAR2(200)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY ecl_incoming_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE ecl_log_dir:'ext_loan_snapshot.bad'
    LOGFILE ecl_log_dir:'ext_loan_snapshot.log'
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('loan_snapshot_placeholder.csv')
)
-- A line the driver can't read goes to the .bad file instead of stopping the
-- read. It still can't slip through: control reconciliation then finds fewer
-- staged rows than the control file promised and fails the batch.
REJECT LIMIT UNLIMITED;

CREATE TABLE ext_control (
  reporting_date  VARCHAR2(200),
  row_count       VARCHAR2(200),
  total_balance   VARCHAR2(200)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY ecl_incoming_dir
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY DETECTED NEWLINE
    SKIP 1
    BADFILE ecl_log_dir:'ext_control.bad'
    LOGFILE ecl_log_dir:'ext_control.log'
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
  )
  LOCATION ('control_placeholder.csv')
)
REJECT LIMIT 0;

------------------------------------------------------------------ descriptions
-- Oracle rejects COMMENT ON for external tables (ORA-30657), so the
-- descriptions go into EXT_TABLE_DOC; V_DATA_DICTIONARY merges them in.
INSERT INTO ext_table_doc (table_name, column_name, comments)
SELECT t, c, d FROM (
  SELECT 'EXT_LOAN_DEV' t, '(table)' c, 'External table over data/processed/loans_dev.csv (all text). PKG_LOAD.load_history converts it into LOAN_DEV.' d FROM dual UNION ALL
  SELECT 'EXT_PORTFOLIO_BASE', '(table)', 'External table over data/processed/portfolio_base.csv (all text). PKG_LOAD.load_history loads the application columns into LOAN_MASTER.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', '(table)', 'External table over one monthly snapshot file, data/incoming/loan_snapshot_YYYYMMDD.csv (all text). Repointed per reporting date by PKG_LOAD.load_snapshot.' FROM dual UNION ALL
  SELECT 'EXT_CONTROL', '(table)', 'External table over one control file, data/incoming/control_YYYYMMDD.csv: the row count and total balance the snapshot should hold.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'REPORTING_DATE', 'Month-end the row describes, YYYY-MM-DD.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'LOAN_ID', 'Lending Club loan id.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'LOAN_STATUS', 'Lending Club status at the reporting date.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'DPD', 'Days past due (whole number).' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'BALANCE', 'Outstanding principal, USD.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'CURRENT_FICO', 'Current FICO score.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'FORBEARANCE_FLAG', 'Y if the loan is in a hardship (forbearance) plan, otherwise N.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'REMAINING_MONTHS', 'Remaining contractual term in months.' FROM dual UNION ALL
  SELECT 'EXT_LOAN_SNAPSHOT', 'DATA_SOURCE', 'LC_ACTUAL or SIMULATED.' FROM dual UNION ALL
  SELECT 'EXT_CONTROL', 'REPORTING_DATE', 'Reporting date of the matching snapshot file, YYYY-MM-DD.' FROM dual UNION ALL
  SELECT 'EXT_CONTROL', 'ROW_COUNT', 'Number of data rows in the snapshot file.' FROM dual UNION ALL
  SELECT 'EXT_CONTROL', 'TOTAL_BALANCE', 'Sum of the balance column in the snapshot file, USD.' FROM dual
);

-- The history files carry the same fields as the tables they feed, so each
-- column points at its target instead of repeating 70 descriptions.
INSERT INTO ext_table_doc (table_name, column_name, comments)
SELECT table_name, column_name,
       CASE
         WHEN table_name = 'EXT_LOAN_DEV' THEN
           'Text from loans_dev.csv; converted into LOAN_DEV.' || column_name || '.'
         WHEN column_name IN ('LOAN_STATUS', 'BALANCE', 'CURRENT_FICO', 'FORBEARANCE_FLAG',
                              'REMAINING_MONTHS', 'DPD', 'LAST_PYMNT_D', 'REPORTING_DATE') THEN
           'Text from portfolio_base.csv: the loan''s state in the base month. Not stored in '
           || 'LOAN_MASTER; it reaches the database through the monthly snapshot file.'
         ELSE
           'Text from portfolio_base.csv; converted into LOAN_MASTER.' || column_name || '.'
       END
  FROM user_tab_columns
 WHERE table_name IN ('EXT_LOAN_DEV', 'EXT_PORTFOLIO_BASE');

COMMIT;
