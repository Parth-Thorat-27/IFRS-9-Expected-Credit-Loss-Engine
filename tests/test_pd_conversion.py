"""Term-to-12-month and monthly-hazard conversions, PD floor and cap."""
import numpy as np
import pytest

from ecl.pd import apply_cap, apply_floor, monthly_hazard, term_to_12m


def test_20pct_over_36_months_is_about_7_17pct_over_12():
    # 1 - 0.8 ** (12/36) = 1 - 0.8 ** (1/3) = 0.071682
    assert term_to_12m(0.20, 36) == pytest.approx(0.071682, abs=1e-6)
    assert round(float(term_to_12m(0.20, 36)) * 100, 2) == 7.17


def test_12_month_term_is_unchanged():
    assert term_to_12m(0.05, 12) == pytest.approx(0.05)


def test_longer_term_spreads_the_same_pd_thinner():
    assert term_to_12m(0.30, 60) < term_to_12m(0.30, 36)


def test_conversion_round_trips_through_the_hazard():
    pd_12m = 0.05
    h = monthly_hazard(pd_12m)
    assert h == pytest.approx(0.0042653, abs=1e-7)  # the golden loan's hazard, 0.42653%
    assert 1 - (1 - h) ** 12 == pytest.approx(pd_12m)


def test_edges():
    assert term_to_12m(0.0, 36) == 0.0
    assert term_to_12m(1.0, 36) == 1.0
    assert monthly_hazard(0.0) == 0.0


def test_vectorised_with_mixed_terms():
    out = term_to_12m([0.2, 0.2], [36, 60])
    assert out.shape == (2,) and out[0] > out[1]


def test_floor_and_cap():
    assert list(apply_floor([0.0001, 0.02], 0.0005)) == [0.0005, 0.02]
    assert list(apply_cap([0.5, 1.4], 0.99)) == [0.5, 0.99]
    assert np.all(apply_cap(apply_floor([0.0, 2.0], 0.0005), 0.99) == [0.0005, 0.99])
