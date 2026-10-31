"""Pandas port of the Lab 2 feature logic, so it can be unit tested in CI.

glue-scripts/feature_engineer.py computes these features in PySpark for the
pipeline. PySpark is awkward to test in isolation, so the same definitions live
here as plain functions over small DataFrames. tests/test_data.py checks this
port against what the Glue job actually wrote.

Every window is measured backwards from `snapshot_date` (T in the Lab 2 job),
never from today(). "In the N days before T" means 0 <= days_before_t < N.
Rows after T are ignored: they belong to the label, not the features.
"""

import pandas as pd

N_CATEGORIES = 8.0              # denominator for category_diversity_score
NO_PURCHASE_RECENCY = 999.0     # days_since_last_purchase with no purchases


def _history(transactions: pd.DataFrame, snapshot_date) -> pd.DataFrame:
    """Rows on or before T, with purchase_date parsed and days_before_t added."""
    cutoff = pd.Timestamp(snapshot_date).normalize()
    history = transactions.copy()
    history["purchase_date"] = pd.to_datetime(history["purchase_date"]).dt.normalize()
    history = history[history["purchase_date"] <= cutoff]
    history["days_before_t"] = (cutoff - history["purchase_date"]).dt.days
    return history


def compute_recency_features(transactions: pd.DataFrame,
                             snapshot_date,
                             customer_ids: pd.DataFrame = None) -> pd.DataFrame:
    """days_since_last_purchase and customer_tenure_days, one row per customer.

    Pass `customer_ids` to keep customers with no purchases: they get
    NO_PURCHASE_RECENCY and a tenure of 0.
    """
    history = _history(transactions, snapshot_date)
    days = history.groupby("customer_id")["days_before_t"]
    features = pd.DataFrame({
        "days_since_last_purchase": days.min().astype(float),
        "customer_tenure_days": days.max().astype(float),
    }).reset_index()

    if customer_ids is not None:
        features = customer_ids[["customer_id"]].merge(features, on="customer_id", how="left")
        features = features.fillna({"days_since_last_purchase": NO_PURCHASE_RECENCY,
                                    "customer_tenure_days": 0.0})
    return features


def compute_frequency_features(transactions: pd.DataFrame, snapshot_date) -> pd.DataFrame:
    """purchase_frequency_30d/_90d/_180d: orders in the N days before T."""
    history = _history(transactions, snapshot_date)
    counts = pd.DataFrame({
        f"purchase_frequency_{n}d": (history["days_before_t"] < n).astype(float)
        for n in (30, 90, 180)
    })
    counts["customer_id"] = history["customer_id"]
    return counts.groupby("customer_id").sum().reset_index()


def compute_monetary_features(transactions: pd.DataFrame, snapshot_date) -> pd.DataFrame:
    """avg_order_value, total_spend_90d, total_lifetime_value, avg_basket_size_6m.

    avg_basket_size_6m is ITEMS per order over the last 180 days, not dollars,
    and 0.0 for a customer with no orders in that window.
    """
    history = _history(transactions, snapshot_date)
    history["_spend_90d"] = history["order_value"].where(history["days_before_t"] < 90, 0.0)
    in_180d = history["days_before_t"] < 180
    history["_items_180d"] = history["num_items"].where(in_180d, 0)
    history["_orders_180d"] = in_180d.astype(int)

    grouped = history.groupby("customer_id")
    orders_180d = grouped["_orders_180d"].sum().clip(lower=1)
    return pd.DataFrame({
        "avg_order_value": grouped["order_value"].mean(),
        "total_spend_90d": grouped["_spend_90d"].sum(),
        "total_lifetime_value": grouped["order_value"].sum(),
        "avg_basket_size_6m": grouped["_items_180d"].sum() / orders_180d,
    }).reset_index()


def compute_behavioral_features(transactions: pd.DataFrame) -> pd.DataFrame:
    """category_diversity_score and online_to_store_ratio over the rows given.

    'unknown' is what the transform imputes for a missing category, so it is
    not counted: counting it would push the score above 1.0.
    """
    frame = transactions.assign(
        _known_category=transactions["product_category"].where(
            transactions["product_category"] != "unknown"),
        _online=(transactions["channel"] == "online").astype(float),
    )
    grouped = frame.groupby("customer_id")
    return pd.DataFrame({
        "category_diversity_score": grouped["_known_category"].nunique() / N_CATEGORIES,
        "online_to_store_ratio": grouped["_online"].mean(),
    }).reset_index()


def build_churn_feature_set(customers: pd.DataFrame,
                            transactions: pd.DataFrame,
                            snapshot_date) -> pd.DataFrame:
    """Every model feature for every row of `customers`, one row per customer.

    Nulls: a customer with no purchases on or before T has no value for any
    aggregate, so counts, spend and ratios are 0.0 and recency is
    NO_PURCHASE_RECENCY. No feature is NaN in the output.
    """
    history = _history(transactions, snapshot_date)
    features = compute_recency_features(history, snapshot_date, customers[["customer_id"]])
    for extra in (compute_frequency_features(history, snapshot_date),
                  compute_monetary_features(history, snapshot_date),
                  compute_behavioral_features(history)):
        features = features.merge(extra, on="customer_id", how="left")

    feature_columns = [c for c in features.columns if c != "customer_id"]
    features[feature_columns] = features[feature_columns].fillna(0.0)
    return customers.merge(features, on="customer_id", how="left")
