"""PD conversions shared by training, scoring and the golden ECL test.

The model predicts the probability of default over the loan's whole term T
(36 or 60 months). Under a constant-hazard assumption the default intensity
is the same every month, which gives:

    PD_12m = 1 - (1 - PD_term) ** (12 / T)      survive 12 of T months
    h      = 1 - (1 - PD_12m) ** (1 / 12)       monthly hazard
"""
from __future__ import annotations

import numpy as np


def term_to_12m(pd_term, term_months):
    """Convert a PD over the full term to a 12-month PD (constant hazard)."""
    pd_term = np.clip(np.asarray(pd_term, dtype=float), 0.0, 1.0)
    return 1.0 - (1.0 - pd_term) ** (12.0 / np.asarray(term_months, dtype=float))


def monthly_hazard(pd_12m):
    """Probability of defaulting in any one month, given survival so far."""
    return 1.0 - (1.0 - np.asarray(pd_12m, dtype=float)) ** (1.0 / 12.0)


def apply_floor(pd_values, floor: float):
    """Minimum PD (PD_FLOOR): a modelling safeguard, no loan is risk-free."""
    return np.maximum(np.asarray(pd_values, dtype=float), floor)


def apply_cap(pd_values, cap: float):
    """Maximum PD for Stages 1 and 2 (PD_CAP), applied after multipliers."""
    return np.minimum(np.asarray(pd_values, dtype=float), cap)
