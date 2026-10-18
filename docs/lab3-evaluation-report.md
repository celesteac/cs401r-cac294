# Lab 3 — Churn Model Evaluation Report

_TODO: fill from the graded run (`docs/lab3-evidence/evaluation_metrics.json`). Every number here must match that file,
the MLflow run and the Model Registry metadata._

## Results

| Metric | Value | Threshold |
|---|---|---|
| AUC-ROC (test set) | | report only, no fixed threshold |
| Precision @ top 10% | | ≥ 0.50 |
| Recall @ top 10% | | ≥ 0.25 |
| AUC lift over recency-only baseline | | 95% CI must exclude zero |

## Baseline comparison

_TODO: baseline AUC, full AUC, lift, 95% CI, how the CI was computed._

## Confusion matrix

_TODO: embed `lab3-evidence/confusion-matrix.png`, state the threshold._

## Feature importance

_TODO: embed `lab3-evidence/feature-importance.png`._

## Slice evaluation by loyalty tier

_TODO: table from `lab3-evidence/slice-evaluation.csv`, weakest tier, too-small tiers._

## Provenance

_TODO: XGBoost version, data source, split, seed, run name, MLflow run, registry version._

---

## Notes (working notes — delete this section before submitting)

### Provenance facts

- Data: Feature Store offline store via Athena, table
  `sagemaker_featurestore.northstar_dev_customer_features_1792273222`, 9,999 customers, 22.0% churn.
  The graded run's `Athena QueryExecutionId` goes in `train-final.log`.
- Split: stratified 70/30, `random_state=42` -> 6,999 train / 3,000 test (660 test churners). Query has
  `ORDER BY customer_id`, so the split is reproducible.
- XGBoost **3.4.1** (local). Lab reference is 3.2.0 (AUC 0.7696, baseline 0.7233, lift +0.0464, CI [0.0254, 0.0670],
  P@10% 0.6833, R@10% 0.3106). Mention the version difference when comparing.
- Missing values: 0 in the current data; left as NaN by design (XGBoost native handling).
- `churn_risk_score` excluded from inputs (if a run includes it, report with and without).

### Trial run numbers (default params) — replace with the graded run

- AUC 0.7806 · P@10% 0.7033 · R@10% 0.3197 · baseline AUC 0.7226 · lift +0.058 · CI [0.0383, 0.0774]
- Params: max_depth 6, eta 0.1, num_round 200 (early-stopped ~round 30), min_child_weight 5, subsample 0.8,
  colsample_bytree 0.8, scale_pos_weight 3.545 (computed), seed 42.

### MLflow runs so far (experiment `northstar-churn`)

| Run | AUC | Lift [95% CI] | P@10% | R@10% | Best round |
|---|---|---|---|---|---|
| xgb-d6-eta0.1 | 0.7806 | +0.0580 [0.0383, 0.0774] | 0.7033 | 0.3197 | 10 |
| xgb-d3-eta0.1 | 0.7785 | +0.0559 [0.0372, 0.0747] | 0.7233 | 0.3288 | 36 |
| xgb-d6-eta0.03-r600 | 0.7857 | +0.0631 [0.0441, 0.0824] | 0.7300 | 0.3318 | 16 |
| xgb-d3-eta0.03-r600 | 0.7735 | +0.0509 [0.0307, 0.0719] | 0.6566* | 0.3621* | 3 |

- Leading candidate for the graded run: **depth 6, eta 0.03, 600 rounds** (best on AUC, lift, precision).
- *Tie artifact: that model flagged 364 customers (12.1%) at the `>= 90th percentile` cutoff, so its P/R are not "top 10%".
  If the graded model has many tied scores, report the actual number flagged.
- Each run logs params (incl. resolved scale_pos_weight, seed, early_stopping_rounds, xgboost_version, data_source),
  all numeric metrics under the same keys as `evaluation_metrics.json`, `best_iteration`, and the plots and slice CSV as
  artifacts (`s3://<bucket>/artifacts/mlflow/...`).

### Baseline / CI method (for the "Baseline comparison" section)

- Baseline = XGBoost on `days_since_last_purchase` alone, same train rows, scored on the same test rows.
  Not a constant predictor (that would have AUC 0.5 by construction).
- CI = **paired** bootstrap: 2,000 resamples of the test rows with replacement (seed 42). Each resample scores both
  models on the same rows; take the 2.5th and 97.5th percentiles of (full AUC − baseline AUC). Resampling the two
  models independently would inflate the interval.

### Confusion matrix — trial run

- Threshold = top-10% cutoff, p ≥ 0.636 (the same cutoff as the precision/recall gates, which is the actual retention decision).
- TP 211 · FP 89 · FN 449 · TN 2,251. 211/300 flagged = precision 0.7033; 211/660 churners = recall 0.3197.
- Recall ceiling: 300 contacts can catch at most 300 of 660 churners = 0.45. The 449 FN are mostly unavoidable at a 10% budget.

### Feature importance — trial run (gain)

days_since_last_purchase 58.7 · purchase_frequency_180d 56.6 · purchase_frequency_30d 22.2 · avg_order_value 17.4 ·
purchase_frequency_90d 14.2 · total_lifetime_value 13.6 · avg_basket_size_6m 12.8 · category_diversity_score 12.4 ·
total_spend_90d 11.2 · online_to_store_ratio 9.4 · customer_tenure_days 8.7
(Gain chosen over split count; the plot shows unused features as 0.)

### Slice evaluation — trial run (aggregate recall@10% = 0.3197)

| Tier | n | Churners | AUC | Recall@10% | Recall SE | Too small | Recall >10pp below aggregate |
|---|---|---|---|---|---|---|---|
| Bronze | 1,071 | 361 | 0.7609 | 0.4349 | 0.026 | no | no |
| Gold | 483 | 52 | 0.7375 | 0.1346 | 0.047 | no | yes |
| Platinum | 307 | 21 | 0.8536 | 0.0952 | 0.064 | **yes** | yes |
| Silver | 1,139 | 226 | 0.7079 | 0.1991 | 0.027 | no | yes |

- **Weakest tier: Silver** (lowest AUC, 0.7079). n = 1,139 and 226 churners, so this is a solid result.
- **Platinum is too small to conclude from**: 307 customers but only 21 churners (rule: < 30 churners, set by
  `--min-slice-positives`). Its AUC of 0.85 is the highest, consistent with the lab's note that Platinum is the strongest
  slice, but with 21 positives the recall SE is ±0.06.
- "Too small" is based on **churners, not n**: AUC and recall are computed over the positives. At 30 positives the recall
  SE is ~0.08, about the size of the 10pp gap being flagged.
- Recall uses the **shared** top-10% cutoff, so low Gold/Silver recall is mostly a ranking effect: the contact list is
  dominated by Bronze customers, not a sign the model is bad within those tiers (within-tier AUC is fine).
