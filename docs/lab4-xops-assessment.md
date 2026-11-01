# Lab 4 — XOps Assessment

## Pipeline Stage Mapping

**Implementation: AWS CodePipeline with CodeBuild**, from the `pipeline.yaml` and `buildspec.yml`
in the repo. GitHub Actions and GitLab CI would need long-lived AWS credentials stored outside the
account, or an OIDC role set up by hand. CodeBuild runs as an IAM role inside the account, next to
the SageMaker Pipeline, the Model Registry and the CloudWatch alarm it works with, and the whole stack
can be deleted with one command at teardown.

The five required phases run in three CodePipeline stages. A stage is a deployment boundary where
artifacts hand off or a human steps in. A phase is a logical step, so they do not line up one to one.

| Phase | CodePipeline stage | Where it runs |
|---|---|---|
| 1. Source | `Source` | CodeStar connection to GitHub `main`. A push starts the run (`triggerType: Webhook`). |
| 2. Test | `Build` | `buildspec.yml` `pre_build`: `tests/test_data.py`, then `tests/test_features.py`. A failure stops the build before any training. |
| 3. Build | `Build` | `buildspec.yml` `build`: `pipeline_definition.py --upsert`, then the SageMaker Pipeline step `TrainChurnModel`, a spot `ml.m5.large` job that runs `train()` in `models/churn/churn_model.py`. |
| 4. Evaluate | `Build` | Twice: `evaluate_model()` raises inside training on a failed gate, then `tests/test_model.py` and `tests/test_fairness.py` run in `build` against the trained artifact and its metrics. |
| 5. Register | `Build` | SageMaker Pipeline step `RegisterChurnModel`, as `PendingManualApproval`. |
| Human promotion decision | `ManualApproval` | SNS-notified approval action. |

**Why not one stage per phase.** It would mean passing the model artifact between stages and running a
CodeBuild project per stage, which adds nothing here. The only point in this flow that needs a real
boundary is the human decision, so that is the only stage added after `Build`.

**Register sits before the end of Evaluate, and a red build still leaves nothing approvable.** The
SageMaker Pipeline registers the model before CodeBuild runs `tests/test_model.py`. A model that fails a gate
inside training never registers, because `evaluate_model()` raises and the training step fails. A model
that fails a CodeBuild-only test is already registered, so `post_build` sets that package to `Rejected`.
Version 4 went through this path: it failed `test_model_monotone_on_recency` and was rejected automatically.

**Notification.** The alarm `northstar-ci-build-failure` watches `AWS/CodeBuild` `FailedBuilds`, which CodeBuild
emits itself. A metric published from `post_build` would be missing for a test failure, because
`post_build` does not run when `pre_build` fails.

## Champion-Challenger

**Criterion.** A challenger replaces the champion if and only if both of these hold, measured on the same
70/30 split with seed 42:

1. It passes every CI gate: precision@top-10% ≥ 0.50, recall@top-10% ≥ 0.25, lift 95% CI excludes zero.
2. Its AUC is **≥ champion AUC + 0.01**.

The current champion, version 5, has AUC 0.7839, so a challenger needs AUC ≥ 0.7939.

**How this relates to the regression test.** `tests/test_model.py` asks a different question: may this model
be registered at all? It fails a candidate below champion AUC − 0.02. The two numbers leave a band:

| Candidate AUC vs. champion | Outcome |
|---|---|
| Below −0.02 | Build fails, package set to `Rejected` |
| −0.02 to below +0.01 | Registered, stays `PendingManualApproval`, never promoted |
| +0.01 or more, gates passed | Replaces the champion |

The +0.01 margin is there because a retrain with no real improvement should not change the production model.
Comparing on the same split removes most of the ±0.03 AUC variation between random splits. Versions 6 and 7
trained the same code as version 5, scored the same AUC, and so stay in the middle band.

## Retraining Triggers

**(a) Scheduled: weekly.** An **Amazon EventBridge Scheduler** schedule runs before the business's Monday 6 AM ET
scoring deadline:

- `cron(0 3 ? * MON *)`, timezone `America/New_York`, starts the Glue job `northstar-dev-feature-engineer`, so the 48-hour freshness test passes.
- `cron(0 4 ? * MON *)`, same timezone, starts the CodePipeline `northstar-pipeline`.

The target is CodePipeline rather than the SageMaker Pipeline directly, so that a scheduled retrain goes
through the same tests and gates as a code change.

**(b) Performance-based: production AUC below 0.744.** A **SageMaker Model Monitor** model-quality schedule merges
predictions with ground truth and publishes `auc` to CloudWatch (`aws/sagemaker/Endpoints/model-metrics`). A
**CloudWatch alarm** fires when `auc` < **0.744**, which is the champion's 0.7839 minus 0.04, a drop larger than the
±0.03 split-to-split variation. An **Amazon EventBridge** rule on that alarm's state change starts `northstar-pipeline`.

**Earlier signal for label delay.** A churn label exists only 90 days after a score, so the AUC trigger lags. Model
Monitor data-quality monitoring also publishes `feature_baseline_drift_days_since_last_purchase`, and a CloudWatch
alarm at > **0.2** starts the same EventBridge rule, so input drift can trigger a retrain before labels arrive.

Both triggers are designed, not deployed. There is no production endpoint until Lab 5, and monitoring arrives in Lab 6.

## DataOps Maturity

Current level: 2

Evidence: The pipeline is code and every build validates its output. `infrastructure/` defines the stack in Terraform, and
`glue-scripts/transform.py` and `glue-scripts/feature_engineer.py` hold the transforms. `docs/lab2/lab2-data-contract.md` sets
the expected schema. `tests/test_data.py` enforces schema, grain, leakage and 48-hour freshness, and fails on missing data
rather than skipping. `data/feature_engineering.py` is a tested port of the Glue logic, and `test_pandas_port_matches_glue_output`
checks it against real pipeline output. Measured: `docs/lab4-build-green.log` shows 29 `test_data.py` and 23
`test_features.py` tests passed.

Gap to Level 3: Pipeline execution is not automated. The crawler, transform and feature jobs are started by hand with
`aws glue start-job-run`, so data only stays fresh if a person remembers, and a stale feature set is caught by a failing
build rather than prevented.

Top priority investment: An AWS Step Functions state machine, started by an Amazon EventBridge schedule, that runs the
crawler, transform and feature jobs in order and alerts through SNS on failure.

## MLOps Maturity

Current level: 2

Evidence: A commit reaches the Model Registry with no manual steps. `buildspec.yml`, `pipeline.yaml` and
`models/churn/pipeline_definition.py` implement test, spot training and registration, and `tests/test_model.py` gates on
precision, recall, the lift CI and the champion. Measured: `docs/lab4-build-green.log` records
`champion v5 auc=0.7839` from the regression test. `docs/lab4-failure-demo.txt` shows a failing test halt in
`PRE_BUILD`, add no registry version, and send an alarm that reached a confirmed subscriber. The gate also caught a real
defect: version 4 failed `test_model_monotone_on_recency` and was rejected automatically, which led to the monotonic constraint
in `models/churn/churn_model.py`. `docs/lab4-model-package.json` holds lineage, and `docs/lab4-mlflow-runs.txt` holds the experiments.

Gap to Level 3: Nothing happens after registration. There is no automated deployment (Lab 5), no production monitoring
(Lab 6), and the retraining triggers are designed but not deployed, so a model that degrades in production would go unnoticed.

Top priority investment: SageMaker Model Monitor on the production endpoint, with CloudWatch alarms and an EventBridge rule
that starts `northstar-pipeline`, turning the designed performance trigger into a running one.
