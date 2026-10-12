-- 05_views.sql: the views the reports read. Every view and column has a
-- comment, so they appear in the generated data dictionary too.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

------------------------------------------------------------------ V_BATCH_STATUS
-- Latest status of each step, per reporting date: the first place to look
-- when a run fails.
CREATE OR REPLACE VIEW v_batch_status AS
SELECT reporting_date, step_name, status, run_id, started_ts, ended_ts,
       elapsed_seconds, rows_processed, message
  FROM (SELECT b.*,
               ROW_NUMBER() OVER (PARTITION BY reporting_date, step_name
                                  ORDER BY started_ts DESC, batch_run_id DESC) AS rn
          FROM batch_run b)
 WHERE rn = 1;

COMMENT ON TABLE v_batch_status IS 'Latest status of each batch step per reporting date (from BATCH_RUN).';
COMMENT ON COLUMN v_batch_status.reporting_date IS 'Reporting date the step ran for (null for one-off steps).';
COMMENT ON COLUMN v_batch_status.step_name IS 'Batch step.';
COMMENT ON COLUMN v_batch_status.status IS 'Latest status: RUNNING, SUCCESS or FAILED.';
COMMENT ON COLUMN v_batch_status.run_id IS 'Batch run of that latest attempt.';
COMMENT ON COLUMN v_batch_status.started_ts IS 'When the latest attempt started.';
COMMENT ON COLUMN v_batch_status.ended_ts IS 'When the latest attempt ended.';
COMMENT ON COLUMN v_batch_status.elapsed_seconds IS 'Run time of the latest attempt in seconds.';
COMMENT ON COLUMN v_batch_status.rows_processed IS 'Rows the latest attempt processed.';
COMMENT ON COLUMN v_batch_status.message IS 'Result summary or error stack of the latest attempt.';

------------------------------------------------------------------ V_DATA_DICTIONARY
-- One row per column of every table and view, with its description. Normal
-- tables and views carry Oracle comments; external tables can't
-- (ORA-30657), so their descriptions come from EXT_TABLE_DOC. The data
-- dictionary generator and the missing-comment check both read this view.
CREATE OR REPLACE VIEW v_data_dictionary AS
SELECT CASE
         WHEN o.object_type = 'VIEW' THEN 'VIEW'
         WHEN x.table_name IS NOT NULL THEN 'EXTERNAL TABLE'
         ELSE 'TABLE'
       END AS object_type,
       c.table_name,
       COALESCE(tc.comments, td.comments) AS table_comment,
       c.column_id,
       c.column_name,
       CASE
         WHEN c.data_type = 'NUMBER' AND c.data_precision IS NOT NULL
           THEN 'NUMBER(' || c.data_precision || CASE WHEN c.data_scale > 0 THEN ',' || c.data_scale END || ')'
         WHEN c.data_type IN ('VARCHAR2', 'CHAR') THEN c.data_type || '(' || c.char_length || ')'
         ELSE c.data_type
       END AS data_type,
       c.nullable,
       COALESCE(cc.comments, cd.comments) AS column_comment
  FROM user_tab_columns c
  JOIN user_objects o
    ON o.object_name = c.table_name AND o.object_type IN ('TABLE', 'VIEW')
  LEFT JOIN user_external_tables x ON x.table_name = c.table_name
  LEFT JOIN user_tab_comments tc ON tc.table_name = c.table_name
  LEFT JOIN user_col_comments cc ON cc.table_name = c.table_name AND cc.column_name = c.column_name
  LEFT JOIN ext_table_doc td ON td.table_name = c.table_name AND td.column_name = '(table)'
  LEFT JOIN ext_table_doc cd ON cd.table_name = c.table_name AND cd.column_name = c.column_name
 WHERE c.table_name NOT LIKE 'BIN$%';

COMMENT ON TABLE v_data_dictionary IS 'Every column of every table and view with its description, merging Oracle comments with EXT_TABLE_DOC. Source of docs/data_dictionary.md.';
COMMENT ON COLUMN v_data_dictionary.object_type IS 'TABLE, EXTERNAL TABLE or VIEW.';
COMMENT ON COLUMN v_data_dictionary.table_name IS 'Table or view name.';
COMMENT ON COLUMN v_data_dictionary.table_comment IS 'Description of the table or view.';
COMMENT ON COLUMN v_data_dictionary.column_id IS 'Column position.';
COMMENT ON COLUMN v_data_dictionary.column_name IS 'Column name.';
COMMENT ON COLUMN v_data_dictionary.data_type IS 'Oracle data type with length, precision and scale.';
COMMENT ON COLUMN v_data_dictionary.nullable IS 'Y if the column accepts nulls.';
COMMENT ON COLUMN v_data_dictionary.column_comment IS 'Description of the column.';

------------------------------------------------------------------ V_DQ_INPUT
-- What a data quality rule sees: one staged row plus the facts rules need
-- beyond the row itself. Working them out once here keeps every rule a
-- simple predicate and every rule a single set-based pass: the duplicate
-- check is one window function instead of a lookup per row.
CREATE OR REPLACE VIEW v_dq_input AS
SELECT x.reporting_date, x.row_num, x.run_id, x.raw_reporting_date, x.loan_id, x.loan_status,
       x.dpd, x.balance, x.current_fico, x.forbearance_flag, x.remaining_months, x.data_source,
       x.loan_id_num,
       -- 1 for the first row with this loan id in the file, 2 for the next copy, ...
       CASE WHEN x.loan_id_num IS NOT NULL
            THEN ROW_NUMBER() OVER (PARTITION BY x.reporting_date, x.loan_id_num ORDER BY x.row_num)
       END AS copy_no,
       CASE WHEN m.loan_id IS NOT NULL THEN 'Y' ELSE 'N' END AS in_master,
       m.funded_amnt AS master_funded_amnt
  FROM (SELECT s.*,
               -- Numeric id, so "0123" and "123" count as the same loan.
               CASE WHEN REGEXP_LIKE(TRIM(s.loan_id), '^[0-9]{1,12}$') THEN TO_NUMBER(TRIM(s.loan_id)) END AS loan_id_num
          FROM stg_loan_snapshot s) x
  LEFT JOIN loan_master m ON m.loan_id = x.loan_id_num;

COMMENT ON TABLE v_dq_input IS 'Staged snapshot rows plus the facts data quality rules need: numeric loan id, copy number within the file, and LOAN_MASTER membership and funded amount. DQ_RULE predicates are written against this view (alias s).';
COMMENT ON COLUMN v_dq_input.reporting_date IS 'Reporting date of the batch.';
COMMENT ON COLUMN v_dq_input.row_num IS 'Line of the row in the file (1 = first data line).';
COMMENT ON COLUMN v_dq_input.run_id IS 'Batch run that staged the row.';
COMMENT ON COLUMN v_dq_input.raw_reporting_date IS 'Reporting date as written in the row.';
COMMENT ON COLUMN v_dq_input.loan_id IS 'Loan id as received.';
COMMENT ON COLUMN v_dq_input.loan_status IS 'Status as received.';
COMMENT ON COLUMN v_dq_input.dpd IS 'Days past due as received.';
COMMENT ON COLUMN v_dq_input.balance IS 'Balance as received.';
COMMENT ON COLUMN v_dq_input.current_fico IS 'Current FICO as received.';
COMMENT ON COLUMN v_dq_input.forbearance_flag IS 'Forbearance flag as received.';
COMMENT ON COLUMN v_dq_input.remaining_months IS 'Remaining term as received.';
COMMENT ON COLUMN v_dq_input.data_source IS 'Data source as received.';
COMMENT ON COLUMN v_dq_input.loan_id_num IS 'Loan id as a number when it is 1-12 digits, otherwise null.';
COMMENT ON COLUMN v_dq_input.copy_no IS 'How many times this loan id has appeared so far in the file (1 = first). Null when the id is not numeric.';
COMMENT ON COLUMN v_dq_input.in_master IS 'Y if the loan id exists in LOAN_MASTER.';
COMMENT ON COLUMN v_dq_input.master_funded_amnt IS 'LOAN_MASTER.funded_amnt for the loan (null when unknown).';
