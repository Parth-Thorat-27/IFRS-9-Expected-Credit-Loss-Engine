CREATE OR REPLACE PACKAGE pkg_ecl AS
  -- Expected credit loss, two ways that must agree to the cent:
  --
  --   run_v2  production: one set-based INSERT ... SELECT. Every loan is
  --           joined to every scenario and to MONTH_IDX, one row per month of
  --           its horizon; the balance in month t comes from a closed form, so
  --           no row depends on the row before it and the database can work
  --           on all of them at once.
  --   run_v1  benchmark only: a cursor loop that calls fn_ecl_loan per loan
  --           per scenario and inserts one row at a time. Deliberately naive.
  --
  -- Per scenario: PD = min(measurement PD x scenario multiplier, PD_CAP),
  -- monthly hazard h = 1 - (1 - PD)^(1/12), and
  --   ECL = sum_{t=1..H} (1 - h)^(t-1) h LGD EAD_t (1 + r)^-t
  -- (Stage 3: LGD x balance). Then the probability-weighted ECL, the RBI floor
  -- (floor rate x balance) and final ECL = max(weighted, floor).
  -- Money is rounded to cents only when stored.

  -- ECL for one loan in one scenario, unrounded. p_pd_12m is the scenario PD.
  FUNCTION fn_ecl_loan(p_balance          IN NUMBER,
                       p_annual_rate      IN NUMBER,
                       p_remaining_months IN NUMBER,
                       p_horizon_months   IN NUMBER,
                       p_pd_12m           IN NUMBER,
                       p_lgd              IN NUMBER,
                       p_stage            IN NUMBER) RETURN NUMBER DETERMINISTIC;

  PROCEDURE run_v2(p_reporting_date IN DATE, p_run_id IN NUMBER);
  PROCEDURE run_v1(p_reporting_date IN DATE, p_run_id IN NUMBER);

  -- Largest absolute difference between ECL_RESULT and ECL_RESULT_V1 over every
  -- money column for the date. Raises if the two hold different loans.
  FUNCTION compare_versions(p_reporting_date IN DATE) RETURN NUMBER;
END pkg_ecl;
/
