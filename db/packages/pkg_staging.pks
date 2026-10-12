-- The result of one staging decision. An object type lets one pure function
-- return the stage, the reason and the updated cure counter together, and
-- SQL can still read each part (decision.stage, decision.reason_code, ...).
CREATE OR REPLACE TYPE stage_decision_t AS OBJECT (
  stage        NUMBER(1),
  reason_code  VARCHAR2(20),
  cure_months  NUMBER(3)
);
/

CREATE OR REPLACE PACKAGE pkg_staging AS
  -- IFRS 9 stage assignment, checked in this order:
  --   Stage 3  DPD above STAGE3_DPD (90)                       -> DPD_90
  --            or status Default                               -> DEFAULT_STATUS
  --   Stage 2  DPD above STAGE2_DPD (30)                       -> DPD_30
  --            forbearance flag Y                              -> FORBEARANCE
  --            PD deterioration: current >= SICR_RELATIVE x origination
  --            and current - origination >= SICR_ABSOLUTE      -> PD_DETERIORATION
  --            in Stage 2 or 3 last month and fewer than CURE_MONTHS
  --            straight months meeting Stage 1 conditions      -> CURE_PROBATION
  --   Stage 1  otherwise                                       -> PERFORMING

  -- Pure: the result depends only on the arguments (no table reads), so it is
  -- DETERMINISTIC and can be unit-tested by calling it with chosen values.
  FUNCTION fn_assign_stage(p_dpd               IN NUMBER,
                           p_loan_status       IN VARCHAR2,
                           p_forbearance_flag  IN VARCHAR2,
                           p_pd_12m_orig       IN NUMBER,
                           p_pd_12m_current    IN NUMBER,
                           p_prev_stage        IN NUMBER,
                           p_prev_cure_months  IN NUMBER,
                           p_stage2_dpd        IN NUMBER,
                           p_stage3_dpd        IN NUMBER,
                           p_sicr_relative     IN NUMBER,
                           p_sicr_absolute     IN NUMBER,
                           p_cure_months       IN NUMBER) RETURN stage_decision_t DETERMINISTIC;

  -- Same decision with the thresholds taken from the loaded XML parameters.
  FUNCTION fn_assign_stage(p_dpd               IN NUMBER,
                           p_loan_status       IN VARCHAR2,
                           p_forbearance_flag  IN VARCHAR2,
                           p_pd_12m_orig       IN NUMBER,
                           p_pd_12m_current    IN NUMBER,
                           p_prev_stage        IN NUMBER,
                           p_prev_cure_months  IN NUMBER) RETURN stage_decision_t;

  -- Stage every loan in the date's snapshot, set-based: decisions into
  -- LOAN_STAGE_HISTORY (from each loan's previous assessment), one MERGE into
  -- LOAN_STAGE_CURRENT (which fires TRG_STAGE_CHANGE_AUDIT), and loans that
  -- left the book marked exited.
  PROCEDURE assign_stages(p_reporting_date IN DATE, p_run_id IN NUMBER);
END pkg_staging;
/
