-- 02_constraints_indexes.sql: keys, foreign keys, checks and indexes.
-- Check constraints make bad data impossible to store, not just unlikely:
-- stages are 1-3, PDs and LGDs 0-1, flags Y/N, and the ECL invariants
-- (final = max(model, floor); floor_applied says which one won) hold on every row.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

------------------------------------------------------------------ primary keys
ALTER TABLE loan_master          ADD CONSTRAINT pk_loan_master          PRIMARY KEY (loan_id);
ALTER TABLE loan_dev             ADD CONSTRAINT pk_loan_dev             PRIMARY KEY (loan_id);
ALTER TABLE stg_loan_snapshot    ADD CONSTRAINT pk_stg_loan_snapshot    PRIMARY KEY (reporting_date, row_num);
ALTER TABLE stg_control          ADD CONSTRAINT pk_stg_control          PRIMARY KEY (reporting_date);
ALTER TABLE dq_rule              ADD CONSTRAINT pk_dq_rule              PRIMARY KEY (rule_id);
ALTER TABLE dq_error             ADD CONSTRAINT pk_dq_error             PRIMARY KEY (error_id);
ALTER TABLE loan_snapshot        ADD CONSTRAINT pk_loan_snapshot        PRIMARY KEY (reporting_date, loan_id);
ALTER TABLE pd_score             ADD CONSTRAINT pk_pd_score             PRIMARY KEY (reporting_date, loan_id);
ALTER TABLE loan_stage_history   ADD CONSTRAINT pk_loan_stage_history   PRIMARY KEY (reporting_date, loan_id);
ALTER TABLE loan_stage_current   ADD CONSTRAINT pk_loan_stage_current   PRIMARY KEY (loan_id);
ALTER TABLE stage_change_audit   ADD CONSTRAINT pk_stage_change_audit   PRIMARY KEY (audit_id);
ALTER TABLE ecl_result           ADD CONSTRAINT pk_ecl_result           PRIMARY KEY (reporting_date, loan_id);
ALTER TABLE ecl_result_v1        ADD CONSTRAINT pk_ecl_result_v1        PRIMARY KEY (reporting_date, loan_id);
ALTER TABLE month_idx            ADD CONSTRAINT pk_month_idx            PRIMARY KEY (t);
ALTER TABLE param_setting        ADD CONSTRAINT pk_param_setting        PRIMARY KEY (setting_name);
ALTER TABLE param_scenario       ADD CONSTRAINT pk_param_scenario       PRIMARY KEY (scenario_code);
ALTER TABLE param_dpd_multiplier ADD CONSTRAINT pk_param_dpd_multiplier PRIMARY KEY (from_dpd);
ALTER TABLE param_floor          ADD CONSTRAINT pk_param_floor          PRIMARY KEY (stage, restructured_flag, months_in_stage3_from);
ALTER TABLE param_lgd            ADD CONSTRAINT pk_param_lgd            PRIMARY KEY (grade);
ALTER TABLE param_audit          ADD CONSTRAINT pk_param_audit          PRIMARY KEY (audit_id);
ALTER TABLE model_registry       ADD CONSTRAINT pk_model_registry       PRIMARY KEY (model_version);
ALTER TABLE batch_run            ADD CONSTRAINT pk_batch_run            PRIMARY KEY (batch_run_id);
ALTER TABLE ext_table_doc        ADD CONSTRAINT pk_ext_table_doc        PRIMARY KEY (table_name, column_name);

------------------------------------------------------------------ foreign keys
-- Every monthly row must belong to a known loan, and every derived row to a
-- clean snapshot row, so nothing downstream can refer to data that was rejected.
ALTER TABLE loan_snapshot      ADD CONSTRAINT fk_snapshot_loan      FOREIGN KEY (loan_id) REFERENCES loan_master (loan_id);
ALTER TABLE pd_score           ADD CONSTRAINT fk_pd_score_snapshot  FOREIGN KEY (reporting_date, loan_id) REFERENCES loan_snapshot (reporting_date, loan_id);
ALTER TABLE pd_score           ADD CONSTRAINT fk_pd_score_model     FOREIGN KEY (model_version) REFERENCES model_registry (model_version);
ALTER TABLE loan_stage_history ADD CONSTRAINT fk_stage_hist_snapshot FOREIGN KEY (reporting_date, loan_id) REFERENCES loan_snapshot (reporting_date, loan_id);
ALTER TABLE loan_stage_current ADD CONSTRAINT fk_stage_current_loan FOREIGN KEY (loan_id) REFERENCES loan_master (loan_id);
ALTER TABLE ecl_result         ADD CONSTRAINT fk_ecl_result_snapshot FOREIGN KEY (reporting_date, loan_id) REFERENCES loan_snapshot (reporting_date, loan_id);
ALTER TABLE ecl_result_v1      ADD CONSTRAINT fk_ecl_v1_snapshot    FOREIGN KEY (reporting_date, loan_id) REFERENCES loan_snapshot (reporting_date, loan_id);
ALTER TABLE dq_error           ADD CONSTRAINT fk_dq_error_rule      FOREIGN KEY (rule_id) REFERENCES dq_rule (rule_id);
ALTER TABLE loan_master        ADD CONSTRAINT fk_loan_master_model  FOREIGN KEY (pd_model_version) REFERENCES model_registry (model_version);

------------------------------------------------------------------ checks: loans
ALTER TABLE loan_master ADD CONSTRAINT ck_loan_master_term  CHECK (term_months IN (36, 60));
ALTER TABLE loan_master ADD CONSTRAINT ck_loan_master_grade CHECK (grade IN ('A','B','C','D','E','F','G'));
ALTER TABLE loan_master ADD CONSTRAINT ck_loan_master_pd    CHECK (pd_12m_orig BETWEEN 0 AND 1);
ALTER TABLE loan_master ADD CONSTRAINT ck_loan_master_rate  CHECK (int_rate BETWEEN 0 AND 1);
ALTER TABLE loan_dev    ADD CONSTRAINT ck_loan_dev_term     CHECK (term_months IN (36, 60));
ALTER TABLE loan_dev    ADD CONSTRAINT ck_loan_dev_grade    CHECK (grade IN ('A','B','C','D','E','F','G'));
ALTER TABLE loan_dev    ADD CONSTRAINT ck_loan_dev_default  CHECK (default_flag IN (0, 1));
ALTER TABLE loan_dev    ADD CONSTRAINT ck_loan_dev_rate     CHECK (int_rate BETWEEN 0 AND 1);

------------------------------------------------------------------ checks: monthly data
ALTER TABLE dq_rule  ADD CONSTRAINT ck_dq_rule_severity CHECK (severity IN ('REJECT', 'WARN'));
ALTER TABLE dq_rule  ADD CONSTRAINT ck_dq_rule_active   CHECK (active_flag IN ('Y', 'N'));
ALTER TABLE dq_error ADD CONSTRAINT ck_dq_error_severity CHECK (severity IN ('REJECT', 'WARN'));
ALTER TABLE stg_control ADD CONSTRAINT ck_stg_control_rows CHECK (expected_rows >= 0);

ALTER TABLE loan_snapshot ADD CONSTRAINT ck_snapshot_dpd       CHECK (dpd >= 0);
ALTER TABLE loan_snapshot ADD CONSTRAINT ck_snapshot_balance   CHECK (balance >= 0);
ALTER TABLE loan_snapshot ADD CONSTRAINT ck_snapshot_fico      CHECK (current_fico BETWEEN 300 AND 850);
ALTER TABLE loan_snapshot ADD CONSTRAINT ck_snapshot_forb      CHECK (forbearance_flag IN ('Y', 'N'));
ALTER TABLE loan_snapshot ADD CONSTRAINT ck_snapshot_remaining CHECK (remaining_months >= 1);
ALTER TABLE loan_snapshot ADD CONSTRAINT ck_snapshot_source    CHECK (data_source IN ('LC_ACTUAL', 'SIMULATED'));

ALTER TABLE pd_score ADD CONSTRAINT ck_pd_score_orig    CHECK (pd_12m_orig BETWEEN 0 AND 1);
ALTER TABLE pd_score ADD CONSTRAINT ck_pd_score_current CHECK (pd_12m_current BETWEEN 0 AND 1);
ALTER TABLE pd_score ADD CONSTRAINT ck_pd_score_source  CHECK (fico_source IN ('CURRENT', 'ORIGINATION'));

------------------------------------------------------------------ checks: stages
ALTER TABLE loan_stage_history ADD CONSTRAINT ck_stage_hist_stage CHECK (stage IN (1, 2, 3));
ALTER TABLE loan_stage_history ADD CONSTRAINT ck_stage_hist_prev  CHECK (prev_stage IN (1, 2, 3));
ALTER TABLE loan_stage_history ADD CONSTRAINT ck_stage_hist_cure  CHECK (cure_months >= 0);
ALTER TABLE loan_stage_current ADD CONSTRAINT ck_stage_cur_stage  CHECK (stage IN (1, 2, 3));
ALTER TABLE loan_stage_current ADD CONSTRAINT ck_stage_cur_cure   CHECK (cure_months >= 0);
ALTER TABLE loan_stage_current ADD CONSTRAINT ck_stage_cur_exited CHECK (exited_flag IN ('Y', 'N'));
ALTER TABLE stage_change_audit ADD CONSTRAINT ck_stage_audit_old  CHECK (old_stage IN (1, 2, 3));
ALTER TABLE stage_change_audit ADD CONSTRAINT ck_stage_audit_new  CHECK (new_stage IN (1, 2, 3));

------------------------------------------------------------------ checks: ECL
ALTER TABLE ecl_result ADD CONSTRAINT ck_ecl_stage    CHECK (stage IN (1, 2, 3));
ALTER TABLE ecl_result ADD CONSTRAINT ck_ecl_pd       CHECK (pd_12m BETWEEN 0 AND 1);
ALTER TABLE ecl_result ADD CONSTRAINT ck_ecl_lgd      CHECK (lgd BETWEEN 0 AND 1);
ALTER TABLE ecl_result ADD CONSTRAINT ck_ecl_restr    CHECK (restructured_flag IN ('Y', 'N'));
ALTER TABLE ecl_result ADD CONSTRAINT ck_ecl_final    CHECK (ecl_final = GREATEST(ecl_weighted, floor_amount));
ALTER TABLE ecl_result ADD CONSTRAINT ck_ecl_floor_flag CHECK (
      (floor_applied = 'Y' AND floor_amount >  ecl_weighted)
   OR (floor_applied = 'N' AND floor_amount <= ecl_weighted));

ALTER TABLE ecl_result_v1 ADD CONSTRAINT ck_ecl_v1_stage    CHECK (stage IN (1, 2, 3));
ALTER TABLE ecl_result_v1 ADD CONSTRAINT ck_ecl_v1_pd       CHECK (pd_12m BETWEEN 0 AND 1);
ALTER TABLE ecl_result_v1 ADD CONSTRAINT ck_ecl_v1_lgd      CHECK (lgd BETWEEN 0 AND 1);
ALTER TABLE ecl_result_v1 ADD CONSTRAINT ck_ecl_v1_restr    CHECK (restructured_flag IN ('Y', 'N'));
ALTER TABLE ecl_result_v1 ADD CONSTRAINT ck_ecl_v1_final    CHECK (ecl_final = GREATEST(ecl_weighted, floor_amount));
ALTER TABLE ecl_result_v1 ADD CONSTRAINT ck_ecl_v1_floor_flag CHECK (
      (floor_applied = 'Y' AND floor_amount >  ecl_weighted)
   OR (floor_applied = 'N' AND floor_amount <= ecl_weighted));

------------------------------------------------------------------ checks: parameters
ALTER TABLE month_idx            ADD CONSTRAINT ck_month_idx_t        CHECK (t >= 1);
ALTER TABLE param_scenario       ADD CONSTRAINT ck_param_scen_weight  CHECK (weight BETWEEN 0 AND 1);
ALTER TABLE param_scenario       ADD CONSTRAINT ck_param_scen_mult    CHECK (pd_multiplier > 0);
ALTER TABLE param_dpd_multiplier ADD CONSTRAINT ck_param_dpd_band     CHECK (from_dpd >= 0 AND to_dpd >= from_dpd);
ALTER TABLE param_dpd_multiplier ADD CONSTRAINT ck_param_dpd_mult     CHECK (multiplier > 0);
ALTER TABLE param_floor          ADD CONSTRAINT ck_param_floor_stage  CHECK (stage IN (1, 2, 3));
ALTER TABLE param_floor          ADD CONSTRAINT ck_param_floor_restr  CHECK (restructured_flag IN ('Y', 'N', '*'));
ALTER TABLE param_floor          ADD CONSTRAINT ck_param_floor_rate   CHECK (floor_rate BETWEEN 0 AND 1);
ALTER TABLE param_lgd            ADD CONSTRAINT ck_param_lgd_lgd      CHECK (lgd BETWEEN 0 AND 1);
ALTER TABLE param_lgd            ADD CONSTRAINT ck_param_lgd_grade_lgd CHECK (grade_lgd BETWEEN 0 AND 1);
ALTER TABLE param_lgd            ADD CONSTRAINT ck_param_lgd_fallback CHECK (fallback_flag IN ('Y', 'N'));
ALTER TABLE param_audit          ADD CONSTRAINT ck_param_audit_action CHECK (action IN ('INSERT', 'UPDATE', 'DELETE'));

------------------------------------------------------------------ checks: model and batch
ALTER TABLE model_registry ADD CONSTRAINT ck_model_features CHECK (features IS JSON);
ALTER TABLE model_registry ADD CONSTRAINT ck_model_active   CHECK (active_flag IN ('Y', 'N'));
ALTER TABLE model_registry ADD CONSTRAINT ck_model_auc      CHECK (auc_test BETWEEN 0 AND 1);
ALTER TABLE batch_run      ADD CONSTRAINT ck_batch_run_status CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED'));

------------------------------------------------------------------ indexes
-- load_clean keeps a staged row only if it has no REJECT error: looked up by row.
CREATE INDEX ix_dq_error_row      ON dq_error (reporting_date, row_num);
-- V_DQ_SUMMARY and the DQ tests group by rule within a date.
CREATE INDEX ix_dq_error_rule     ON dq_error (reporting_date, rule_id);
-- Foreign-key column: without it, deleting a LOAN_MASTER row locks all of LOAN_SNAPSHOT.
CREATE INDEX ix_snapshot_loan     ON loan_snapshot (loan_id);
CREATE INDEX ix_stage_audit_date  ON stage_change_audit (reporting_date);
CREATE INDEX ix_batch_run_run     ON batch_run (run_id);
CREATE INDEX ix_batch_run_step    ON batch_run (reporting_date, step_name);
CREATE INDEX ix_param_audit_table ON param_audit (table_name, changed_ts);
