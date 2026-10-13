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

------------------------------------------------------------------ report views
-- The management reports read these. All amounts are USD; coverage = ECL / balance.

CREATE OR REPLACE VIEW v_ecl_by_stage AS
SELECT reporting_date, stage,
       COUNT(*)                                            AS loans,
       SUM(balance)                                        AS balance,
       SUM(ecl_final)                                      AS ecl_final,
       ROUND(SUM(ecl_final) / NULLIF(SUM(balance), 0), 6)  AS coverage,
       ROUND(SUM(balance) / SUM(SUM(balance)) OVER (PARTITION BY reporting_date), 6) AS balance_share
  FROM ecl_result
 GROUP BY reporting_date, stage;

COMMENT ON TABLE v_ecl_by_stage IS 'Loans, balance, final ECL, coverage and share of balance by reporting date and stage.';
COMMENT ON COLUMN v_ecl_by_stage.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN v_ecl_by_stage.stage IS 'IFRS 9 stage.';
COMMENT ON COLUMN v_ecl_by_stage.loans IS 'Number of loans.';
COMMENT ON COLUMN v_ecl_by_stage.balance IS 'Outstanding balance, USD.';
COMMENT ON COLUMN v_ecl_by_stage.ecl_final IS 'Final ECL (after floors), USD.';
COMMENT ON COLUMN v_ecl_by_stage.coverage IS 'Final ECL divided by balance.';
COMMENT ON COLUMN v_ecl_by_stage.balance_share IS 'Share of the date''s total balance in this stage.';

CREATE OR REPLACE VIEW v_ecl_by_grade AS
SELECT e.reporting_date, m.grade, e.stage,
       COUNT(*) AS loans, SUM(e.balance) AS balance, SUM(e.ecl_final) AS ecl_final,
       ROUND(SUM(e.ecl_final) / NULLIF(SUM(e.balance), 0), 6) AS coverage
  FROM ecl_result e
  JOIN loan_master m ON m.loan_id = e.loan_id
 GROUP BY e.reporting_date, m.grade, e.stage;

COMMENT ON TABLE v_ecl_by_grade IS 'Loans, balance, final ECL and coverage by reporting date, Lending Club grade and stage.';
COMMENT ON COLUMN v_ecl_by_grade.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN v_ecl_by_grade.grade IS 'Lending Club grade A-G.';
COMMENT ON COLUMN v_ecl_by_grade.stage IS 'IFRS 9 stage.';
COMMENT ON COLUMN v_ecl_by_grade.loans IS 'Number of loans.';
COMMENT ON COLUMN v_ecl_by_grade.balance IS 'Outstanding balance, USD.';
COMMENT ON COLUMN v_ecl_by_grade.ecl_final IS 'Final ECL (after floors), USD.';
COMMENT ON COLUMN v_ecl_by_grade.coverage IS 'Final ECL divided by balance.';

CREATE OR REPLACE VIEW v_ecl_by_state AS
SELECT e.reporting_date, m.addr_state, e.stage,
       COUNT(*) AS loans, SUM(e.balance) AS balance, SUM(e.ecl_final) AS ecl_final,
       ROUND(SUM(e.ecl_final) / NULLIF(SUM(e.balance), 0), 6) AS coverage
  FROM ecl_result e
  JOIN loan_master m ON m.loan_id = e.loan_id
 GROUP BY e.reporting_date, m.addr_state, e.stage;

COMMENT ON TABLE v_ecl_by_state IS 'Loans, balance, final ECL and coverage by reporting date, borrower state (the geography cut) and stage.';
COMMENT ON COLUMN v_ecl_by_state.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN v_ecl_by_state.addr_state IS 'Borrower US state.';
COMMENT ON COLUMN v_ecl_by_state.stage IS 'IFRS 9 stage.';
COMMENT ON COLUMN v_ecl_by_state.loans IS 'Number of loans.';
COMMENT ON COLUMN v_ecl_by_state.balance IS 'Outstanding balance, USD.';
COMMENT ON COLUMN v_ecl_by_state.ecl_final IS 'Final ECL (after floors), USD.';
COMMENT ON COLUMN v_ecl_by_state.coverage IS 'Final ECL divided by balance.';

-- Last month's stage against this month's, for every loan on either book.
-- NEW = not on last month's book; EXITED = not on this month's book.
CREATE OR REPLACE VIEW v_stage_migration AS
WITH dates AS (
  SELECT reporting_date, LAG(reporting_date) OVER (ORDER BY reporting_date) AS prev_date
    FROM (SELECT DISTINCT reporting_date FROM ecl_result)
),
moves AS (
  SELECT d.reporting_date, d.prev_date,
         NVL(TO_CHAR(p.stage), 'NEW') AS from_stage, TO_CHAR(c.stage) AS to_stage,
         p.balance AS balance_from, c.balance AS balance_to
    FROM dates d
    JOIN ecl_result c      ON c.reporting_date = d.reporting_date
    LEFT JOIN ecl_result p ON p.reporting_date = d.prev_date AND p.loan_id = c.loan_id
  UNION ALL
  SELECT d.reporting_date, d.prev_date, TO_CHAR(p.stage), 'EXITED', p.balance, NULL
    FROM dates d
    JOIN ecl_result p ON p.reporting_date = d.prev_date
   WHERE NOT EXISTS (SELECT 1 FROM ecl_result c
                      WHERE c.reporting_date = d.reporting_date AND c.loan_id = p.loan_id)
)
SELECT reporting_date, prev_date, from_stage, to_stage,
       COUNT(*) AS loans, SUM(balance_from) AS balance_from, SUM(balance_to) AS balance_to
  FROM moves
 GROUP BY reporting_date, prev_date, from_stage, to_stage;

COMMENT ON TABLE v_stage_migration IS 'Loans and balance moving from the previous reporting date''s stage to this one''s, including new (NEW) and exited (EXITED) loans.';
COMMENT ON COLUMN v_stage_migration.reporting_date IS 'Reporting date (the "to" month).';
COMMENT ON COLUMN v_stage_migration.prev_date IS 'Previous reporting date (the "from" month); null for the first month.';
COMMENT ON COLUMN v_stage_migration.from_stage IS 'Stage at the previous date: 1, 2, 3, or NEW.';
COMMENT ON COLUMN v_stage_migration.to_stage IS 'Stage at this date: 1, 2, 3, or EXITED.';
COMMENT ON COLUMN v_stage_migration.loans IS 'Number of loans that made this move.';
COMMENT ON COLUMN v_stage_migration.balance_from IS 'Their balance at the previous date, USD.';
COMMENT ON COLUMN v_stage_migration.balance_to IS 'Their balance at this date, USD.';

-- Opening to closing ECL by stage, the IFRS 7 way. Each loan contributes to
-- last month's stage (opening, then a transfer out or an exit) and to this
-- month's stage (a new loan, or a transfer in at its opening ECL plus the
-- remeasurement to its closing ECL). So opening + movements = closing by
-- construction, and DIFFERENCE must be 0.
CREATE OR REPLACE VIEW v_ecl_movement AS
WITH dates AS (
  SELECT reporting_date, LAG(reporting_date) OVER (ORDER BY reporting_date) AS prev_date
    FROM (SELECT DISTINCT reporting_date FROM ecl_result)
),
pairs AS (
  SELECT d.reporting_date, d.prev_date, p.stage AS p_stage, p.ecl_final AS p_ecl,
         c.stage AS c_stage, c.ecl_final AS c_ecl
    FROM dates d
    JOIN ecl_result c      ON c.reporting_date = d.reporting_date
    LEFT JOIN ecl_result p ON p.reporting_date = d.prev_date AND p.loan_id = c.loan_id
  UNION ALL
  SELECT d.reporting_date, d.prev_date, p.stage, p.ecl_final, NULL, NULL
    FROM dates d
    JOIN ecl_result p ON p.reporting_date = d.prev_date
   WHERE NOT EXISTS (SELECT 1 FROM ecl_result c
                      WHERE c.reporting_date = d.reporting_date AND c.loan_id = p.loan_id)
),
parts AS (
  SELECT reporting_date, prev_date, p_stage AS stage,
         p_ecl AS opening, 0 AS new_loans, 0 AS transfers_in,
         CASE WHEN c_stage IS NOT NULL AND c_stage <> p_stage THEN -p_ecl ELSE 0 END AS transfers_out,
         CASE WHEN c_stage IS NULL THEN -p_ecl ELSE 0 END AS exits,
         0 AS remeasurement, 0 AS closing
    FROM pairs WHERE p_stage IS NOT NULL
  UNION ALL
  SELECT reporting_date, prev_date, c_stage,
         0,
         CASE WHEN p_stage IS NULL THEN c_ecl ELSE 0 END,
         CASE WHEN p_stage IS NOT NULL AND p_stage <> c_stage THEN p_ecl ELSE 0 END,
         0, 0,
         CASE WHEN p_stage IS NOT NULL THEN c_ecl - p_ecl ELSE 0 END,
         c_ecl
    FROM pairs WHERE c_stage IS NOT NULL
)
SELECT reporting_date, prev_date, stage,
       SUM(opening) AS opening_ecl, SUM(new_loans) AS new_loans, SUM(transfers_in) AS transfers_in,
       SUM(transfers_out) AS transfers_out, SUM(exits) AS exits, SUM(remeasurement) AS remeasurement,
       SUM(closing) AS closing_ecl,
       SUM(opening) + SUM(new_loans) + SUM(transfers_in) + SUM(transfers_out) + SUM(exits)
         + SUM(remeasurement) - SUM(closing) AS difference
  FROM parts
 GROUP BY reporting_date, prev_date, stage;

COMMENT ON TABLE v_ecl_movement IS 'Opening to closing ECL by stage between consecutive reporting dates: new loans, transfers in and out, exits and remeasurement. DIFFERENCE must be 0.';
COMMENT ON COLUMN v_ecl_movement.reporting_date IS 'Reporting date (closing).';
COMMENT ON COLUMN v_ecl_movement.prev_date IS 'Previous reporting date (opening); null for the first month.';
COMMENT ON COLUMN v_ecl_movement.stage IS 'IFRS 9 stage.';
COMMENT ON COLUMN v_ecl_movement.opening_ecl IS 'Final ECL at the previous date of loans then in this stage, USD.';
COMMENT ON COLUMN v_ecl_movement.new_loans IS 'Closing ECL of loans not on the previous book, USD.';
COMMENT ON COLUMN v_ecl_movement.transfers_in IS 'Opening ECL of loans that moved into this stage, USD.';
COMMENT ON COLUMN v_ecl_movement.transfers_out IS 'Opening ECL of loans that moved out of this stage (negative), USD.';
COMMENT ON COLUMN v_ecl_movement.exits IS 'Opening ECL of loans that left the book (negative), USD.';
COMMENT ON COLUMN v_ecl_movement.remeasurement IS 'Change in ECL of loans on both books, booked in their closing stage, USD.';
COMMENT ON COLUMN v_ecl_movement.closing_ecl IS 'Final ECL at this date of loans now in this stage, USD.';
COMMENT ON COLUMN v_ecl_movement.difference IS 'Opening + all movements - closing; 0 when the movement reconciles.';

CREATE OR REPLACE VIEW v_floor_impact AS
SELECT reporting_date, stage,
       COUNT(*)                                             AS loans,
       SUM(CASE WHEN floor_applied = 'Y' THEN 1 ELSE 0 END) AS loans_floored,
       SUM(ecl_weighted)                                    AS model_ecl,
       SUM(ecl_final)                                       AS final_ecl,
       SUM(ecl_final - ecl_weighted)                        AS ecl_added_by_floors
  FROM ecl_result
 GROUP BY reporting_date, stage;

COMMENT ON TABLE v_floor_impact IS 'How much the RBI floors add: loans floored and ECL added by floors, by reporting date and stage.';
COMMENT ON COLUMN v_floor_impact.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN v_floor_impact.stage IS 'IFRS 9 stage.';
COMMENT ON COLUMN v_floor_impact.loans IS 'Number of loans.';
COMMENT ON COLUMN v_floor_impact.loans_floored IS 'Loans whose final ECL was set by the floor.';
COMMENT ON COLUMN v_floor_impact.model_ecl IS 'Probability-weighted model ECL before floors, USD.';
COMMENT ON COLUMN v_floor_impact.final_ecl IS 'Final ECL after floors, USD.';
COMMENT ON COLUMN v_floor_impact.ecl_added_by_floors IS 'Final minus model ECL: what the floors added, USD.';

CREATE OR REPLACE VIEW v_scenario_sensitivity AS
SELECT reporting_date,
       COUNT(*)          AS loans,
       SUM(ecl_base)     AS ecl_base,
       SUM(ecl_downside) AS ecl_downside,
       SUM(ecl_severe)   AS ecl_severe,
       SUM(ecl_weighted) AS ecl_weighted,
       SUM(ecl_final)    AS ecl_final
  FROM ecl_result
 GROUP BY reporting_date;

COMMENT ON TABLE v_scenario_sensitivity IS 'Total model ECL under each scenario, the probability-weighted ECL and the final ECL after floors, by reporting date.';
COMMENT ON COLUMN v_scenario_sensitivity.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN v_scenario_sensitivity.loans IS 'Number of loans.';
COMMENT ON COLUMN v_scenario_sensitivity.ecl_base IS 'Total model ECL under the BASE scenario, USD.';
COMMENT ON COLUMN v_scenario_sensitivity.ecl_downside IS 'Total model ECL under the DOWNSIDE scenario, USD.';
COMMENT ON COLUMN v_scenario_sensitivity.ecl_severe IS 'Total model ECL under the SEVERE scenario, USD.';
COMMENT ON COLUMN v_scenario_sensitivity.ecl_weighted IS 'Total probability-weighted model ECL, USD.';
COMMENT ON COLUMN v_scenario_sensitivity.ecl_final IS 'Total final ECL after floors, USD.';

CREATE OR REPLACE VIEW v_dq_summary AS
SELECT e.reporting_date, e.rule_id, r.rule_name, e.severity,
       COUNT(*) AS errors,
       s.rows_received,
       ROUND(COUNT(*) / s.rows_received, 6) AS share_of_rows
  FROM dq_error e
  JOIN dq_rule r ON r.rule_id = e.rule_id
  JOIN (SELECT reporting_date, COUNT(*) AS rows_received
          FROM stg_loan_snapshot GROUP BY reporting_date) s
    ON s.reporting_date = e.reporting_date
 GROUP BY e.reporting_date, e.rule_id, r.rule_name, e.severity, s.rows_received;

COMMENT ON TABLE v_dq_summary IS 'Data quality errors by rule and severity per reporting date. The first place to look when the reject share stops a batch.';
COMMENT ON COLUMN v_dq_summary.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN v_dq_summary.rule_id IS 'Data quality rule.';
COMMENT ON COLUMN v_dq_summary.rule_name IS 'Short name of the rule.';
COMMENT ON COLUMN v_dq_summary.severity IS 'REJECT or WARN.';
COMMENT ON COLUMN v_dq_summary.errors IS 'Rows that failed the rule.';
COMMENT ON COLUMN v_dq_summary.rows_received IS 'Rows staged for the date.';
COMMENT ON COLUMN v_dq_summary.share_of_rows IS 'Errors divided by rows received.';
