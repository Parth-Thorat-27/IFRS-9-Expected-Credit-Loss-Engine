CREATE OR REPLACE PACKAGE pkg_lgd AS
  -- LGD calibration from charged-off loans in LOAN_DEV:
  --
  --   EAD = funded_amnt - total_rec_prncp          (principal still owed at charge-off)
  --   LGD = 1 - (recoveries - collection_recovery_fee) / EAD, bounded to 0..1 per loan
  --
  -- averaged by grade and weighted by EAD, so a $30,000 loss counts more than
  -- a $1,000 one. A grade with fewer than LGD_MIN_DEFAULTS defaults uses the
  -- portfolio average instead (row ALL), because a small sample is too noisy.
  -- Recoveries are not discounted, a stated simplification.

  PROCEDURE calibrate(p_run_id IN NUMBER);
END pkg_lgd;
/
