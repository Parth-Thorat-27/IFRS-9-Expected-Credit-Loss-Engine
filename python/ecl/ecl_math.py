"""Independent Python implementation of the ECL formulas.

Written separately from the PL/SQL engine, in floating point, so the golden
tests compare two implementations instead of checking the engine against
itself. docs/methodology.md's worked example is generated from it too.

For one loan and one scenario, with balance B, monthly rate r, n remaining
months, horizon H, 12-month PD and LGD:

    P     = B r / (1 - (1 + r)^-n)                level payment
    B_t   = B_{t-1} (1 + r) - P                    balance after t payments
    EAD_t = B_{t-1}                                exposure in month t
    h     = 1 - (1 - PD_12m)^(1/12)                monthly hazard
    ECL   = sum_{t=1..H} (1 - h)^(t-1) h LGD EAD_t (1 + r)^-t
    Stage 3: ECL = LGD x B
"""
from __future__ import annotations

from dataclasses import dataclass

from ecl.pd import monthly_hazard


def level_payment(balance: float, monthly_rate: float, n: int) -> float:
    if monthly_rate == 0:
        return balance / n
    return balance * monthly_rate / (1 - (1 + monthly_rate) ** -n)


@dataclass
class Month:
    t: int
    ead: float          # balance at the start of month t
    survival: float     # probability of no default before month t
    marginal_pd: float  # probability of defaulting in month t
    discount: float     # (1 + r)^-t
    loss: float         # marginal_pd x LGD x EAD x discount


def schedule(balance: float, annual_rate: float, remaining: int, horizon: int,
             pd_12m: float, lgd: float) -> list[Month]:
    r = annual_rate / 12
    payment = level_payment(balance, r, remaining)
    h = float(monthly_hazard(pd_12m))
    months, bal = [], balance
    for t in range(1, horizon + 1):
        ead = max(bal, 0.0)
        survival = (1 - h) ** (t - 1)
        discount = (1 + r) ** -t
        months.append(Month(t, ead, survival, survival * h, discount, survival * h * lgd * ead * discount))
        bal = bal * (1 + r) - payment if r else bal - payment
    return months


def model_ecl(stage: int, balance: float, annual_rate: float, remaining: int, pd_12m: float, lgd: float) -> float:
    """ECL for one scenario: 12 months for Stage 1, the remaining life for Stage 2, LGD x B for Stage 3."""
    if stage == 3:
        return lgd * balance
    horizon = min(12, remaining) if stage == 1 else remaining
    return sum(m.loss for m in schedule(balance, annual_rate, remaining, horizon, pd_12m, lgd))


def cents(x: float) -> float:
    return round(x + 0.0, 2)


def final_ecl(weighted: float, floor_rate: float, balance: float) -> tuple[float, float, str]:
    """(floor amount, final ECL, floor_applied), all in cents, as the engine stores them."""
    floor_amount = cents(floor_rate * balance)
    model = cents(weighted)
    return floor_amount, max(model, floor_amount), "Y" if floor_amount > model else "N"
