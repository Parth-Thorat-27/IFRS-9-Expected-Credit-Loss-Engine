"""What the PD model may and may not see, defined once.

prepare_data.py asserts the leakage rule before writing anything, and
train_pd_model.py and score_pd.py build the derived features from here, so
training and scoring can never drift apart.
"""
from __future__ import annotations

import numpy as np
import pandas as pd
from sklearn.base import BaseEstimator, OneToOneFeatureMixin, TransformerMixin

# Application-time columns kept for every loan (cleaned names). sub_grade and
# addr_state are kept for reporting but are not model inputs: sub_grade only
# refines grade and int_rate, which the model already has.
APPLICATION_COLUMNS = [
    "loan_amnt", "funded_amnt", "int_rate", "installment", "grade", "sub_grade",
    "emp_length", "home_ownership", "annual_inc", "verification_status", "purpose",
    "addr_state", "dti", "delinq_2yrs", "earliest_cr_line", "fico_range_low",
    "fico_range_high", "inq_last_6mths", "open_acc", "pub_rec", "revol_bal",
    "revol_util", "total_acc", "mort_acc", "pub_rec_bankruptcies", "application_type",
]

# Known only after the loan has run. Any of these as a model input would leak
# the outcome into the prediction and make the model look far better than it is.
LEAKAGE_COLUMNS = {
    "out_prncp", "out_prncp_inv", "total_pymnt", "total_pymnt_inv", "total_rec_prncp",
    "total_rec_int", "total_rec_late_fee", "recoveries", "collection_recovery_fee",
    "last_pymnt_d", "last_pymnt_amnt", "next_pymnt_d", "last_credit_pull_d",
    "debt_settlement_flag", "pymnt_plan",
}
LEAKAGE_PREFIXES = ("last_fico_range_", "hardship_", "settlement_")

NUMERIC_FEATURES = [
    "loan_amnt", "funded_amnt", "int_rate", "installment", "log_annual_inc", "dti",
    "delinq_2yrs", "fico", "credit_history_months", "inq_last_6mths", "open_acc",
    "pub_rec", "log_revol_bal", "revol_util", "total_acc", "mort_acc",
    "pub_rec_bankruptcies",
]
# term and emp_length are numbers in the data but one-hot encoded: their effect
# on default risk is not a straight line.
CATEGORICAL_FEATURES = [
    "grade", "term_months", "home_ownership", "verification_status", "purpose",
    "emp_length", "application_type",
]
# Raw columns the derived features are computed from.
DERIVATION_INPUTS = [
    "fico_range_low", "fico_range_high", "issue_d", "earliest_cr_line", "annual_inc", "revol_bal",
]


def is_leakage(column: str) -> bool:
    return column in LEAKAGE_COLUMNS or column.startswith(LEAKAGE_PREFIXES)


def model_inputs() -> list[str]:
    """Every column the model reads, directly or through a derived feature."""
    return NUMERIC_FEATURES + CATEGORICAL_FEATURES + DERIVATION_INPUTS


def assert_no_leakage(columns: list[str]) -> None:
    leaked = sorted(c for c in columns if is_leakage(c))
    assert not leaked, f"leakage columns in the model inputs: {leaked}"


class ClipToTrainingRange(OneToOneFeatureMixin, TransformerMixin, BaseEstimator):
    """Cap each numeric feature at its training 1st and 99th percentiles.

    A logistic model extrapolates in a straight line, so one absurd input
    pushes the PD towards 100%. Lending Club stores an undefined
    debt-to-income ratio as 999, far beyond anything in training. The caps
    are learned in fit() from the training data only and travel inside the
    saved Pipeline, so scoring applies exactly the same caps.
    """

    def __init__(self, lower: float = 0.01, upper: float = 0.99):
        self.lower = lower
        self.upper = upper

    def fit(self, X, y=None):
        values = np.asarray(X, dtype=float)
        self.n_features_in_ = values.shape[1]
        self.low_ = np.nanquantile(values, self.lower, axis=0)
        self.high_ = np.nanquantile(values, self.upper, axis=0)
        return self

    def transform(self, X):
        return np.clip(np.asarray(X, dtype=float), self.low_, self.high_)


def to_category_strings(frame: pd.DataFrame) -> pd.DataFrame:
    """Give every categorical column one type for the one-hot encoder.

    36, 36.0 and "36" must all become the same category, and a missing value
    must become its own category rather than an error. This runs inside the
    saved Pipeline, so training and scoring always encode identically.
    """
    out = {}
    for col in frame.columns:
        values = frame[col]
        if pd.api.types.is_numeric_dtype(values):
            # Through Int64 so 36.0 becomes "36", not "36.0".
            out[col] = values.astype("Int64").astype("string").fillna("missing")
        else:
            out[col] = values.astype("string").fillna("missing")
    return pd.DataFrame(out, index=frame.index).astype(object)


def add_derived_features(df: pd.DataFrame, fico: pd.Series | None = None) -> pd.DataFrame:
    """Add fico, credit_history_months, log_annual_inc and log_revol_bal.

    fico defaults to the origination FICO (middle of the reported range).
    Monthly scoring passes the current FICO instead, so a falling score raises the PD.
    """
    out = df.copy()
    out["fico"] = (out["fico_range_low"] + out["fico_range_high"]) / 2 if fico is None else fico
    issue = pd.to_datetime(out["issue_d"])
    first_line = pd.to_datetime(out["earliest_cr_line"])
    out["credit_history_months"] = (
        (issue.dt.year - first_line.dt.year) * 12 + (issue.dt.month - first_line.dt.month)
    )
    # log1p rather than log: both columns contain genuine zeros.
    out["log_annual_inc"] = np.log1p(out["annual_inc"].clip(lower=0))
    out["log_revol_bal"] = np.log1p(out["revol_bal"].clip(lower=0))
    return out
