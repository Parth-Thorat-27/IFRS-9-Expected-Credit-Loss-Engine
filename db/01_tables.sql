-- 01_tables.sql: every table, in the order the data flows through them.
-- Keys, checks and indexes are in 02 and comments in 03, so this file shows
-- the plain shape of the data. Conventions: money NUMBER(18,2), rates and PDs
-- NUMBER(12,10), codes VARCHAR2, surrogate keys as identity columns.
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

------------------------------------------------------------------ loans
CREATE TABLE loan_master (
  loan_id               NUMBER(12)     NOT NULL,
  issue_d               DATE           NOT NULL,
  term_months           NUMBER(3)      NOT NULL,
  loan_amnt             NUMBER(18,2),
  funded_amnt           NUMBER(18,2)   NOT NULL,
  int_rate              NUMBER(12,10)  NOT NULL,
  installment           NUMBER(18,2),
  grade                 VARCHAR2(1)    NOT NULL,
  sub_grade             VARCHAR2(2),
  emp_length            NUMBER(2),
  home_ownership        VARCHAR2(10),
  annual_inc            NUMBER(18,2),
  verification_status   VARCHAR2(20),
  purpose               VARCHAR2(30),
  addr_state            VARCHAR2(2),
  dti                   NUMBER(7,2),
  delinq_2yrs           NUMBER(4),
  earliest_cr_line      DATE,
  fico_range_low        NUMBER(3),
  fico_range_high       NUMBER(3),
  inq_last_6mths        NUMBER(4),
  open_acc              NUMBER(4),
  pub_rec               NUMBER(4),
  revol_bal             NUMBER(18,2),
  revol_util            NUMBER(12,10),
  total_acc             NUMBER(4),
  mort_acc              NUMBER(4),
  pub_rec_bankruptcies  NUMBER(4),
  application_type      VARCHAR2(20),
  pd_12m_orig           NUMBER(12,10),
  pd_model_version      VARCHAR2(30),
  loaded_ts             TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE loan_dev (
  loan_id                  NUMBER(12)     NOT NULL,
  loan_status              VARCHAR2(60)   NOT NULL,
  default_flag             NUMBER(1)      NOT NULL,
  issue_d                  DATE           NOT NULL,
  term_months              NUMBER(3)      NOT NULL,
  loan_amnt                NUMBER(18,2),
  funded_amnt              NUMBER(18,2)   NOT NULL,
  int_rate                 NUMBER(12,10)  NOT NULL,
  installment              NUMBER(18,2),
  grade                    VARCHAR2(1)    NOT NULL,
  sub_grade                VARCHAR2(2),
  emp_length               NUMBER(2),
  home_ownership           VARCHAR2(10),
  annual_inc               NUMBER(18,2),
  verification_status      VARCHAR2(20),
  purpose                  VARCHAR2(30),
  addr_state               VARCHAR2(2),
  dti                      NUMBER(7,2),
  delinq_2yrs              NUMBER(4),
  earliest_cr_line         DATE,
  fico_range_low           NUMBER(3),
  fico_range_high          NUMBER(3),
  inq_last_6mths           NUMBER(4),
  open_acc                 NUMBER(4),
  pub_rec                  NUMBER(4),
  revol_bal                NUMBER(18,2),
  revol_util               NUMBER(12,10),
  total_acc                NUMBER(4),
  mort_acc                 NUMBER(4),
  pub_rec_bankruptcies     NUMBER(4),
  application_type         VARCHAR2(20),
  total_rec_prncp          NUMBER(18,2),
  recoveries               NUMBER(18,2),
  collection_recovery_fee  NUMBER(18,2),
  loaded_ts                TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

------------------------------------------------------------------ monthly intake
-- Staging columns are all text and wide: a row is stored exactly as received,
-- however malformed, so data quality can say what was wrong with it.
CREATE TABLE stg_loan_snapshot (
  reporting_date      DATE           NOT NULL,
  row_num             NUMBER(10)     NOT NULL,
  run_id              NUMBER(12)     NOT NULL,
  raw_reporting_date  VARCHAR2(200),
  loan_id             VARCHAR2(200),
  loan_status         VARCHAR2(200),
  dpd                 VARCHAR2(200),
  balance             VARCHAR2(200),
  current_fico        VARCHAR2(200),
  forbearance_flag    VARCHAR2(200),
  remaining_months    VARCHAR2(200),
  data_source         VARCHAR2(200),
  loaded_ts           TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE stg_control (
  reporting_date    DATE          NOT NULL,
  run_id            NUMBER(12)    NOT NULL,
  control_file      VARCHAR2(100) NOT NULL,
  expected_rows     NUMBER(10)    NOT NULL,
  expected_balance  NUMBER(18,2)  NOT NULL,
  loaded_ts         TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE dq_rule (
  rule_id      VARCHAR2(10)    NOT NULL,
  rule_name    VARCHAR2(100)   NOT NULL,
  severity     VARCHAR2(10)    NOT NULL,
  column_name  VARCHAR2(30),
  predicate    VARCHAR2(4000)  NOT NULL,
  message      VARCHAR2(400)   NOT NULL,
  active_flag  VARCHAR2(1)     DEFAULT 'Y' NOT NULL
);

CREATE TABLE dq_error (
  error_id        NUMBER GENERATED ALWAYS AS IDENTITY,
  reporting_date  DATE           NOT NULL,
  run_id          NUMBER(12)     NOT NULL,
  rule_id         VARCHAR2(10)   NOT NULL,
  severity        VARCHAR2(10)   NOT NULL,
  row_num         NUMBER(10)     NOT NULL,
  loan_id         VARCHAR2(200),
  column_name     VARCHAR2(30),
  bad_value       VARCHAR2(200),
  message         VARCHAR2(400)  NOT NULL,
  created_ts      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE loan_snapshot (
  reporting_date    DATE           NOT NULL,
  loan_id           NUMBER(12)     NOT NULL,
  loan_status       VARCHAR2(60),
  dpd               NUMBER(5)      NOT NULL,
  balance           NUMBER(18,2)   NOT NULL,
  current_fico      NUMBER(5,1),
  forbearance_flag  VARCHAR2(1)    NOT NULL,
  remaining_months  NUMBER(4)      NOT NULL,
  data_source       VARCHAR2(20)   NOT NULL,
  run_id            NUMBER(12)     NOT NULL,
  loaded_ts         TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

------------------------------------------------------------------ scores and stages
CREATE TABLE pd_score (
  reporting_date  DATE           NOT NULL,
  loan_id         NUMBER(12)     NOT NULL,
  pd_12m_orig     NUMBER(12,10)  NOT NULL,
  pd_12m_current  NUMBER(12,10)  NOT NULL,
  fico_used       NUMBER(5,1),
  fico_source     VARCHAR2(12)   NOT NULL,
  model_version   VARCHAR2(30)   NOT NULL,
  run_id          NUMBER(12)     NOT NULL,
  scored_ts       TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE loan_stage_history (
  reporting_date  DATE          NOT NULL,
  loan_id         NUMBER(12)    NOT NULL,
  stage           NUMBER(1)     NOT NULL,
  reason_code     VARCHAR2(20)  NOT NULL,
  prev_stage      NUMBER(1),
  cure_months     NUMBER(3)     NOT NULL,
  stage_since     DATE          NOT NULL,
  stage3_since    DATE,
  run_id          NUMBER(12)    NOT NULL,
  assessed_ts     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE loan_stage_current (
  loan_id         NUMBER(12)    NOT NULL,
  reporting_date  DATE          NOT NULL,
  stage           NUMBER(1)     NOT NULL,
  reason_code     VARCHAR2(20)  NOT NULL,
  cure_months     NUMBER(3)     NOT NULL,
  stage_since     DATE          NOT NULL,
  stage3_since    DATE,
  exited_flag     VARCHAR2(1)   DEFAULT 'N' NOT NULL,
  exited_date     DATE,
  updated_ts      TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE stage_change_audit (
  audit_id        NUMBER GENERATED ALWAYS AS IDENTITY,
  loan_id         NUMBER(12)     NOT NULL,
  reporting_date  DATE           NOT NULL,
  old_stage       NUMBER(1),
  new_stage       NUMBER(1)      NOT NULL,
  old_reason      VARCHAR2(20),
  new_reason      VARCHAR2(20),
  changed_by      VARCHAR2(128)  NOT NULL,
  changed_ts      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

------------------------------------------------------------------ ECL results
CREATE TABLE ecl_result (
  reporting_date     DATE           NOT NULL,
  loan_id            NUMBER(12)     NOT NULL,
  stage              NUMBER(1)      NOT NULL,
  reason_code        VARCHAR2(20)   NOT NULL,
  balance            NUMBER(18,2)   NOT NULL,
  int_rate           NUMBER(12,10)  NOT NULL,
  remaining_months   NUMBER(4)      NOT NULL,
  horizon_months     NUMBER(4)      NOT NULL,
  dpd                NUMBER(5)      NOT NULL,
  restructured_flag  VARCHAR2(1)    NOT NULL,
  months_in_stage3   NUMBER(4),
  lgd                NUMBER(12,10)  NOT NULL,
  pd_12m             NUMBER(12,10)  NOT NULL,
  ecl_base           NUMBER(18,2)   NOT NULL,
  ecl_downside       NUMBER(18,2)   NOT NULL,
  ecl_severe         NUMBER(18,2)   NOT NULL,
  ecl_weighted       NUMBER(18,2)   NOT NULL,
  floor_rate         NUMBER(12,10)  NOT NULL,
  floor_amount       NUMBER(18,2)   NOT NULL,
  ecl_final          NUMBER(18,2)   NOT NULL,
  floor_applied      VARCHAR2(1)    NOT NULL,
  run_id             NUMBER(12)     NOT NULL,
  calc_ts            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

-- Same shape as ECL_RESULT; only the deliberately row-by-row benchmark writes here.
CREATE TABLE ecl_result_v1 (
  reporting_date     DATE           NOT NULL,
  loan_id            NUMBER(12)     NOT NULL,
  stage              NUMBER(1)      NOT NULL,
  reason_code        VARCHAR2(20)   NOT NULL,
  balance            NUMBER(18,2)   NOT NULL,
  int_rate           NUMBER(12,10)  NOT NULL,
  remaining_months   NUMBER(4)      NOT NULL,
  horizon_months     NUMBER(4)      NOT NULL,
  dpd                NUMBER(5)      NOT NULL,
  restructured_flag  VARCHAR2(1)    NOT NULL,
  months_in_stage3   NUMBER(4),
  lgd                NUMBER(12,10)  NOT NULL,
  pd_12m             NUMBER(12,10)  NOT NULL,
  ecl_base           NUMBER(18,2)   NOT NULL,
  ecl_downside       NUMBER(18,2)   NOT NULL,
  ecl_severe         NUMBER(18,2)   NOT NULL,
  ecl_weighted       NUMBER(18,2)   NOT NULL,
  floor_rate         NUMBER(12,10)  NOT NULL,
  floor_amount       NUMBER(18,2)   NOT NULL,
  ecl_final          NUMBER(18,2)   NOT NULL,
  floor_applied      VARCHAR2(1)    NOT NULL,
  run_id             NUMBER(12)     NOT NULL,
  calc_ts            TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

-- Row source for the set-based ECL: one row per month of a loan's remaining life.
CREATE TABLE month_idx (
  t  NUMBER(3) NOT NULL
);

------------------------------------------------------------------ parameters
CREATE TABLE param_setting (
  setting_name   VARCHAR2(40)   NOT NULL,
  setting_value  NUMBER         NOT NULL,
  description    VARCHAR2(200),
  source_file    VARCHAR2(200)  NOT NULL,
  loaded_ts      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE param_scenario (
  scenario_code  VARCHAR2(20)   NOT NULL,
  weight         NUMBER(12,10)  NOT NULL,
  pd_multiplier  NUMBER(12,10)  NOT NULL,
  loaded_ts      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE param_dpd_multiplier (
  from_dpd    NUMBER(5)      NOT NULL,
  to_dpd      NUMBER(5)      NOT NULL,
  multiplier  NUMBER(12,10)  NOT NULL,
  loaded_ts   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE param_floor (
  stage                  NUMBER(1)      NOT NULL,
  restructured_flag      VARCHAR2(1)    NOT NULL,
  months_in_stage3_from  NUMBER(4)      NOT NULL,
  months_in_stage3_to    NUMBER(4),
  floor_rate             NUMBER(12,10)  NOT NULL,
  source                 VARCHAR2(200),
  loaded_ts              TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE param_lgd (
  grade           VARCHAR2(3)    NOT NULL,
  lgd             NUMBER(12,10)  NOT NULL,
  grade_lgd       NUMBER(12,10)  NOT NULL,
  defaults_count  NUMBER(10)     NOT NULL,
  ead_total       NUMBER(18,2)   NOT NULL,
  fallback_flag   VARCHAR2(1)    NOT NULL,
  calibrated_ts   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE param_audit (
  audit_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  table_name   VARCHAR2(30)   NOT NULL,
  param_key    VARCHAR2(100)  NOT NULL,
  column_name  VARCHAR2(30)   NOT NULL,
  action       VARCHAR2(6)    NOT NULL,
  old_value    VARCHAR2(200),
  new_value    VARCHAR2(200),
  changed_by   VARCHAR2(128)  NOT NULL,
  changed_ts   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

------------------------------------------------------------------ model and batch
CREATE TABLE model_registry (
  model_version       VARCHAR2(30)   NOT NULL,
  algorithm           VARCHAR2(100)  NOT NULL,
  train_from          DATE           NOT NULL,
  train_to            DATE           NOT NULL,
  test_from           DATE           NOT NULL,
  test_to             DATE           NOT NULL,
  train_rows          NUMBER(10)     NOT NULL,
  test_rows           NUMBER(10)     NOT NULL,
  train_default_rate  NUMBER(12,10)  NOT NULL,
  test_default_rate   NUMBER(12,10)  NOT NULL,
  test_mean_pd        NUMBER(12,10)  NOT NULL,
  auc_train           NUMBER(12,10)  NOT NULL,
  auc_test            NUMBER(12,10)  NOT NULL,
  gini_test           NUMBER(12,10)  NOT NULL,
  ks_test             NUMBER(12,10)  NOT NULL,
  brier_test          NUMBER(12,10)  NOT NULL,
  features            CLOB           NOT NULL,
  artifact_file       VARCHAR2(200)  NOT NULL,
  active_flag         VARCHAR2(1)    DEFAULT 'Y' NOT NULL,
  trained_ts          TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE SEQUENCE batch_run_id_seq;

-- Oracle rejects COMMENT ON for external tables (ORA-30657), so their
-- descriptions are stored here and merged in by V_DATA_DICTIONARY.
CREATE TABLE ext_table_doc (
  table_name   VARCHAR2(128)  NOT NULL,
  column_name  VARCHAR2(128)  NOT NULL,
  comments     VARCHAR2(4000) NOT NULL
);

CREATE TABLE batch_run (
  batch_run_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  run_id           NUMBER(12)      NOT NULL,
  reporting_date   DATE,
  step_name        VARCHAR2(40)    NOT NULL,
  status           VARCHAR2(10)    NOT NULL,
  started_ts       TIMESTAMP       NOT NULL,
  ended_ts         TIMESTAMP,
  elapsed_seconds  NUMBER(12,3),
  rows_processed   NUMBER(12),
  message          VARCHAR2(4000),
  db_user          VARCHAR2(128)   NOT NULL
);
