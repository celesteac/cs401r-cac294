task 3 - path c - agent

# Lab 3 — Model Design

**Track:** C — Customer Service Agent (Amazon Bedrock AgentCore)

<!-- ~700 words across the four sections below, not counting the track line. -->

## 1. Churn model

_TODO: why gradient boosting over logistic regression or a neural network for this dataset; what would make me switch._

## 2. What the features bought us

_TODO: recency-only baseline vs full model with numbers and the CI; which features carried signal, which were decorative._

## 3. LLM system

_TODO: why an agent over a simpler pipeline; primary production risk; why the $50 cap is in three places and which one I'd trust alone._

## 4. What I would do differently

_TODO: a specific architectural or evaluation change with 10x time or data._

---

## Notes (working notes — delete this section before submitting)

### Facts about the dataset (for section 1)

- 9,999 customers, one labeled row each, in Feature Group `northstar-dev-customer-features`
  (offline store table `sagemaker_featurestore.northstar_dev_customer_features_1792273222`). No duplicate records.
- Churn rate 22.0% (2,200 positives). Split 70/30 stratified, seed 42: **6,999 train / 3,000 test** (660 test churners).
- 13 features in the Feature Group; **11 used as model inputs**. Excluded: `churn_risk_score` (pure recency
  heuristic, effectively the baseline) and `loyalty_tier` (slice column only; correlates with spend, so using it
  would make the per-tier check circular). `churn_label` and `customer_id` are never inputs.
- Tier mix (all 9,999): Silver 3,862 · Bronze 3,529 · Gold 1,664 · Platinum 944.
- Tabular, mixed scales, skewed spend features -> trees need no scaling and handle interactions natively.
- Small dataset for a neural net (7k training rows, 11 features).
- Interpretability: gain-based feature importance is available directly from the booster (see section 2 notes).

### Modeling choices made so far (for section 1)

- XGBoost **3.4.1** locally (lab reference was 3.2.0; the SageMaker container is 1.7). Small metric differences vs the
  reference are expected from the version alone.
- `scale_pos_weight` = negatives / positives from the training split = **3.545** (not hardcoded; matches the reference).
  Rebalances the loss so each class contributes equally.
- Missing values left as **NaN** (not a -1 sentinel, not median imputation): XGBoost learns a default branch for
  missing values at each split, so missingness can carry signal without colliding with real values. The current data
  has 0 missing feature values, so this choice does not change today's metrics.
- Early stopping on validation **AUC** (kept last in `eval_metric`), patience 20. With the defaults (depth 6, eta 0.1)
  the best round was **10** (training stopped at 30 of 200), so the model peaks almost immediately. That's why the
  MLflow runs vary depth and learning rate (see the experiment table below).
- Hyperparameters, seed and early-stopping patience are all CLI arguments (no literals in the training call).

### Baseline vs full model (for section 2) — GRADED RUN `xgb-d6-eta0.03-r600-final`

| | Value |
|---|---|
| Full model AUC | **0.7857** |
| Recency-only baseline AUC | **0.7226** |
| Lift | **+0.0631** (≈ 23% of the way from the baseline to a perfect ranker: 0.0631 / (1 − 0.7226)) |
| 95% CI on lift (paired bootstrap, 2,000 reps) | **[0.0441, 0.0824]**, excludes 0 |
| Precision @ top 10% | 0.7300 (vs a 22% base rate, ~3.3× better than random contact) |
| Recall @ top 10% | 0.3318 (ceiling ≈ 300 / 660 = 0.45, so ~74% of what is reachable) |

Params: max_depth 6, eta 0.03, num_round 600 (best iteration 16), min_child_weight 5, subsample 0.8,
colsample_bytree 0.8, scale_pos_weight 3.545, seed 42. MLflow run dfc0f14a…, registry version 2.
Compared with the lab reference (XGBoost 3.2.0, default-ish params): AUC 0.7696, lift +0.0464 [0.0254, 0.0670].

### MLflow experiment `northstar-churn` — runs so far (sections 1 and 2)

All Athena, XGBoost 3.4.1, same split, scale_pos_weight 3.545, min_child_weight 5, subsample/colsample 0.8.
Baseline AUC is 0.7226 in every run (same rows, same baseline model).

| Run | Depth | eta | Rounds (best) | AUC | Lift [95% CI] | P@10% | R@10% |
|---|---|---|---|---|---|---|---|
| xgb-d6-eta0.1 | 6 | 0.1 | 200 (10) | 0.7806 | +0.0580 [0.0383, 0.0774] | 0.7033 | 0.3197 |
| xgb-d3-eta0.1 | 3 | 0.1 | 200 (36) | 0.7785 | +0.0559 [0.0372, 0.0747] | 0.7233 | 0.3288 |
| xgb-d6-eta0.03-r600 | 6 | 0.03 | 600 (16) | **0.7857** | **+0.0631 [0.0441, 0.0824]** | **0.7300** | 0.3318 |
| xgb-d3-eta0.03-r600 | 3 | 0.03 | 600 (3) | 0.7735 | +0.0509 [0.0307, 0.0719] | 0.6566* | 0.3621* |
| xgb-d6-eta0.03-r600-regtest | 6 | 0.03 | 600 (16) | 0.7857 | same as above | 0.7300 | 0.3318 |
| **xgb-d6-eta0.03-r600-final** (graded) | 6 | 0.03 | 600 (16) | 0.7857 | +0.0631 [0.0441, 0.0824] | 0.7300 | 0.3318 |

(The regtest and final runs reproduce the d6-eta0.03 run exactly, so the pipeline is deterministic end to end:
`ORDER BY customer_id` + fixed seeds.)

- **Every configuration's lift CI excludes 0.** The feature-engineering result is robust to hyperparameters, not one lucky config.
- AUC spans only 0.7735–0.7857 across these settings. The CIs overlap heavily, so hyperparameters matter much less than features.
- Slower learning at depth 6 (eta 0.03) was best on every metric. Depth 3 needed more rounds (best 36 vs 10) to get about the same.
- *d3-eta0.03 stopped at best round 3 (4 shallow trees), so it outputs only a few distinct probabilities. Ties at the
  90th-percentile cutoff flagged **364 customers (12.1%), not 300**, which inflates its recall and deflates its precision. Its
  top-10% metrics are not comparable to the others. (The skeleton's `>= percentile` cutoff includes ties.)
- Silver is the weakest tier by AUC in every run (0.706–0.728).

### Feature importance (for section 2) — GRADED RUN

Gain, highest first: days_since_last_purchase 93.2 · purchase_frequency_180d 92.3 · purchase_frequency_30d 43.4 ·
avg_order_value 28.3 · purchase_frequency_90d 20.7 · total_lifetime_value 18.8 · avg_basket_size_6m 18.5 ·
category_diversity_score 15.0 · total_spend_90d 14.1 · online_to_store_ratio 12.5 · customer_tenure_days 10.9
(Same order as the default-param run, so the ranking is stable across hyperparameters.)

- Recency still matters most, but **180-day frequency is nearly as strong**. Most of the lift over the recency
  baseline likely comes from the frequency features.
- The features the lab built to catch "still buying" churners (category diversity, channel mix, basket size) carry
  **low gain**. That's a candidate for "decorative", and section 2 should be honest about it.
- The three frequency windows (30/90/180d) overlap. Gain is split across correlated features, so a low score for one
  does not prove it carries no signal. Worth saying.
- Possible check before writing: drop the low-gain features and see whether AUC moves (would make the
  "decorative" claim quantitative).

### Slice finding worth using (sections 2 and 4)

- The single top-10% contact list is dominated by **Bronze** customers (graded run): Bronze recall@10% is 0.44, but
  Gold 0.13 and Silver 0.23, even though their within-tier AUCs (0.75, 0.73) are reasonable. A "contact the top 10%
  overall" budget mostly reaches low-spend customers.
- Silver is the weakest tier by AUC (0.7281, 226 churners). Platinum has the highest AUC (0.88) but only 21 churners,
  so it's too small to conclude from.
- Idea for section 4: tier-aware or value-weighted contact budgets (e.g., rank by churn probability × lifetime value),
  or a cost-based threshold from retention-offer economics.

### LLM system — Track C (for section 3)

- Bedrock **Agents** (`CreateAgent`) is closed to new accounts, so AgentCore is the only option (a constraint, not a preference).
- Alternative to argue against: a fixed pipeline. Customer service needs branching, multi-step actions (look up
  order -> check policy -> act or escalate), and the agent must decide when to clarify (TC-004) or escalate (TC-003, TC-005).
- The $50 cap lives in three places:
  - **System prompt.** Shapes behavior but can be talked around.
  - **`tools.py`.** Code, but runs after the gateway has already allowed the call. Credits over $50 return
    `approval_required=True` with a ticket instead of applying.
  - **Gateway Cedar `forbid` policy.** Enforced by the platform **before** the tool runs, independent of the model.
    `policy_tests.py` proves it with no model in the loop. This is the one to trust alone.
- Evidence the gateway layer works alone (`policy-tests.json`, 7/7, no model in the loop): $51 and $75 were DENIED
  at the gateway by `cap_loyalty_credit` before `tools.py` ran. $30 and $50 were allowed.
- But even the gateway rule is **per-call**: two $40 credits pass (the split-credit hole), and one customer received $160
  across four allowed calls in one test run. Link to `track-c-failures.md`.
- Deployment facts: `terraform apply` created 14 resources on the first attempt (TODO 1 had all three policy
  permissions up front, so the expected `GetPolicyEngine` failure never happened). Harness creation took 34 s.
- How the three Terraform TODOs implement enforcement (from `infrastructure/environments/agent/main.tf`):
  - TODO 1: the gateway execution role gets `GetPolicyEngine` (engine ARN) and `AuthorizeAction` +
    `PartiallyAuthorizeActions` (engine ARN and gateway glob). Without them, the gateway can't evaluate Cedar at all.
  - TODO 2: the harness role gets `bedrock-agentcore:InvokeGateway` on the one gateway ARN (least privilege).
  - TODO 3: Cedar `forbid ... apply_loyalty_credit ... when { context.input.amount > 50 }`. In Cedar a forbid always
    overrides a permit, so it carves over-cap credits out of the blanket `permit_tools` grant. The policy engine runs
    in **ENFORCE** mode with `validation_mode = FAIL_ON_ANY_FINDINGS`.
- Harness config from the kit: Haiku 4.5 via the `us.` inference profile, `max_iterations = 8`, `max_tokens = 1024`,
  `memory { disabled {} }`, idle session timeout 60 s (runtime memory was 90% of the reference stack's bill at the
  900 s default).
- Evaluation (2 runs, 6 scenarios each): 6/6 both times per the harness, ~$0.053 per run. But zero
  `escalate_to_human` tool calls: escalation happened only in prose, and the harness's keyword fallback counted it. A
  concrete example of **an LLM-judged or keyword-judged metric overstating behavior**, and of why the lab insists the
  action be a tool call (auditable, routable) rather than text. Good material for the production-risk paragraph.
- Pre-Lab access regression: on 2026-10-17 Claude calls failed with "Model use case details have not been submitted"
  even though the same IAM user (`cs401r-lab`) passed on Oct 12. CloudTrail showed no earlier use-case form
  submission. The form was submitted via `put_use_case_for_model_access` and access returned. Possible "operational
  risk" point: model access is account state outside Terraform, so a working stack can break with no code change.
- Production risk candidates: harmful action under customer pressure (TC-005: final-sale return for a long-tenure
  Platinum member); stateful abuse (split credits).

### Registry / deployment caveat (possible section 4 or Lab 5 note)

- The model is trained on XGBoost 3.4.1 but registered against the SageMaker `xgboost:1.7-1` serving image. The package
  stores the booster as JSON (the most portable format), but cross-version loading is not guaranteed. Lab 5 should
  check that the container loads it and reproduces the evaluated scores.
- The saved booster keeps all trees up to where training stopped (37 for the d6/eta0.03 run), while evaluation scored at
  the best iteration (16). XGBoost 3.x predicts at `best_iteration` automatically; an older serving runtime might use
  all 37 trees. Another thing to verify at deploy time, or fix by slicing the booster to the best iteration before saving.
- Version mismatch between training and serving is a concrete "what I'd do differently": train in the same container
  version that serves (or pin XGBoost locally to the container's version).

### Ideas for section 4 (10x time or data)

- Time-based backtest (train at one cutoff `T`, test at a later one) instead of a random split. Rebuild features at
  several cutoffs to get more labeled rows.
- Calibrated probabilities + a cost-based threshold; value-weighted ranking (see the slice finding).
- Per-customer SHAP explanations for the retention team.
- Track C: a stateful credit ledger or temporal policy to close the split-credit hole; a larger adversarial scenario
  suite run on every deploy.
