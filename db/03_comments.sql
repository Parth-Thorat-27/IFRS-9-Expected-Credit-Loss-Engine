-- 03_comments.sql: a comment on every table and column.
-- docs/data_dictionary.md is generated from these, so they are written for a
-- reader who has never seen the code.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

------------------------------------------------------------------ LOAN_MASTER
COMMENT ON TABLE loan_master IS 'Application data for every loan in the live book, one row per loan, plus its origination 12-month PD. Loaded once from data/processed/portfolio_base.csv by PKG_LOAD.load_history.';
COMMENT ON COLUMN loan_master.loan_id IS 'Lending Club loan id.';
COMMENT ON COLUMN loan_master.issue_d IS 'Month the loan was issued (first day of that month).';
COMMENT ON COLUMN loan_master.term_months IS 'Contractual term in months: 36 or 60.';
COMMENT ON COLUMN loan_master.loan_amnt IS 'Amount the borrower applied for, USD.';
COMMENT ON COLUMN loan_master.funded_amnt IS 'Amount funded at origination, USD. Data quality rule DQ006 rejects a monthly balance above this.';
COMMENT ON COLUMN loan_master.int_rate IS 'Annual contract interest rate as a fraction (0.1399 = 13.99%). Also used as the effective interest rate for discounting.';
COMMENT ON COLUMN loan_master.installment IS 'Monthly instalment at origination, USD.';
COMMENT ON COLUMN loan_master.grade IS 'Lending Club credit grade, A (best) to G. LGD is calibrated by grade.';
COMMENT ON COLUMN loan_master.sub_grade IS 'Lending Club sub-grade, A1 to G5. Reporting only, not a model input.';
COMMENT ON COLUMN loan_master.emp_length IS 'Years in employment at application, 0 to 10 (10 means 10 or more). Null when not given.';
COMMENT ON COLUMN loan_master.home_ownership IS 'Home ownership at application: RENT, MORTGAGE, OWN, OTHER, NONE or ANY.';
COMMENT ON COLUMN loan_master.annual_inc IS 'Self-reported annual income at application, USD.';
COMMENT ON COLUMN loan_master.verification_status IS 'Whether income was verified: Verified, Source Verified or Not Verified.';
COMMENT ON COLUMN loan_master.purpose IS 'Loan purpose stated by the borrower, e.g. debt_consolidation.';
COMMENT ON COLUMN loan_master.addr_state IS 'Borrower US state (two letters). The geography cut in V_ECL_BY_STATE.';
COMMENT ON COLUMN loan_master.dti IS 'Debt-to-income ratio at application, in percent.';
COMMENT ON COLUMN loan_master.delinq_2yrs IS 'Delinquencies of 30+ days in the two years before application.';
COMMENT ON COLUMN loan_master.earliest_cr_line IS 'Month the borrower''s earliest credit line was opened. Credit history length = issue_d minus this.';
COMMENT ON COLUMN loan_master.fico_range_low IS 'Lower bound of the FICO range at origination.';
COMMENT ON COLUMN loan_master.fico_range_high IS 'Upper bound of the FICO range at origination. Origination FICO = midpoint of the range.';
COMMENT ON COLUMN loan_master.inq_last_6mths IS 'Credit inquiries in the six months before application.';
COMMENT ON COLUMN loan_master.open_acc IS 'Open credit lines at application.';
COMMENT ON COLUMN loan_master.pub_rec IS 'Derogatory public records at application.';
COMMENT ON COLUMN loan_master.revol_bal IS 'Total revolving credit balance at application, USD.';
COMMENT ON COLUMN loan_master.revol_util IS 'Revolving credit utilisation at application as a fraction (0.297 = 29.7%).';
COMMENT ON COLUMN loan_master.total_acc IS 'Credit lines ever opened, at application.';
COMMENT ON COLUMN loan_master.mort_acc IS 'Mortgage accounts at application.';
COMMENT ON COLUMN loan_master.pub_rec_bankruptcies IS 'Public-record bankruptcies at application.';
COMMENT ON COLUMN loan_master.application_type IS 'Individual or Joint App.';
COMMENT ON COLUMN loan_master.pd_12m_orig IS '12-month PD scored with application data as at origination, after the PD floor. The baseline for the PD-deterioration staging test.';
COMMENT ON COLUMN loan_master.pd_model_version IS 'MODEL_REGISTRY version that produced pd_12m_orig.';
COMMENT ON COLUMN loan_master.loaded_ts IS 'When the row was loaded.';

------------------------------------------------------------------ LOAN_DEV
COMMENT ON TABLE loan_dev IS 'Closed loans from matured vintages, used to train the PD model and calibrate LGD. Loaded from data/processed/loans_dev.csv by PKG_LOAD.load_history.';
COMMENT ON COLUMN loan_dev.loan_status IS 'Final Lending Club status: Fully Paid, Charged Off, or one of the two "Does not meet the credit policy" variants.';
COMMENT ON COLUMN loan_dev.default_flag IS 'Model target: 1 = charged off, 0 = fully paid.';
COMMENT ON COLUMN loan_dev.total_rec_prncp IS 'Principal repaid before the loan closed, USD. Used only to calibrate LGD; never a model input (leakage).';
COMMENT ON COLUMN loan_dev.recoveries IS 'Amount recovered after charge-off, USD. LGD calibration only.';
COMMENT ON COLUMN loan_dev.collection_recovery_fee IS 'Collection fee paid out of recoveries, USD. LGD calibration only.';

-- The application columns mean the same thing in both loan tables, so their
-- comments are copied from LOAN_MASTER rather than written twice.
BEGIN
  FOR c IN (SELECT m.column_name, m.comments
              FROM user_col_comments m
              JOIN user_tab_columns d ON d.table_name = 'LOAN_DEV' AND d.column_name = m.column_name
             WHERE m.table_name = 'LOAN_MASTER'
               AND m.column_name NOT IN ('PD_12M_ORIG', 'PD_MODEL_VERSION')) LOOP
    EXECUTE IMMEDIATE 'COMMENT ON COLUMN loan_dev.' || c.column_name
                   || ' IS ' || DBMS_ASSERT.ENQUOTE_LITERAL(REPLACE(c.comments, '''', ''''''));
  END LOOP;
END;
/

------------------------------------------------------------------ staging
COMMENT ON TABLE stg_loan_snapshot IS 'Monthly snapshot rows exactly as received (all text), one row per line of the file, before any checks. PKG_DQ checks these rows; PKG_LOAD.load_clean moves the good ones to LOAN_SNAPSHOT.';
COMMENT ON COLUMN stg_loan_snapshot.reporting_date IS 'Reporting date of the batch that loaded the file.';
COMMENT ON COLUMN stg_loan_snapshot.row_num IS 'Position of the row in the file: 1 = first data line after the header.';
COMMENT ON COLUMN stg_loan_snapshot.run_id IS 'BATCH_RUN.run_id of the load.';
COMMENT ON COLUMN stg_loan_snapshot.raw_reporting_date IS 'reporting_date field as written in the file. DQ010 compares it with the batch date.';
COMMENT ON COLUMN stg_loan_snapshot.loan_id IS 'loan_id as received.';
COMMENT ON COLUMN stg_loan_snapshot.loan_status IS 'Lending Club status as received.';
COMMENT ON COLUMN stg_loan_snapshot.dpd IS 'Days past due as received.';
COMMENT ON COLUMN stg_loan_snapshot.balance IS 'Outstanding principal as received, USD.';
COMMENT ON COLUMN stg_loan_snapshot.current_fico IS 'Current FICO score as received.';
COMMENT ON COLUMN stg_loan_snapshot.forbearance_flag IS 'Forbearance (hardship plan) flag as received.';
COMMENT ON COLUMN stg_loan_snapshot.remaining_months IS 'Remaining contractual term in months as received.';
COMMENT ON COLUMN stg_loan_snapshot.data_source IS 'LC_ACTUAL (real Lending Club data) or SIMULATED, as received.';
COMMENT ON COLUMN stg_loan_snapshot.loaded_ts IS 'When the row was staged.';

COMMENT ON TABLE stg_control IS 'Control totals from the control file that arrives with each snapshot: what the sender says the snapshot holds. PKG_DQ.reconcile_control checks the staged rows against them.';
COMMENT ON COLUMN stg_control.reporting_date IS 'Reporting date of the batch that loaded the file.';
COMMENT ON COLUMN stg_control.run_id IS 'BATCH_RUN.run_id of the load.';
COMMENT ON COLUMN stg_control.control_file IS 'Name of the control file the totals came from.';
COMMENT ON COLUMN stg_control.expected_rows IS 'Number of data rows the snapshot file should contain.';
COMMENT ON COLUMN stg_control.expected_balance IS 'Total outstanding principal the snapshot file should contain, USD.';
COMMENT ON COLUMN stg_control.loaded_ts IS 'When the totals were staged.';

------------------------------------------------------------------ data quality
COMMENT ON TABLE dq_rule IS 'Data quality rules as metadata. PKG_DQ.run_checks runs every active rule against the day''s staged rows with dynamic SQL; adding a rule needs no code change.';
COMMENT ON COLUMN dq_rule.rule_id IS 'Rule code, e.g. DQ001.';
COMMENT ON COLUMN dq_rule.rule_name IS 'Short name of the rule.';
COMMENT ON COLUMN dq_rule.severity IS 'REJECT: the row is kept out of LOAN_SNAPSHOT. WARN: the row is loaded with the documented fix.';
COMMENT ON COLUMN dq_rule.column_name IS 'Staging column the rule checks. Its value is copied to DQ_ERROR.bad_value.';
COMMENT ON COLUMN dq_rule.predicate IS 'SQL condition on STG_LOAN_SNAPSHOT (alias s) that is true for a bad row.';
COMMENT ON COLUMN dq_rule.message IS 'Explanation written to DQ_ERROR for every row that fails the rule.';
COMMENT ON COLUMN dq_rule.active_flag IS 'Y = the rule runs; N = switched off.';

COMMENT ON TABLE dq_error IS 'One row per failed check: which staged row, which rule, the offending value and why.';
COMMENT ON COLUMN dq_error.error_id IS 'Surrogate key (identity).';
COMMENT ON COLUMN dq_error.reporting_date IS 'Reporting date of the checked batch.';
COMMENT ON COLUMN dq_error.run_id IS 'BATCH_RUN.run_id of the check.';
COMMENT ON COLUMN dq_error.rule_id IS 'Rule that failed (DQ_RULE).';
COMMENT ON COLUMN dq_error.severity IS 'Rule severity at the time of the check: REJECT or WARN.';
COMMENT ON COLUMN dq_error.row_num IS 'STG_LOAN_SNAPSHOT.row_num of the failing row.';
COMMENT ON COLUMN dq_error.loan_id IS 'loan_id of the failing row as received (may be blank or invalid).';
COMMENT ON COLUMN dq_error.column_name IS 'Column the rule checks.';
COMMENT ON COLUMN dq_error.bad_value IS 'Value of that column in the failing row, as received.';
COMMENT ON COLUMN dq_error.message IS 'Why the row failed.';
COMMENT ON COLUMN dq_error.created_ts IS 'When the error was recorded.';

------------------------------------------------------------------ LOAN_SNAPSHOT
COMMENT ON TABLE loan_snapshot IS 'Clean, typed monthly loan data: only staged rows with no REJECT error. One row per loan per reporting date.';
COMMENT ON COLUMN loan_snapshot.reporting_date IS 'Month-end the snapshot describes.';
COMMENT ON COLUMN loan_snapshot.loan_id IS 'Loan (LOAN_MASTER).';
COMMENT ON COLUMN loan_snapshot.loan_status IS 'Lending Club status at the reporting date. Default forces Stage 3.';
COMMENT ON COLUMN loan_snapshot.dpd IS 'Days past due at the reporting date.';
COMMENT ON COLUMN loan_snapshot.balance IS 'Outstanding principal at the reporting date, USD. The exposure for ECL.';
COMMENT ON COLUMN loan_snapshot.current_fico IS 'Current FICO score. Null when DQ008 flagged the received value; scoring then uses the origination FICO.';
COMMENT ON COLUMN loan_snapshot.forbearance_flag IS 'Y = the loan is in a hardship (forbearance) plan. Values failing DQ009 are loaded as N.';
COMMENT ON COLUMN loan_snapshot.remaining_months IS 'Remaining contractual term in months.';
COMMENT ON COLUMN loan_snapshot.data_source IS 'LC_ACTUAL for the real base month, SIMULATED for generated months.';
COMMENT ON COLUMN loan_snapshot.source_row_num IS 'STG_LOAN_SNAPSHOT.row_num (line in the file) the row came from: lineage back to the raw data.';
COMMENT ON COLUMN loan_snapshot.run_id IS 'BATCH_RUN.run_id that loaded the row.';
COMMENT ON COLUMN loan_snapshot.loaded_ts IS 'When the row was loaded.';

------------------------------------------------------------------ PD_SCORE
COMMENT ON TABLE pd_score IS 'Monthly PD scores per loan from the Python PD model: origination and current 12-month PD.';
COMMENT ON COLUMN pd_score.reporting_date IS 'Reporting date scored.';
COMMENT ON COLUMN pd_score.loan_id IS 'Loan scored.';
COMMENT ON COLUMN pd_score.pd_12m_orig IS '12-month PD at origination, copied from LOAN_MASTER.';
COMMENT ON COLUMN pd_score.pd_12m_current IS '12-month PD from the same model with the current FICO in place of the origination FICO, after the PD floor.';
COMMENT ON COLUMN pd_score.fico_used IS 'FICO value fed to the model for pd_12m_current.';
COMMENT ON COLUMN pd_score.fico_source IS 'CURRENT, or ORIGINATION when the current FICO failed DQ008.';
COMMENT ON COLUMN pd_score.model_version IS 'MODEL_REGISTRY version used.';
COMMENT ON COLUMN pd_score.run_id IS 'BATCH_RUN.run_id of the scoring step.';
COMMENT ON COLUMN pd_score.scored_ts IS 'When the score was written.';

------------------------------------------------------------------ stages
COMMENT ON TABLE loan_stage_history IS 'Stage decision per loan per reporting date, with the cure counter and stage dates. Each month''s assessment starts from the previous month''s row here, which makes re-running a month repeatable.';
COMMENT ON COLUMN loan_stage_history.reporting_date IS 'Reporting date assessed.';
COMMENT ON COLUMN loan_stage_history.loan_id IS 'Loan assessed.';
COMMENT ON COLUMN loan_stage_history.stage IS 'IFRS 9 stage: 1 performing, 2 significant increase in credit risk, 3 credit-impaired.';
COMMENT ON COLUMN loan_stage_history.reason_code IS 'Why: DPD_90, DEFAULT_STATUS, DPD_30, FORBEARANCE, PD_DETERIORATION, CURE_PROBATION or PERFORMING.';
COMMENT ON COLUMN loan_stage_history.prev_stage IS 'Stage at the loan''s previous assessment; null in its first month.';
COMMENT ON COLUMN loan_stage_history.cure_months IS 'Consecutive months meeting Stage 1 conditions while still held in Stage 2 by the cure rule.';
COMMENT ON COLUMN loan_stage_history.stage_since IS 'Reporting date the loan entered its current stage.';
COMMENT ON COLUMN loan_stage_history.stage3_since IS 'Date the loan entered Stage 3, backdated by DPD beyond 90 days when known. Null unless in Stage 3. Drives the Stage 3 floor.';
COMMENT ON COLUMN loan_stage_history.run_id IS 'BATCH_RUN.run_id of the assessment.';
COMMENT ON COLUMN loan_stage_history.assessed_ts IS 'When the assessment was written.';

COMMENT ON TABLE loan_stage_current IS 'Latest stage per loan. Updating its stage column fires TRG_STAGE_CHANGE_AUDIT. Loans that leave the book are marked exited, not deleted.';
COMMENT ON COLUMN loan_stage_current.loan_id IS 'Loan.';
COMMENT ON COLUMN loan_stage_current.reporting_date IS 'Reporting date of the latest assessment.';
COMMENT ON COLUMN loan_stage_current.stage IS 'Current IFRS 9 stage (1, 2 or 3).';
COMMENT ON COLUMN loan_stage_current.reason_code IS 'Reason for the current stage.';
COMMENT ON COLUMN loan_stage_current.cure_months IS 'Consecutive months meeting Stage 1 conditions while held in Stage 2 by the cure rule.';
COMMENT ON COLUMN loan_stage_current.stage_since IS 'Reporting date the loan entered its current stage.';
COMMENT ON COLUMN loan_stage_current.stage3_since IS 'Date the loan entered Stage 3; null unless in Stage 3.';
COMMENT ON COLUMN loan_stage_current.exited_flag IS 'Y = the loan was not in the latest clean snapshot (paid off, written off or rejected that month).';
COMMENT ON COLUMN loan_stage_current.exited_date IS 'Reporting date the loan was first missing from the book.';
COMMENT ON COLUMN loan_stage_current.updated_ts IS 'When the row last changed.';

COMMENT ON TABLE stage_change_audit IS 'Every change of a loan''s stage, written by trigger TRG_STAGE_CHANGE_AUDIT. Append-only.';
COMMENT ON COLUMN stage_change_audit.audit_id IS 'Surrogate key (identity).';
COMMENT ON COLUMN stage_change_audit.loan_id IS 'Loan whose stage changed.';
COMMENT ON COLUMN stage_change_audit.reporting_date IS 'Reporting date of the assessment that changed the stage.';
COMMENT ON COLUMN stage_change_audit.old_stage IS 'Stage before the change.';
COMMENT ON COLUMN stage_change_audit.new_stage IS 'Stage after the change.';
COMMENT ON COLUMN stage_change_audit.old_reason IS 'Reason code before the change.';
COMMENT ON COLUMN stage_change_audit.new_reason IS 'Reason code after the change.';
COMMENT ON COLUMN stage_change_audit.changed_by IS 'Database session user that made the change.';
COMMENT ON COLUMN stage_change_audit.changed_ts IS 'When the change was made.';

------------------------------------------------------------------ ECL_RESULT
COMMENT ON TABLE ecl_result IS 'ECL per loan per reporting date from the set-based engine (PKG_ECL.run_v2): inputs, ECL per scenario, weighted model ECL, RBI floor and final ECL.';
COMMENT ON COLUMN ecl_result.reporting_date IS 'Reporting date.';
COMMENT ON COLUMN ecl_result.loan_id IS 'Loan.';
COMMENT ON COLUMN ecl_result.stage IS 'IFRS 9 stage used for measurement.';
COMMENT ON COLUMN ecl_result.reason_code IS 'Staging reason code.';
COMMENT ON COLUMN ecl_result.balance IS 'Outstanding principal at the reporting date (exposure today), USD.';
COMMENT ON COLUMN ecl_result.int_rate IS 'Annual contract rate used to rebuild the payment schedule and to discount.';
COMMENT ON COLUMN ecl_result.remaining_months IS 'Remaining contractual term n.';
COMMENT ON COLUMN ecl_result.horizon_months IS 'Months of loss counted: min(12, n) for Stage 1, n for Stage 2, 0 for Stage 3 (no schedule).';
COMMENT ON COLUMN ecl_result.dpd IS 'Days past due; selects the DPD multiplier.';
COMMENT ON COLUMN ecl_result.restructured_flag IS 'Forbearance flag used to choose the restructured floor.';
COMMENT ON COLUMN ecl_result.months_in_stage3 IS 'Whole months since stage3_since; selects the Stage 3 floor. Null outside Stage 3.';
COMMENT ON COLUMN ecl_result.lgd IS 'Loss given default from PARAM_LGD for the loan''s grade.';
COMMENT ON COLUMN ecl_result.pd_12m IS 'Measurement 12-month PD before scenario multipliers: current PD x DPD multiplier, capped at PD_CAP; 1 for Stage 3.';
COMMENT ON COLUMN ecl_result.ecl_base IS 'Model ECL under the BASE scenario, USD.';
COMMENT ON COLUMN ecl_result.ecl_downside IS 'Model ECL under the DOWNSIDE scenario, USD.';
COMMENT ON COLUMN ecl_result.ecl_severe IS 'Model ECL under the SEVERE scenario, USD.';
COMMENT ON COLUMN ecl_result.ecl_weighted IS 'Probability-weighted model ECL across the scenarios, before floors, USD.';
COMMENT ON COLUMN ecl_result.floor_rate IS 'RBI floor rate that applies to the loan (share of balance).';
COMMENT ON COLUMN ecl_result.floor_amount IS 'floor_rate x balance, USD.';
COMMENT ON COLUMN ecl_result.ecl_final IS 'Provision booked: the larger of ecl_weighted and floor_amount, USD.';
COMMENT ON COLUMN ecl_result.floor_applied IS 'Y when the floor was higher than the model ECL, so the floor set ecl_final.';
COMMENT ON COLUMN ecl_result.run_id IS 'BATCH_RUN.run_id of the calculation.';
COMMENT ON COLUMN ecl_result.calc_ts IS 'When the row was calculated.';

COMMENT ON TABLE ecl_result_v1 IS 'Same shape as ECL_RESULT, written only by the deliberately row-by-row benchmark PKG_ECL.run_v1. Used to prove v1 and v2 agree to the cent and to time them.';
-- Same columns, same meaning: copy the comments from ECL_RESULT.
BEGIN
  FOR c IN (SELECT column_name, comments FROM user_col_comments WHERE table_name = 'ECL_RESULT') LOOP
    EXECUTE IMMEDIATE 'COMMENT ON COLUMN ecl_result_v1.' || c.column_name
                   || ' IS ' || DBMS_ASSERT.ENQUOTE_LITERAL(REPLACE(c.comments, '''', ''''''));
  END LOOP;
END;
/

COMMENT ON TABLE month_idx IS 'Month numbers 1 to 60. PKG_ECL.run_v2 joins each loan to the months of its horizon to lay out the monthly losses as rows.';
COMMENT ON COLUMN month_idx.t IS 'Month number t in the ECL sum (1 = the first month after the reporting date).';

------------------------------------------------------------------ parameters
COMMENT ON TABLE param_setting IS 'Single-value business settings (staging thresholds, PD floor and cap, LGD and DQ limits) loaded from config/ecl_parameters.xml by PKG_PARAMS.';
COMMENT ON COLUMN param_setting.setting_name IS 'Setting name, e.g. STAGE2_DPD.';
COMMENT ON COLUMN param_setting.setting_value IS 'Numeric value.';
COMMENT ON COLUMN param_setting.description IS 'What the setting controls, from the XML.';
COMMENT ON COLUMN param_setting.source_file IS 'Config file the value was loaded from.';
COMMENT ON COLUMN param_setting.loaded_ts IS 'When the value was last loaded.';

COMMENT ON TABLE param_scenario IS 'Economic scenarios: probability weight and PD multiplier. Weights must sum to 1.';
COMMENT ON COLUMN param_scenario.scenario_code IS 'BASE, DOWNSIDE or SEVERE.';
COMMENT ON COLUMN param_scenario.weight IS 'Probability weight of the scenario.';
COMMENT ON COLUMN param_scenario.pd_multiplier IS 'Factor applied to the 12-month PD in this scenario (result capped at PD_CAP).';
COMMENT ON COLUMN param_scenario.loaded_ts IS 'When the row was last loaded.';

COMMENT ON TABLE param_dpd_multiplier IS 'PD multiplier by days-past-due band. Affects measurement only; delinquency already drives staging.';
COMMENT ON COLUMN param_dpd_multiplier.from_dpd IS 'First DPD in the band (inclusive).';
COMMENT ON COLUMN param_dpd_multiplier.to_dpd IS 'Last DPD in the band (inclusive).';
COMMENT ON COLUMN param_dpd_multiplier.multiplier IS 'Factor applied to pd_12m_current for loans in the band.';
COMMENT ON COLUMN param_dpd_multiplier.loaded_ts IS 'When the row was last loaded.';

COMMENT ON TABLE param_floor IS 'RBI minimum provision floors as a share of balance, by stage, restructured status and time in Stage 3.';
COMMENT ON COLUMN param_floor.stage IS 'Stage the floor applies to.';
COMMENT ON COLUMN param_floor.restructured_flag IS 'Y = loans in forbearance (restructured), N = others, * = any (Stage 3 rows).';
COMMENT ON COLUMN param_floor.months_in_stage3_from IS 'Start of the time-in-Stage-3 band in months (inclusive); 0 for Stages 1 and 2.';
COMMENT ON COLUMN param_floor.months_in_stage3_to IS 'End of the time-in-Stage-3 band in months (exclusive); null = no upper limit.';
COMMENT ON COLUMN param_floor.floor_rate IS 'Minimum ECL as a share of balance.';
COMMENT ON COLUMN param_floor.source IS 'Where the rates come from (as stated in the XML).';
COMMENT ON COLUMN param_floor.loaded_ts IS 'When the row was last loaded.';

COMMENT ON TABLE param_lgd IS 'LGD by grade, calibrated by PKG_LGD.calibrate from charged-off loans in LOAN_DEV. Row ALL holds the portfolio average.';
COMMENT ON COLUMN param_lgd.grade IS 'Grade A to G, or ALL for the portfolio average.';
COMMENT ON COLUMN param_lgd.lgd IS 'LGD the engine uses for the grade.';
COMMENT ON COLUMN param_lgd.grade_lgd IS 'The grade''s own exposure-weighted LGD, kept even when the fallback is used.';
COMMENT ON COLUMN param_lgd.defaults_count IS 'Charged-off loans behind the estimate.';
COMMENT ON COLUMN param_lgd.ead_total IS 'Exposure at default summed over those loans, USD (the weights).';
COMMENT ON COLUMN param_lgd.fallback_flag IS 'Y = fewer defaults than LGD_MIN_DEFAULTS, so lgd is the portfolio average.';
COMMENT ON COLUMN param_lgd.calibrated_ts IS 'When the calibration ran.';

COMMENT ON TABLE param_audit IS 'Every change to a parameter table, one row per changed value, written by the parameter audit triggers.';
COMMENT ON COLUMN param_audit.audit_id IS 'Surrogate key (identity).';
COMMENT ON COLUMN param_audit.table_name IS 'Parameter table that changed.';
COMMENT ON COLUMN param_audit.param_key IS 'Key of the changed row, e.g. DOWNSIDE or STAGE2_DPD.';
COMMENT ON COLUMN param_audit.column_name IS 'Column whose value changed.';
COMMENT ON COLUMN param_audit.action IS 'INSERT, UPDATE or DELETE.';
COMMENT ON COLUMN param_audit.old_value IS 'Value before the change (null for INSERT).';
COMMENT ON COLUMN param_audit.new_value IS 'Value after the change (null for DELETE).';
COMMENT ON COLUMN param_audit.changed_by IS 'Database session user that made the change.';
COMMENT ON COLUMN param_audit.changed_ts IS 'When the change was made.';

------------------------------------------------------------------ model and batch
COMMENT ON TABLE model_registry IS 'Each trained PD model: data periods, out-of-time test metrics, features and saved artifact.';
COMMENT ON COLUMN model_registry.model_version IS 'Model version, e.g. PD_LR_20261013_1.';
COMMENT ON COLUMN model_registry.algorithm IS 'Model type and key settings.';
COMMENT ON COLUMN model_registry.train_from IS 'First issue month in the training data.';
COMMENT ON COLUMN model_registry.train_to IS 'Last issue month in the training data.';
COMMENT ON COLUMN model_registry.test_from IS 'First issue month in the out-of-time test data.';
COMMENT ON COLUMN model_registry.test_to IS 'Last issue month in the out-of-time test data.';
COMMENT ON COLUMN model_registry.train_rows IS 'Training loans.';
COMMENT ON COLUMN model_registry.test_rows IS 'Test loans.';
COMMENT ON COLUMN model_registry.train_default_rate IS 'Observed default rate in training.';
COMMENT ON COLUMN model_registry.test_default_rate IS 'Observed default rate in the test set.';
COMMENT ON COLUMN model_registry.test_mean_pd IS 'Mean predicted term PD on the test set (compare with test_default_rate for calibration).';
COMMENT ON COLUMN model_registry.auc_train IS 'Area under the ROC curve on the training data.';
COMMENT ON COLUMN model_registry.auc_test IS 'Area under the ROC curve on the out-of-time test data.';
COMMENT ON COLUMN model_registry.gini_test IS 'Gini on the test data = 2 x AUC - 1.';
COMMENT ON COLUMN model_registry.ks_test IS 'Kolmogorov-Smirnov statistic on the test data: largest gap between the score distributions of defaulters and non-defaulters.';
COMMENT ON COLUMN model_registry.brier_test IS 'Brier score on the test data: mean squared error of the predicted PDs (lower is better).';
COMMENT ON COLUMN model_registry.features IS 'JSON list of model input features.';
COMMENT ON COLUMN model_registry.artifact_file IS 'Saved model file under models/ (git-ignored; rebuilt by train_pd_model.py).';
COMMENT ON COLUMN model_registry.active_flag IS 'Y = the model scoring uses; only one model is active.';
COMMENT ON COLUMN model_registry.trained_ts IS 'When the model was trained.';

COMMENT ON TABLE batch_run IS 'One row per batch step: status, timings, row counts and message. Written through PKG_BATCH_LOG with autonomous transactions, so failed steps keep their row.';
COMMENT ON COLUMN batch_run.batch_run_id IS 'Surrogate key (identity).';
COMMENT ON COLUMN batch_run.run_id IS 'Groups the steps of one batch run (from BATCH_RUN_ID_SEQ).';
COMMENT ON COLUMN batch_run.reporting_date IS 'Reporting date the step ran for (null for one-off steps).';
COMMENT ON COLUMN batch_run.step_name IS 'Step name, e.g. LOAD_SNAPSHOT.';
COMMENT ON COLUMN batch_run.status IS 'RUNNING, SUCCESS or FAILED.';
COMMENT ON COLUMN batch_run.started_ts IS 'When the step started.';
COMMENT ON COLUMN batch_run.ended_ts IS 'When the step finished.';
COMMENT ON COLUMN batch_run.elapsed_seconds IS 'Run time of the step in seconds.';
COMMENT ON COLUMN batch_run.rows_processed IS 'Rows the step wrote or checked.';
COMMENT ON COLUMN batch_run.message IS 'Result summary, or the error stack when the step failed.';
COMMENT ON COLUMN batch_run.db_user IS 'Database user that ran the step.';

COMMENT ON TABLE ext_table_doc IS 'Descriptions of the external tables and their columns. Oracle rejects COMMENT ON for external tables (ORA-30657), so they live here and V_DATA_DICTIONARY merges them with the normal comments.';
COMMENT ON COLUMN ext_table_doc.table_name IS 'External table described.';
COMMENT ON COLUMN ext_table_doc.column_name IS 'Column described, or (table) for the description of the table itself.';
COMMENT ON COLUMN ext_table_doc.comments IS 'The description.';
