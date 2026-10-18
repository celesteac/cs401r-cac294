task 3 - path c - agent

# Lab 3 — Model Design

**Track:** C — Customer Service Agent (Amazon Bedrock AgentCore)

## 1. Churn model

NorthStar's churn data is small, tabular, and has to be explained. There are 9,999 customers (6,999 for training), 11
numeric input features with very different scales and skewed spend distributions, a 22% positive rate, and a retention
team that needs to know why a customer was flagged. Gradient-boosted trees (XGBoost) fit all three. They need no scaling,
they learn nonlinear thresholds and interactions on their own (healthy recency but falling 180-day frequency, for
example), and they report gain-based feature importance directly from the trained model. Logistic regression would be
more transparent but can't represent those interactions unless they are engineered by hand. A neural network has nothing
to gain from 7,000 rows and 11 features: it would need heavy regularization to avoid overfitting and would be harder to
explain. Class imbalance is handled with `scale_pos_weight` computed from the training split (3.545), and early stopping
on validation AUC keeps the model small (best round 16).

I would switch to logistic regression if the retention team needed a fully additive scorecard, or if its AUC came within
the confidence interval of the boosted model. I would consider a sequence model only with raw event histories and 10–100×
more customers.

## 2. What the features bought us

The recency-only baseline (`days_since_last_purchase` alone) scores **AUC 0.7226**. The full model scores **0.7857**, a
lift of **+0.0631 with a paired-bootstrap 95% CI of [0.0441, 0.0824]**. The interval excludes zero, so the Lab 2 features
do real work, and every hyperparameter configuration I tried also cleared that bar (lifts +0.051 to +0.063). The lift is
moderate: it closes about 23% of the gap between the baseline and a perfect ranker. Precision at the top 10% is 0.73 (3.3×
the base rate), and recall is 0.33 of a 0.45 ceiling.

The signal is concentrated. By gain, `days_since_last_purchase` (93) and `purchase_frequency_180d` (92) dominate,
followed by `purchase_frequency_30d` (43) and `avg_order_value` (28). The behavioral features Lab 2 built to catch
churners who still look active carry the least: category diversity (15), `online_to_store_ratio` (12), and
`customer_tenure_days` (11) are close to decorative in this model. Gain is split across the overlapping 30/90/180-day
frequency windows, so a low score for one doesn't prove it's useless, but the honest reading is that frequency, not
diversity or channel mix, carries the lift over recency.

## 3. LLM system

I built an **agent rather than a fixed pipeline** because customer service branches on the conversation. The system has
to look up an order, check policy, and then act, clarify (TC-004) or escalate (TC-003, TC-005). A pipeline would have to
hard-code that decision tree. The agent runs on AgentCore because managed Bedrock Agents is closed to new accounts.

The primary production risk is the agent **taking or promising an action it shouldn't** under pressure. That's why the
$50 cap lives in three places. The **system prompt** shapes behavior but can be talked around. **`tools.py`** is code,
but it runs only after the platform has already allowed the call. The **gateway Cedar `forbid`** is enforced by the
platform before the tool runs, independent of the model. `policy_tests.py` proved it with no model in the loop: $51 and
$75 were denied by `cap_loyalty_credit`. I would trust the gateway policy alone, with one caveat: it is per-call, so two
$40 credits pass. Closing that requires state (see `track-c-failures.md`).

The evaluation showed the same pattern for escalation. Prompt instructions are probabilistic. After I told the agent
that escalating means calling `escalate_to_human`, real tool escalations rose from 0/4 to only 2/6, while the harness's
text-keyword check reported 6/6 throughout. Required actions belong in the platform, not the prompt.

## 4. What I would do differently

With 10× the time or data, I would change evaluation and enforcement, not just tune more. For churn: a **time-based
backtest** (train at one cutoff `T`, test at a later one) instead of a random split, and a **value-weighted contact
ranking**. Today's top-10% list is dominated by Bronze customers (recall 0.44 vs 0.13 for Gold). For the agent: a
**per-customer credit ledger** in the tool layer (or a Gateway-fronted Runtime so temporal `sum` policies work),
**schema-optional, deterministically routed escalation**, and a tool-call-only escalation check in the harness, so the
evaluation measures the action instead of the wording. I would also train in the same XGBoost version the serving
container runs. The model was trained on 3.4.1 and registered against the 1.7 image.
