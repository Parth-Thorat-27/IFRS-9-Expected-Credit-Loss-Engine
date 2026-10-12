"""Phase 5: train the PD model, validate it out of time, register it, and score
the live book's origination PD.

  1. Read LOAN_DEV. Train on loans issued up to 2014, test on 2015 issues
     ("out of time": the model never sees the period it is tested on).
  2. Pipeline: median imputation and scaling for numbers, one-hot encoding for
     categories, logistic regression with no class weighting, so the outputs
     stay real probabilities.
  3. AUC, Gini, KS, Brier and a decile calibration table on the test set.
     Stops if test AUC is above 0.90: on this data that would mean leakage.
  4. Save models/pd_model.joblib (git-ignored) and models/pd_model.json,
     register the model in MODEL_REGISTRY, write docs/model_report.md.
  5. Score LOAN_MASTER with application data, convert term PD to 12-month PD
     (constant hazard), apply PD_FLOOR, write LOAN_MASTER.pd_12m_orig.

Usage: python python/train_pd_model.py [--run-id N]
"""
from __future__ import annotations

import argparse
import json
from datetime import date, datetime

import joblib
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import brier_score_loss, roc_auc_score, roc_curve
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import FunctionTransformer, OneHotEncoder, StandardScaler

from ecl import features, markdown
from ecl.batchlog import batch_step
from ecl.config import DOCS_DIR, MODELS_DIR
from ecl.db import connect, get_setting, read_frame
from ecl.log import get_logger
from ecl.pd import apply_floor, term_to_12m

log = get_logger("train_pd_model")

TRAIN_LAST_ISSUE = pd.Timestamp("2014-12-31")
TEST_YEAR = 2015
# A credit-scoring model on application data typically reaches 0.65-0.75.
# Far above that, a post-origination column has almost certainly leaked in.
MAX_TEST_AUC = 0.90

MODEL_FILE = MODELS_DIR / "pd_model.joblib"
METADATA_FILE = MODELS_DIR / "pd_model.json"
X_COLUMNS = features.NUMERIC_FEATURES + features.CATEGORICAL_FEATURES

APP_COLS = ", ".join(features.APPLICATION_COLUMNS)
DEV_SQL = f"SELECT loan_id, default_flag, issue_d, term_months, {APP_COLS} FROM loan_dev"
MASTER_SQL = f"SELECT loan_id, issue_d, term_months, {APP_COLS} FROM loan_master"


def build_pipeline() -> Pipeline:
    numeric = Pipeline([
        ("impute", SimpleImputer(strategy="median")),
        # Caps at the training 1st/99th percentiles, so an outlier such as
        # DTI = 999 can't extrapolate a PD to ~100%.
        ("clip", features.ClipToTrainingRange()),
        # Scaling puts every feature on the same footing for the solver and
        # makes the coefficients comparable.
        ("scale", StandardScaler()),
    ])
    categorical = Pipeline([
        ("as_text", FunctionTransformer(features.to_category_strings, feature_names_out="one-to-one")),
        # A category never seen in training (a new purpose, say) is all zeros, not an error.
        ("one_hot", OneHotEncoder(handle_unknown="ignore")),
    ])
    prep = ColumnTransformer([
        ("num", numeric, features.NUMERIC_FEATURES),
        ("cat", categorical, features.CATEGORICAL_FEATURES),
    ])
    # No class_weight and no resampling: up-weighting defaults would push every
    # predicted PD up, and the ECL needs PDs that are real probabilities.
    return Pipeline([("prep", prep), ("model", LogisticRegression(max_iter=2000))])


def ks_statistic(y_true, scores) -> float:
    """Largest gap between the cumulative score distributions of defaulters and non-defaulters."""
    fpr, tpr, _ = roc_curve(y_true, scores)
    return float(np.max(tpr - fpr))


def decile_table(y_true, scores) -> pd.DataFrame:
    """Test loans split into ten equal groups by predicted PD: predicted vs observed."""
    df = pd.DataFrame({"y": np.asarray(y_true), "p": np.asarray(scores)})
    # Ranking first gives ten groups of equal size even when PDs tie.
    df["decile"] = pd.qcut(df["p"].rank(method="first"), 10, labels=list(range(1, 11)))
    return (df.groupby("decile", observed=True)
              .agg(loans=("y", "size"), min_pd=("p", "min"), max_pd=("p", "max"),
                   mean_pd=("p", "mean"), defaults=("y", "sum"), default_rate=("y", "mean"))
              .reset_index())


def register(conn, version: str, train: pd.DataFrame, test: pd.DataFrame, m: dict) -> None:
    with conn.cursor() as cur:
        # One active model: scoring always knows which one to use.
        cur.execute("UPDATE model_registry SET active_flag = 'N' WHERE active_flag = 'Y'")
        cur.execute("""
            INSERT INTO model_registry (
              model_version, algorithm, train_from, train_to, test_from, test_to,
              train_rows, test_rows, train_default_rate, test_default_rate, test_mean_pd,
              auc_train, auc_test, gini_test, ks_test, brier_test, features, artifact_file, active_flag)
            VALUES (:version, :algorithm, :train_from, :train_to, :test_from, :test_to,
                    :train_rows, :test_rows, :train_dr, :test_dr, :test_mean_pd,
                    :auc_train, :auc_test, :gini_test, :ks_test, :brier_test, :features, :artifact, 'Y')""",
            version=version,
            algorithm="scikit-learn LogisticRegression (lbfgs, L2, C=1.0), no class weighting",
            train_from=train["issue_d"].min().to_pydatetime(), train_to=train["issue_d"].max().to_pydatetime(),
            test_from=test["issue_d"].min().to_pydatetime(), test_to=test["issue_d"].max().to_pydatetime(),
            train_rows=len(train), test_rows=len(test),
            train_dr=m["train_default_rate"], test_dr=m["test_default_rate"], test_mean_pd=m["test_mean_pd"],
            auc_train=m["auc_train"], auc_test=m["auc_test"], gini_test=m["gini_test"],
            ks_test=m["ks_test"], brier_test=m["brier_test"],
            features=json.dumps({"numeric": features.NUMERIC_FEATURES,
                                 "categorical": features.CATEGORICAL_FEATURES}),
            artifact=f"models/{MODEL_FILE.name}")
    conn.commit()


def score_live_book(conn, model: Pipeline, version: str) -> pd.DataFrame:
    master = features.add_derived_features(read_frame(conn, MASTER_SQL))
    pd_floor = get_setting(conn, "PD_FLOOR")
    master["pd_term"] = model.predict_proba(master[X_COLUMNS])[:, 1]
    master["pd_12m_raw"] = term_to_12m(master["pd_term"], master["term_months"])
    master["pd_12m_orig"] = apply_floor(master["pd_12m_raw"], pd_floor)
    rows = [(float(p), version, int(i)) for p, i in zip(master["pd_12m_orig"], master["loan_id"])]
    with conn.cursor() as cur:
        for start in range(0, len(rows), 25_000):
            cur.executemany("UPDATE loan_master SET pd_12m_orig = :1, pd_model_version = :2 WHERE loan_id = :3",
                            rows[start:start + 25_000])
    conn.commit()
    master.attrs["pd_floor"] = pd_floor
    return master


def calibration_note(m: dict, deciles: pd.DataFrame) -> str:
    """One sentence on ranking and level, written from the computed numbers."""
    gap = (m["test_mean_pd"] - m["test_default_rate"]) * 100
    ranking = ("The ranking holds: the observed default rate rises in every decile."
               if deciles["default_rate"].is_monotonic_increasing
               else "The observed default rate does not rise in every decile.")
    if abs(gap) < 0.5:
        level = "The level is well calibrated on the test vintage."
    else:
        level = (f"The level is {'too low' if gap < 0 else 'too high'} for the test vintage: mean predicted PD "
                 f"{m['test_mean_pd']:.2%} against {m['test_default_rate']:.2%} observed "
                 f"({gap:+.2f} percentage points). A production model would be recalibrated to recent "
                 "vintages or carry a margin of conservatism; this project keeps the model as specified "
                 "and states the gap.")
    return f"{ranking} {level}"


def write_report(version: str, train: pd.DataFrame, test: pd.DataFrame, m: dict,
                 deciles: pd.DataFrame, book: pd.DataFrame, coefs: pd.DataFrame) -> None:
    pct = lambda x: f"{x:.2%}"  # noqa: E731
    floored = int((book["pd_12m_raw"] < book.attrs["pd_floor"]).sum())
    by_grade = book.groupby("grade").agg(loans=("loan_id", "size"), mean_term_pd=("pd_term", "mean"),
                                         mean_pd_12m=("pd_12m_orig", "mean"))
    lines = [
        "# PD model report",
        "",
        f"Generated by `python/train_pd_model.py` on {date.today():%Y-%m-%d}. Model version `{version}`. "
        "Every number below comes from that run.",
        "",
        "## Data",
        "",
        f"- Source: `LOAN_DEV`, {len(train) + len(test):,} closed loans from matured vintages (see `docs/data_profile.md`).",
        f"- Training: loans issued {train['issue_d'].min():%b %Y} to {train['issue_d'].max():%b %Y}, "
        f"{len(train):,} loans, default rate {pct(m['train_default_rate'])}.",
        f"- Out-of-time test: loans issued in {TEST_YEAR}, {len(test):,} loans, default rate {pct(m['test_default_rate'])}. "
        "The model never sees this period while training, so the test shows how it holds up on a later vintage.",
        "- Target: `default_flag` = 1 for charged off, 0 for fully paid, over the loan's full term.",
        "",
        "## Features",
        "",
        "Application-time information only:",
        "",
        f"- Numeric (median imputation, capped at the training 1st and 99th percentiles, then standard scaling): {', '.join(f'`{c}`' for c in features.NUMERIC_FEATURES)}.",
        f"- Categorical (one-hot, missing as its own category): {', '.join(f'`{c}`' for c in features.CATEGORICAL_FEATURES)}.",
        "- Derived: `fico` = midpoint of `fico_range_low` and `fico_range_high`; `credit_history_months` = "
        "`issue_d` minus `earliest_cr_line`; `log_annual_inc` and `log_revol_bal` = log(1 + x).",
        "",
        "Excluded because they are only known after the loan has run (leakage); "
        "`prepare_data.py` and this script assert none of them is a model input:",
        "",
        ", ".join(f"`{c}`" for c in sorted(features.LEAKAGE_COLUMNS))
        + ", and every column starting with " + ", ".join(f"`{p}`" for p in features.LEAKAGE_PREFIXES) + ".",
        "",
        "## Method",
        "",
        "scikit-learn `Pipeline`: `ColumnTransformer` (numeric and categorical branches) feeding a "
        "`LogisticRegression` (lbfgs, L2 penalty, C = 1.0). No class weighting and no resampling, because "
        "re-weighting defaults would inflate every predicted PD and the ECL needs real probabilities.",
        "",
        "## Out-of-time results",
        "",
        markdown.table(["Metric", "Training", f"Test ({TEST_YEAR})"], [
            ["AUC", f"{m['auc_train']:.4f}", f"{m['auc_test']:.4f}"],
            ["Gini (2 x AUC - 1)", f"{2 * m['auc_train'] - 1:.4f}", f"{m['gini_test']:.4f}"],
            ["KS", "", f"{m['ks_test']:.4f}"],
            ["Brier score", "", f"{m['brier_test']:.4f}"],
            ["Mean predicted PD (term)", f"{m['train_mean_pd']:.4f}", f"{m['test_mean_pd']:.4f}"],
            ["Observed default rate", f"{m['train_default_rate']:.4f}", f"{m['test_default_rate']:.4f}"],
        ], right=[1, 2]),
        "",
        f"Test AUC {m['auc_test']:.4f} is below the {MAX_TEST_AUC:.2f} leakage alarm the script enforces.",
        "",
        calibration_note(m, deciles),
        "",
        "### Calibration by score decile (test set)",
        "",
        "Decile 1 holds the 10% of test loans with the lowest predicted PD.",
        "",
        markdown.table(["Decile", "Loans", "PD range", "Mean predicted PD", "Observed default rate", "Defaults"],
                       [[int(r.decile), f"{r.loans:,}", f"{r.min_pd:.4f}-{r.max_pd:.4f}", pct(r.mean_pd),
                         pct(r.default_rate), f"{int(r.defaults):,}"] for r in deciles.itertuples()],
                       right=[1, 3, 4, 5]),
        "",
        "### Largest coefficients (on scaled or one-hot inputs)",
        "",
        markdown.table(["Feature", "Coefficient"],
                       [[f"`{r.feature}`", f"{r.coef:+.4f}"] for r in coefs.itertuples()], right=[1]),
        "",
        "## Live book: origination PD",
        "",
        f"All {len(book):,} loans in `LOAN_MASTER` were scored with their application data. The model's "
        "term PD was converted to a 12-month PD with a constant hazard, "
        "PD_12m = 1 - (1 - PD_term)^(12/T), then floored at "
        f"PD_FLOOR = {book.attrs['pd_floor']:g} from the XML config ({floored:,} loans were raised to the floor).",
        "",
        markdown.table(["Grade", "Loans", "Mean term PD", "Mean pd_12m_orig"],
                       [[g, f"{r.loans:,}", pct(r.mean_term_pd), pct(r.mean_pd_12m)]
                        for g, r in zip(by_grade.index, by_grade.itertuples())], right=[1, 2, 3]),
        "",
        "## Limitations",
        "",
        "- The target is default over the full term; the 12-month PD comes from a constant-hazard assumption, "
        "while real default hazards peak in the first years of a loan.",
        "- Monthly scoring swaps today's FICO into a model trained on origination FICO (a stated simplification).",
        "- Matured vintages end in 2015, so the model reflects 2007-2015 underwriting and economic conditions.",
        "",
    ]
    (DOCS_DIR / "model_report.md").write_text("\n".join(lines), encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id", type=int, help="BATCH_RUN run id to log under (default: a new one)")
    args = parser.parse_args()

    features.assert_no_leakage(features.model_inputs())

    with connect() as conn:
        with batch_step(conn, "TRAIN_PD_MODEL", args.run_id) as step:
            dev = features.add_derived_features(read_frame(conn, DEV_SQL))
            dev["issue_d"] = pd.to_datetime(dev["issue_d"])
            train = dev[dev["issue_d"] <= TRAIN_LAST_ISSUE]
            test = dev[dev["issue_d"].dt.year == TEST_YEAR]
            log.info("training on %d loans (issued to %s), testing on %d loans issued in %d",
                     len(train), f"{TRAIN_LAST_ISSUE:%Y-%m}", len(test), TEST_YEAR)

            model = build_pipeline().fit(train[X_COLUMNS], train["default_flag"])
            p_train = model.predict_proba(train[X_COLUMNS])[:, 1]
            p_test = model.predict_proba(test[X_COLUMNS])[:, 1]
            auc_test = roc_auc_score(test["default_flag"], p_test)
            m = {
                "auc_train": float(roc_auc_score(train["default_flag"], p_train)),
                "auc_test": float(auc_test),
                "gini_test": float(2 * auc_test - 1),
                "ks_test": ks_statistic(test["default_flag"], p_test),
                "brier_test": float(brier_score_loss(test["default_flag"], p_test)),
                "train_default_rate": float(train["default_flag"].mean()),
                "test_default_rate": float(test["default_flag"].mean()),
                "train_mean_pd": float(p_train.mean()),
                "test_mean_pd": float(p_test.mean()),
            }
            log.info("test AUC %.4f, Gini %.4f, KS %.4f, Brier %.4f",
                     m["auc_test"], m["gini_test"], m["ks_test"], m["brier_test"])
            log.info("test set: mean predicted PD %.4f vs observed default rate %.4f",
                     m["test_mean_pd"], m["test_default_rate"])
            if m["auc_test"] > MAX_TEST_AUC:
                raise SystemExit(f"test AUC {m['auc_test']:.4f} is above {MAX_TEST_AUC}: "
                                 "look for leakage before going on")

            deciles = decile_table(test["default_flag"], p_test)
            names = model.named_steps["prep"].get_feature_names_out()
            coefs = (pd.DataFrame({"feature": names, "coef": model.named_steps["model"].coef_[0]})
                       .assign(size=lambda d: d["coef"].abs()).nlargest(12, "size"))

            version = f"PD_LR_{datetime.now():%Y%m%d_%H%M%S}"
            MODELS_DIR.mkdir(exist_ok=True)
            joblib.dump(model, MODEL_FILE)
            METADATA_FILE.write_text(json.dumps({
                "model_version": version,
                "artifact": f"models/{MODEL_FILE.name}",
                "features": {"numeric": features.NUMERIC_FEATURES, "categorical": features.CATEGORICAL_FEATURES},
                "training_issue_dates": [f"{train['issue_d'].min():%Y-%m-%d}", f"{train['issue_d'].max():%Y-%m-%d}"],
                "test_issue_dates": [f"{test['issue_d'].min():%Y-%m-%d}", f"{test['issue_d'].max():%Y-%m-%d}"],
                "rows": {"train": len(train), "test": len(test)},
                "metrics": {k: round(v, 6) for k, v in m.items()},
                "deciles": [{k: (round(float(v), 6) if k != "decile" else int(v)) for k, v in row.items()}
                            for row in deciles.to_dict("records")],
            }, indent=2) + "\n", encoding="utf-8", newline="\n")
            register(conn, version, train, test, m)
            step.rows = len(dev)
            step.message = (f"{version}: test AUC {m['auc_test']:.4f}, Gini {m['gini_test']:.4f}, "
                            f"KS {m['ks_test']:.4f}, Brier {m['brier_test']:.4f}")

        with batch_step(conn, "SCORE_LIVE_BOOK", step.run_id) as score_step:
            book = score_live_book(conn, model, version)
            score_step.rows = len(book)
            score_step.message = (f"{len(book)} loans scored with {version}; "
                                  f"mean pd_12m_orig {book['pd_12m_orig'].mean():.4f}")
        log.info("live book: %d loans scored, mean pd_12m_orig %.4f", len(book), book["pd_12m_orig"].mean())

    write_report(version, train, test, m, deciles, book, coefs)
    print(f"\nModel {version}")
    print(f"  test AUC {m['auc_test']:.4f}   Gini {m['gini_test']:.4f}   KS {m['ks_test']:.4f}   Brier {m['brier_test']:.4f}")
    print(f"  test mean predicted PD {m['test_mean_pd']:.4f}   observed default rate {m['test_default_rate']:.4f}")
    print("\n  decile  loans  mean_pd  default_rate")
    for r in deciles.itertuples():
        print(f"  {int(r.decile):>6}  {r.loans:>5}  {r.mean_pd:.4f}   {r.default_rate:.4f}")


if __name__ == "__main__":
    main()
