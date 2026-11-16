# Lab 5 Deployment Plan: NorthStar Churn Model Canary

Run from the repo root in Git Bash (account `493155413162`, `us-east-1`). Names used below:

```bash
EP=northstar-churn-prod
P=arn:aws:sagemaker:us-east-1:493155413162:model-package/northstar-churn-models
```

## 1. Deployment strategy and rationale

**Real-time endpoint, canary rollout:** one endpoint with two `ml.m5.large` variants.
`champion` (registry v8) has weight 9 and `canary` (v9) has weight 1, so the canary receives
10% of traffic.

NorthStar needs a **weekly** churn score for every active customer by **Monday 6 AM ET** for the
retention campaign. On its own that is a batch job. We still serve it in real time because offer
generation (Lab 6) must score a single customer on demand within its **2-second** budget, and a
weekly file is stale for anyone whose behavior changed mid-week. The Monday campaign calls the
same endpoint over the customer list, so both consumers share one approved model. A canary tests
a new model on 10% of real traffic with a one-command rollback. Batch Transform quota is 0 on
this account; the `ml.m5.large` endpoint quota is 30.

## 2. Pre-deployment checklist

- [ ] The Lab 2 stack is applied and the features are less than 48 h old. Run
      `terraform -chdir=infrastructure/environments/dev apply`, then the Glue jobs
      `northstar-dev-transform` and `northstar-dev-feature-engineer`.
- [ ] The MLEngineer policy has `S3DataCaptureWrite`, and the `expire-datacapture` lifecycle
      rule shows `7  1` (expiration days, noncurrent days).
- [ ] **Model approval is done by the ML Lead,** against the Lab 4 gates (P@10% ≥ 0.50,
      R@10% ≥ 0.25, `lift_ci_low` > 0):
      - v8: AUC 0.7833, P@10% 0.720, R@10% 0.327, lift CI [0.033, 0.072]
      - v9: AUC 0.7885, P@10% 0.730, R@10% 0.332, lift CI [0.039, 0.077]

      `aws sagemaker update-model-package --model-package-arn $P/9 --model-approval-status Approved`
- [ ] Quota `L-614B09FD` is ≥ 2.
- [ ] Deploy and apply the controls:

```bash
ROLE=$(terraform -chdir=infrastructure/environments/dev output -raw ml_engineer_role_arn)
for v in 8 9; do aws sagemaker create-model --model-name northstar-churn-v$v \
  --primary-container ModelPackageName=$P/$v --execution-role-arn "$ROLE"; done
aws sagemaker create-endpoint-config --cli-input-json file://deployment/configs/endpoint-config-canary.json
aws sagemaker create-endpoint --endpoint-name $EP --endpoint-config-name northstar-churn-canary-v8-v9
aws sagemaker wait endpoint-in-service --endpoint-name $EP
aws cloudwatch put-metric-alarm --cli-input-json file://deployment/configs/rollback-alarm.json
aws application-autoscaling register-scalable-target --cli-input-json file://deployment/configs/scalable-target.json
aws application-autoscaling put-scaling-policy --cli-input-json file://deployment/configs/scaling-policy.json
```

## 3. Rollback criteria

- **Metric:** `AWS/SageMaker` `ModelLatency`, statistic **p95**, dimensions
  `EndpointName=northstar-churn-prod` and `VariantName=canary`.
- **Threshold:** above **200000 microseconds (200 ms)** in **3 of 5** one-minute periods. This
  is the alarm `northstar-churn-rollback-canary-latency-p95` in
  `deployment/configs/rollback-alarm.json`. Measured healthy latency is about 5,500 µs.
- **Manual trigger:** any `Invocation5XXErrors` on the canary.
- **Who decides:** the **on-call ML Engineer** rolls back as soon as the alarm reaches `ALARM`,
  with no approval needed. Ambiguous cases go to the ML Lead.
- **Action:** `bash deployment/configs/rollback-action.sh` sets the canary weight to 0. It takes
  about 90 s and drops no requests.

## 4. Monitoring window

In **production** the canary runs for **48 hours** at 10% before promotion to 100%. The **lab**
compresses this to **60 minutes**, then rolls back (proving the control) and promotes.

A clean window means all of these hold:

- the alarm never reaches `ALARM`
- 0 `Invocation5XXErrors` on either variant
- the canary receives 10% ± 5 points of at least 100 calls
- new `.jsonl` files keep arriving under `datacapture/`

Auto-scaling uses target tracking on `SageMakerVariantInvocationsPerInstance` at 1000, with a
60 s scale-out and 600 s scale-in cooldown. It is applied to the champion, which carries 90% of
the traffic.

**What 60 minutes misses:** the daily traffic peak, a weekend, the Monday 6 AM campaign run, the
2 AM nightly POS load, slow latency degradation, and enough volume to compare the two models'
score distributions and their top-10% overlap. **A real rollout would also track** the
top-decile disagreement rate between champion and canary, recall by loyalty tier, input drift
(Lab 6 Model Monitor) and cost per thousand calls.

## 5. Stakeholder notifications

| Stage | Role | Receives |
|---|---|---|
| Start | VP of Technology | Change notice: endpoint, v8/v9, window, rollback owner |
| Start | VP of Marketing | Notice that campaign scores may come from either version |
| Start | Chief Privacy Officer | Confirmation that data capture is on, with 7+1 day retention |
| Promotion | Chief Data Officer | Approval record and metrics against the gates |
| Promotion | VP of Marketing, VP of Customer Experience | Notice that v9 now scores all customers |
| Promotion | CFO | Instance count and hourly cost |
| Rollback | VP of Technology, ML Lead | Incident notice: alarm state, timeline |
| Rollback | VP of Marketing | Notice that v8 scores the campaign and the canary is paused |
| Rollback | Chief Data Officer | Review date |

## 6. Post-deployment review

Within **2 business days** of promotion or rollback. The ML Lead chairs; the on-call ML
Engineer, a Data Engineer, a VP of Technology delegate and a Marketing analyst attend. The review
produces **`docs/lab5-deployment-review.md`**, which records the observed split, the alarm
history, the decision, the cost, and follow-ups with owners.

## 7. Resource cleanup

1. Capture the live evidence first. It cannot be recreated after teardown.
2. Run `bash scripts/teardown-lab5.sh`. It deletes, in this order: scaling policies, scalable
   targets, `northstar-churn-rollback*` alarms, endpoints, endpoint configs, models, and
   in-flight jobs.
3. Verify against the live API, not the console: `docs/lab5-teardown-output.txt` shows 6 `OK`
   lines, and `aws sagemaker list-endpoints --query 'length(Endpoints)'` prints `0`.

Model Registry versions are kept. They are metadata and are not billed.
