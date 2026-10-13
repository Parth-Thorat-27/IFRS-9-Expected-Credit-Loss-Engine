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

------------------------------------------------------------------ V_ECL_INPUT
-- Everything the ECL needs for one loan on one reporting date, in one row.
-- Both engines read this view, so run_v1 and run_v2 start from exactly the
-- same inputs and can only differ in how they calculate.
CREATE OR REPLACE VIEW v_ecl_input AS
SELECT s.reporting_date,
       s.loan_id,
       m.grade,
       h.stage,
       h.reason_code,
       s.balance,
       m.int_rate,
       s.remaining_months,
       -- 12 months of losses for Stage 1, the remaining life for Stage 2,
       -- none for Stage 3 (ECL = LGD x balance, no schedule).
       CASE h.stage WHEN 1 THEN LEAST(12, s.remaining_months)
                    WHEN 2 THEN s.remaining_months
                    ELSE 0 END AS horizon_months,
       s.dpd,
       s.forbearance_flag AS restructured_flag,
       CASE WHEN h.stage = 3 THEN FLOOR(MONTHS_BETWEEN(s.reporting_date, h.stage3_since)) END AS months_in_stage3,
       l.lgd,
       p.pd_12m_current,
       dm.multiplier AS dpd_multiplier,
       -- Measurement PD: Stage 3 has defaulted (PD 1); otherwise the current
       -- PD times the DPD multiplier, capped.
       CASE WHEN h.stage = 3 THEN 1 ELSE LEAST(p.pd_12m_current * dm.multiplier, c.pd_cap) END AS pd_12m,
       c.pd_cap,
       f.floor_rate
  FROM loan_snapshot s
  JOIN loan_master m        ON m.loan_id = s.loan_id
  JOIN loan_stage_history h ON h.reporting_date = s.reporting_date AND h.loan_id = s.loan_id
  JOIN pd_score p           ON p.reporting_date = s.reporting_date AND p.loan_id = s.loan_id
  JOIN param_lgd l          ON l.grade = m.grade
  CROSS JOIN (SELECT setting_value AS pd_cap FROM param_setting WHERE setting_name = 'PD_CAP') c
  -- Stage 3 loans are past 90 DPD, beyond the last band; they don't use a multiplier.
  LEFT JOIN param_dpd_multiplier dm ON s.dpd BETWEEN dm.from_dpd AND dm.to_dpd
  LEFT JOIN param_floor f
    ON f.stage = h.stage
   AND (   (h.stage IN (1, 2) AND f.restructured_flag = s.forbearance_flag)
        OR (h.stage = 3 AND f.restructured_flag = '*'
            AND FLOOR(MONTHS_BETWEEN(s.reporting_date, h.stage3_since)) >= f.months_in_stage3_from
            AND (f.months_in_stage3_to IS NULL
                 OR FLOOR(MONTHS_BETWEEN(s.reporting_date, h.stage3_since)) < f.months_in_stage3_to)));

COMMENT ON TABLE v_ecl_input IS 'One row per loan per reporting date with every ECL input: stage, balance, rate, horizon, LGD, measurement PD and floor rate. PKG_ECL.run_v1 and run_v2 both read it.';
COMMENT ON COLUMN v_ecl_input.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN v_ecl_input.loan_id IS 'Loan.';
COMMENT ON COLUMN v_ecl_input.grade IS 'Lending Club grade (selects the LGD).';
COMMENT ON COLUMN v_ecl_input.stage IS 'Stage from LOAN_STAGE_HISTORY.';
COMMENT ON COLUMN v_ecl_input.reason_code IS 'Staging reason code.';
COMMENT ON COLUMN v_ecl_input.balance IS 'Outstanding principal, USD.';
COMMENT ON COLUMN v_ecl_input.int_rate IS 'Annual contract rate (fraction).';
COMMENT ON COLUMN v_ecl_input.remaining_months IS 'Remaining contractual term n.';
COMMENT ON COLUMN v_ecl_input.horizon_months IS 'Months of loss counted: min(12, n) for Stage 1, n for Stage 2, 0 for Stage 3.';
COMMENT ON COLUMN v_ecl_input.dpd IS 'Days past due.';
COMMENT ON COLUMN v_ecl_input.restructured_flag IS 'Forbearance flag, used to choose the restructured floor.';
COMMENT ON COLUMN v_ecl_input.months_in_stage3 IS 'Whole months since stage3_since (Stage 3 only).';
COMMENT ON COLUMN v_ecl_input.lgd IS 'LGD for the grade from PARAM_LGD.';
COMMENT ON COLUMN v_ecl_input.pd_12m_current IS 'Current 12-month PD from PD_SCORE.';
COMMENT ON COLUMN v_ecl_input.dpd_multiplier IS 'PD multiplier of the loan''s DPD band (null in Stage 3).';
COMMENT ON COLUMN v_ecl_input.pd_12m IS 'Measurement PD before scenarios: 1 in Stage 3, otherwise pd_12m_current x DPD multiplier capped at PD_CAP.';
COMMENT ON COLUMN v_ecl_input.pd_cap IS 'PD_CAP from the parameters; scenario PDs are capped at it too.';
COMMENT ON COLUMN v_ecl_input.floor_rate IS 'RBI floor rate for the loan''s stage, restructured status and time in Stage 3.';
