"""Your Lab 3 churn model, packaged for the Lab 4 pipeline.

The pipeline's training job runs train_sagemaker.py (beside this file; do not
edit it), which imports this module and calls train(). Everything the job needs
goes through the three names below.

Contract (train_sagemaker.py checks it in the first seconds of the job):

    FEATURE_COLUMNS   list[str]   model input columns, in order
    LABEL             str         "churn_label"
    train(df, seed=42) -> (xgboost.Booster, dict)

`df` is the full labeled feature table: every column of the Lab 2 output,
including `loyalty_tier` for slice evaluation. It is already loaded. Do not
query Athena or the Feature Store from here; the training container stages
the data and has no business making service calls for its input.

The metrics dict must include the four numbers the CI gate in
tests/test_model.py reads:

    precision_top10, recall_top10      gated at 0.50 / 0.25
    lift_ci_low, lift_ci_high          bootstrap 95% CI on AUC lift over the
                                       recency-only baseline; lift_ci_low > 0

What runs in the container: the SageMaker XGBoost 1.7-1 image ships pandas,
numpy, scikit-learn, xgboost and boto3. It does NOT ship mlflow or sagemaker,
so neither is imported here. MLflow tracking stays in the Lab 3 script.

Only this directory (models/churn/) is uploaded to the training job, so the
functions below are copied from churn_training_skeleton.py, not imported.

Test it locally before pushing:

    python models/churn/train_sagemaker.py \
        --train-channel <dir containing your features CSV or Parquet> \
        --model-dir /tmp/model --output-data-dir /tmp/out
"""

# Keeps Lab 3 annotations like `-> tuple[np.ndarray, np.ndarray]` from being
# evaluated, whatever Python the training container runs.
from __future__ import annotations

from datetime import datetime

import numpy as np
import pandas as pd
import xgboost as xgb
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

# Must match the columns the Lab 3 model was trained on, in the same order.
FEATURE_COLUMNS = [
    "days_since_last_purchase",
    "customer_tenure_days",
    "purchase_frequency_30d",
    "purchase_frequency_90d",
    "purchase_frequency_180d",
    "avg_order_value",
    "total_spend_90d",
    "total_lifetime_value",
    "avg_basket_size_6m",
    "category_diversity_score",
    "online_to_store_ratio",
]

LABEL = "churn_label"

SLICE_COLUMN = "loyalty_tier"
BASELINE_FEATURE = "days_since_last_purchase"

# The Lab 3 graded run (xgb-d6-eta0.03-r600-final). The training job takes no
# hyperparameter arguments, so they live here. scale_pos_weight is computed
# from the training split in train_model().
HYPERPARAMETERS = {
    "max_depth": 6,
    "eta": 0.03,
    "min_child_weight": 5,
    "subsample": 0.8,
    "colsample_bytree": 0.8,
}
NUM_ROUND = 600
EARLY_STOPPING_ROUNDS = 20

EVAL_THRESHOLDS = {
    "precision_top10": 0.50,   # Minimum precision @ top 10% scored customers
    "recall_top10":    0.25,   # Minimum recall @ top 10% scored customers
}

# No absolute AUC threshold, on purpose: AUC is reported, not gated. The
# baseline gate is an interval: the 95% CI on the lift must exclude zero.
BOOTSTRAP_N = 2000
BOOTSTRAP_SEED = 42

MIN_SLICE_POSITIVES = 30   # below this a slice is too small to conclude from
SLICE_RECALL_GAP = 0.10    # flag a slice whose recall is >10pp below aggregate


def preprocess_features(df: pd.DataFrame) -> tuple[np.ndarray, np.ndarray, pd.Series]:
    """Return (X, y, tiers), row-aligned.

    Sorted by customer_id first. Lab 3 got its row order from the Athena
    ORDER BY; here it would otherwise come from Glue's part files, and the row
    order reaching train_test_split determines the split.

    Missing values stay NaN, as in Lab 3: XGBoost learns a default branch for
    them, and a -1 sentinel would collide with legitimate values.
    """
    df = df.dropna(subset=[LABEL]).sort_values("customer_id").reset_index(drop=True)
    X = df[FEATURE_COLUMNS].astype(float).values
    y = df[LABEL].values.astype(int)
    return X, y, df[SLICE_COLUMN]


def train_model(X_train: np.ndarray,
                y_train: np.ndarray,
                X_val: np.ndarray,
                y_val: np.ndarray,
                seed: int) -> xgb.Booster:
    """Train the XGBoost churn model."""
    dtrain = xgb.DMatrix(X_train, label=y_train, feature_names=FEATURE_COLUMNS)
    dval = xgb.DMatrix(X_val, label=y_val, feature_names=FEATURE_COLUMNS)

    # Class imbalance, computed from the training split rather than hardcoded.
    spw = float((y_train == 0).sum() / max((y_train == 1).sum(), 1))

    params = {
        # eval_metric ORDER MATTERS: XGBoost early-stops on the LAST metric in
        # this list, so "auc" stays last.
        "objective": "binary:logistic",
        "eval_metric": ["logloss", "auc"],
        **HYPERPARAMETERS,
        "scale_pos_weight": spw,
        "seed": seed,
        "verbosity": 1,
    }

    print(f"Training XGBoost with params: {params}")

    return xgb.train(
        params=params,
        dtrain=dtrain,
        num_boost_round=NUM_ROUND,
        evals=[(dtrain, "train"), (dval, "validation")],
        early_stopping_rounds=EARLY_STOPPING_ROUNDS,
        verbose_eval=25,
    )


def train_recency_baseline(X_train: np.ndarray,
                           y_train: np.ndarray,
                           X_val: np.ndarray) -> np.ndarray:
    """Train the recency-only baseline and score the validation split.

    A model over days_since_last_purchase ALONE, on the same rows as the full
    model. The question is whether the features beat the rule the business
    already has for free, not whether they beat a coin flip.
    """
    i = FEATURE_COLUMNS.index(BASELINE_FEATURE)
    dtr = xgb.DMatrix(X_train[:, [i]], label=y_train, feature_names=[BASELINE_FEATURE])
    dva = xgb.DMatrix(X_val[:, [i]], feature_names=[BASELINE_FEATURE])
    spw = float((y_train == 0).sum() / max((y_train == 1).sum(), 1))
    params = {
        "objective": "binary:logistic", "eval_metric": "auc",
        "max_depth": 4, "eta": 0.1, "subsample": 0.9,
        "colsample_bytree": 0.9, "scale_pos_weight": spw, "seed": 42,
    }
    return xgb.train(params, dtr, num_boost_round=200).predict(dva)


def bootstrap_lift_ci(y_true: np.ndarray,
                      proba: np.ndarray,
                      baseline_proba: np.ndarray,
                      n: int = BOOTSTRAP_N,
                      seed: int = BOOTSTRAP_SEED,
                      alpha: float = 0.05) -> tuple[float, float]:
    """Percentile CI for (model AUC - baseline AUC), by resampling the val set.

    PAIRED: each replicate resamples row indices once and scores BOTH models on
    those same rows, so the interval is on the difference. The seed is fixed so
    the same split always produces the same verdict.
    """
    rng = np.random.default_rng(seed)
    y_true = np.asarray(y_true)
    idx = np.arange(len(y_true))
    diffs = []
    for _ in range(n):
        s = rng.choice(idx, size=len(idx), replace=True)
        ys = y_true[s]
        if len(np.unique(ys)) < 2:
            continue
        diffs.append(roc_auc_score(ys, proba[s]) - roc_auc_score(ys, baseline_proba[s]))
    if len(diffs) < n // 2:
        raise ValueError(
            "Too few usable bootstrap replicates to form a confidence interval. "
            "The validation set is too small or too imbalanced to support this gate."
        )
    d = np.sort(diffs)
    return float(np.quantile(d, alpha / 2)), float(np.quantile(d, 1 - alpha / 2))


def evaluate_model(model: xgb.Booster,
                   X_val: np.ndarray,
                   y_val: np.ndarray,
                   baseline_proba: np.ndarray) -> dict:
    """Evaluate the model against the gates. Raises ValueError if one fails.

    Raising is what fails the training step, so a model that misses a gate is
    never registered.
    """
    dval = xgb.DMatrix(X_val, feature_names=FEATURE_COLUMNS)
    y_pred_proba = model.predict(dval)

    auc_roc = roc_auc_score(y_val, y_pred_proba)

    top10_threshold = np.percentile(y_pred_proba, 90)
    top10_mask = y_pred_proba >= top10_threshold
    precision_top10 = y_val[top10_mask].mean() if top10_mask.sum() > 0 else 0.0
    recall_top10 = y_val[top10_mask].sum() / y_val.sum() if y_val.sum() > 0 else 0.0

    baseline_auc = roc_auc_score(y_val, baseline_proba)
    lift_ci_low, lift_ci_high = bootstrap_lift_ci(y_val, y_pred_proba, baseline_proba)

    metrics = {
        "auc_roc": round(float(auc_roc), 4),
        "precision_top10": round(float(precision_top10), 4),
        "recall_top10": round(float(recall_top10), 4),
        "auc_vs_baseline": round(float(auc_roc - baseline_auc), 4),
        "baseline_auc": round(float(baseline_auc), 4),
        "baseline_auc_roc": round(float(baseline_auc), 4),
        "lift_ci_low": round(float(lift_ci_low), 4),
        "lift_ci_high": round(float(lift_ci_high), 4),
        "positive_rate_val": round(float(y_val.mean()), 4),
        "n_val_samples": int(len(y_val)),
        "eval_timestamp": datetime.utcnow().isoformat(),
    }

    failures = []
    for metric, threshold in EVAL_THRESHOLDS.items():
        status = "PASS" if metrics[metric] >= threshold else "FAIL"
        print(f"  {metric:25s}: {metrics[metric]:.4f}  (threshold: {threshold:.4f})  {status}")
        if metrics[metric] < threshold:
            failures.append(f"{metric}={metrics[metric]:.4f} < {threshold}")

    ci_status = "PASS" if lift_ci_low > 0 else "FAIL"
    print(f"  {'auc_lift 95% CI':25s}: [{lift_ci_low:.4f}, {lift_ci_high:.4f}]"
          f"  (must exclude 0)  {ci_status}")
    if lift_ci_low <= 0:
        failures.append(
            f"auc_lift 95% CI [{lift_ci_low:.4f}, {lift_ci_high:.4f}] includes "
            f"zero - no evidence the model beats the recency-only baseline")

    if failures:
        raise ValueError(
            f"Model failed evaluation thresholds: {'; '.join(failures)}. "
            f"Do not promote to Model Registry."
        )

    return metrics


def evaluate_slices(model: xgb.Booster,
                    X_val: np.ndarray,
                    y_val: np.ndarray,
                    slice_column: pd.Series) -> dict:
    """Per-tier results, keyed by tier, for tests/test_fairness.py.

    Recall uses the SAME top-10% cutoff as the aggregate metric: retention
    contacts the top 10% of all customers, not the top 10% of each tier.

    Undefined values are None, not NaN: this dict is written to
    evaluation_metrics.json, and NaN is not valid JSON.
    """
    dval = xgb.DMatrix(X_val, feature_names=FEATURE_COLUMNS)
    y_pred_proba = model.predict(dval)
    top10_mask = y_pred_proba >= np.percentile(y_pred_proba, 90)
    aggregate_recall = y_val[top10_mask].sum() / y_val.sum()

    slices = {}
    for slice_value in sorted(slice_column.unique()):
        mask = (slice_column == slice_value).values
        y_s, p_s, flagged = y_val[mask], y_pred_proba[mask], top10_mask[mask]
        positives = int(y_s.sum())
        # AUC is undefined for a single-class slice.
        auc_s = round(float(roc_auc_score(y_s, p_s)), 4) if 0 < positives < len(y_s) else None
        recall_s = round(float(y_s[flagged].sum() / positives), 4) if positives else None
        slices[str(slice_value)] = {
            "n": int(mask.sum()),
            "positives": positives,
            "auc": auc_s,
            "recall_top10": recall_s,
            "too_small": positives < MIN_SLICE_POSITIVES,
            "recall_below_aggregate": recall_s is not None
                                      and bool(recall_s < aggregate_recall - SLICE_RECALL_GAP),
        }
    return slices


def train(df: pd.DataFrame, seed: int = 42):
    """Train the churn model on `df` and return (booster, metrics)."""
    X, y, tiers = preprocess_features(df)

    # test_size=0.30 matches Lab 3; the bootstrap CI is calibrated on a test
    # set that size. The tiers split in the same call so each row keeps its own.
    X_train, X_val, y_train, y_val, _, tier_val = train_test_split(
        X, y, tiers, test_size=0.30, random_state=seed, stratify=y
    )
    tier_val = tier_val.reset_index(drop=True)
    print(f"Train: {len(X_train):,} | Validation: {len(X_val):,}")

    model = train_model(X_train, y_train, X_val, y_val, seed)
    baseline_proba = train_recency_baseline(X_train, y_train, X_val)
    metrics = evaluate_model(model, X_val, y_val, baseline_proba)
    metrics["slice_results"] = evaluate_slices(model, X_val, y_val, tier_val)
    metrics["best_iteration"] = int(model.best_iteration)

    return model, metrics
