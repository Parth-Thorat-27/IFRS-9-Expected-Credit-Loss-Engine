-- dq_rules.sql: the data quality rules, as metadata.
--
-- Each predicate is a SQL condition over V_DQ_INPUT (alias s) that is TRUE
-- for a bad row. V_DQ_INPUT is one staged row plus what the rules need
-- beyond it: the loan id as a number (loan_id_num), the copy number of that
-- id within the file (copy_no), and the loan's LOAN_MASTER data
-- (in_master, master_funded_amnt). PKG_DQ.run_checks runs every active rule;
-- adding a rule is an INSERT here, not a code change.
--
-- Conversions use DEFAULT NULL ON CONVERSION ERROR because SQL doesn't
-- promise to evaluate OR conditions left to right: a bare TO_NUMBER('N/A')
-- could raise an error before the "is it numeric?" test runs.
-- Re-runnable: MERGE by rule_id.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

MERGE INTO dq_rule t
USING (
  SELECT 'DQ001' rule_id, 'Loan id missing' rule_name, 'REJECT' severity, 'LOAN_ID' column_name,
         q'[TRIM(s.loan_id) IS NULL]' predicate,
         'Loan id is missing: the row cannot be matched to a loan.' message FROM dual UNION ALL
  SELECT 'DQ002', 'Loan id not a number', 'REJECT', 'LOAN_ID',
         q'[TRIM(s.loan_id) IS NOT NULL AND s.loan_id_num IS NULL]',
         'Loan id is not a whole number of up to 12 digits.' FROM dual UNION ALL
  SELECT 'DQ003', 'Loan id repeated', 'REJECT', 'LOAN_ID',
         q'[s.copy_no > 1]',
         'Loan id already appeared earlier in the file; only the first copy is loaded.' FROM dual UNION ALL
  SELECT 'DQ004', 'Loan id unknown', 'REJECT', 'LOAN_ID',
         q'[s.loan_id_num IS NOT NULL AND s.in_master = 'N']',
         'Loan id is not in LOAN_MASTER: no application data, so the loan cannot be scored.' FROM dual UNION ALL
  SELECT 'DQ005', 'Balance missing, invalid or negative', 'REJECT', 'BALANCE',
         q'[TO_NUMBER(s.balance DEFAULT NULL ON CONVERSION ERROR) IS NULL
            OR TO_NUMBER(s.balance DEFAULT NULL ON CONVERSION ERROR) < 0]',
         'Balance is missing, not a number, or negative.' FROM dual UNION ALL
  SELECT 'DQ006', 'Balance above funded amount', 'REJECT', 'BALANCE',
         q'[TO_NUMBER(s.balance DEFAULT NULL ON CONVERSION ERROR) > s.master_funded_amnt]',
         'Balance is above the amount the loan was funded with.' FROM dual UNION ALL
  SELECT 'DQ007', 'DPD invalid', 'REJECT', 'DPD',
         q'[s.dpd IS NULL OR NOT REGEXP_LIKE(TRIM(s.dpd), '^[0-9]{1,5}$')]',
         'Days past due is missing, not a whole number, or negative.' FROM dual UNION ALL
  SELECT 'DQ008', 'Current FICO out of range', 'WARN', 'CURRENT_FICO',
         q'[NVL(TO_NUMBER(s.current_fico DEFAULT NULL ON CONVERSION ERROR), -1) NOT BETWEEN 300 AND 850]',
         'Current FICO is missing or outside 300-850; the origination FICO is used instead.' FROM dual UNION ALL
  SELECT 'DQ009', 'Forbearance flag invalid', 'WARN', 'FORBEARANCE_FLAG',
         q'[NVL(TRIM(s.forbearance_flag), '?') NOT IN ('Y', 'N')]',
         'Forbearance flag is not Y or N; treated as N.' FROM dual UNION ALL
  SELECT 'DQ010', 'Reporting date mismatch', 'REJECT', 'RAW_REPORTING_DATE',
         q'[NVL(TO_DATE(s.raw_reporting_date DEFAULT NULL ON CONVERSION ERROR, 'FXYYYY-MM-DD'),
                DATE '0001-01-01') <> s.reporting_date]',
         'The row''s reporting date is missing, malformed or differs from the batch date.' FROM dual UNION ALL
  -- Not in the spec's starting list: these guard the two remaining columns
  -- load_clean converts, so a bad value is rejected with a reason instead of
  -- failing the whole typed load.
  SELECT 'DQ011', 'Remaining term invalid', 'REJECT', 'REMAINING_MONTHS',
         q'[s.remaining_months IS NULL OR NOT REGEXP_LIKE(TRIM(s.remaining_months), '^[0-9]{1,4}$')
            OR TO_NUMBER(TRIM(s.remaining_months) DEFAULT NULL ON CONVERSION ERROR) < 1]',
         'Remaining term is missing or not a whole number of at least 1 month.' FROM dual UNION ALL
  SELECT 'DQ012', 'Data source invalid', 'REJECT', 'DATA_SOURCE',
         q'[NVL(TRIM(s.data_source), '?') NOT IN ('LC_ACTUAL', 'SIMULATED')]',
         'Data source is not LC_ACTUAL or SIMULATED.' FROM dual
) s
   ON (t.rule_id = s.rule_id)
 WHEN MATCHED THEN UPDATE SET t.rule_name = s.rule_name, t.severity = s.severity,
                              t.column_name = s.column_name, t.predicate = s.predicate,
                              t.message = s.message
 WHEN NOT MATCHED THEN INSERT (rule_id, rule_name, severity, column_name, predicate, message)
                       VALUES (s.rule_id, s.rule_name, s.severity, s.column_name, s.predicate, s.message);

COMMIT;
