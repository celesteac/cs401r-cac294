# NorthStar Retail AI Platform — cs401r-cac294

CS 401R (MLOps) lab repository. The NorthStar platform is built in AWS with Terraform, and each lab
extends the same codebase.

| Lab | What it adds | Status |
|---|---|---|
| Lab 1 — Platform Foundation | VPC, S3 data bucket, MLEngineer IAM role, SageMaker Studio domain, remote state, LocalStack validation | Done |
| Lab 2 — Data & Feature Engineering | Private subnet + NAT Gateway, DataEngineer and ModelMonitor roles, S3 lifecycle rules, Glue ingestion pipeline, SageMaker Feature Store | Done |
| Lab 3 — Model Development | XGBoost churn model on Feature Store features (MLflow App tracking, Model Registry), Track C customer service agent on Amazon Bedrock AgentCore | This lab |

## Repository layout

```
infrastructure/
  modules/
    vpc/            VPC, public + private subnets, IGW, NAT Gateway, route tables, security groups
    storage/        data bucket (versioned, encrypted, private) + S3 lifecycle rules
    iam/            MLEngineer, DataEngineer, ModelMonitor roles and policies
    sagemaker/      SageMaker Studio domain (private subnet, VpcOnly) + MLEngineer profile
    glue/           (Lab 2) catalog database, crawler, VPC connection, transform + feature jobs
    feature_store/  (Lab 2) customer Feature Group (online + offline store)
  environments/
    dev/            real AWS account (S3 remote state)
    local/          LocalStack (vpc, storage, iam only; NAT and lifecycle rules disabled)
    agent/          (Lab 3) AgentCore harness, gateway, Cedar policies, tools Lambda; own state, AWS provider 6.x
churn_training_skeleton.py   (Lab 3) churn model: Athena pull, XGBoost, evaluation, MLflow, Model Registry
evaluation_harness.py        (Lab 3) Track B RAGAS cases and Track C agent scenarios
agent/                       (Lab 3) tools.py, Lambda handler, harness_client.py, policy_tests.py, run_agent_eval.py
northstar-policy-docs/       (Lab 3) policy corpus the agent's query_policy tool reads
notebooks/lab3-demo.ipynb    (Lab 3) Track C end-to-end demo, committed with outputs
glue-scripts/
  transform.py         raw/customers/ CSV -> processed/customers/ Parquet
  feature_engineer.py  processed/customers/ -> features/customers/ + Feature Store
scripts/
  bootstrap-state.sh   one-time: Terraform state bucket + lock table
  verify-lab1.sh       Lab 1 rubric checks
  verify-lab2.sh       Lab 2 rubric checks (the same assertions the TA runs)
  teardown-lab2.sh     full Lab 2 teardown, including resources Terraform does not own
  collect-lab3-evidence.sh  (Lab 3) exports Athena/MLflow/registry/AgentCore evidence and cross-checks it
  teardown-lab3.sh     (Lab 3) endpoints, jobs, Tracking Server check, agent stack destroy
  check-secrets.sh     scans every revision for committed AWS credentials
docs/
  lab1/                Lab 1 evidence, ADR, cost estimate, architecture diagram
  lab2/                Lab 2 diagram sources (.drawio)
  lab2-*               Lab 2 deliverables (see "Lab 2 documents" below)
  lab3-*.md            Lab 3 evaluation report and design justification
  lab3-evidence/       Lab 3 run logs, metrics, plots, exported AWS evidence, agent traces
Makefile               make local-validate / local-destroy / local-clean (LocalStack)
docker-compose.yml     LocalStack container
```

## Lab 2 architecture

The architecture diagram source is [docs/lab2/lab2-architecture-diagram.drawio](docs/lab2/lab2-architecture-diagram.drawio).

**Network.** SageMaker Studio and the Glue workers run in the private subnet
`northstar-dev-private-1` (`10.0.1.0/24`). They reach S3, ECR, and the AWS APIs outbound through the NAT Gateway
`northstar-dev-nat` in the public subnet. Nothing on the internet can open a connection into the private
subnet. The SageMaker domain uses `app_network_access_type = "VpcOnly"`, so Studio traffic also leaves
through the NAT rather than straight out the Internet Gateway.

**IAM boundaries.**

| Role | Trusted by | Can | Cannot |
|---|---|---|---|
| `northstar-dev-MLEngineer` | SageMaker | read/write `features/`, `artifacts/`; train, deploy, use Studio | write `raw/` or `processed/` |
| `northstar-dev-DataEngineer` | Glue, Lambda, SageMaker | read/write `raw/`, `processed/`, `features/`; read `artifacts/glue/`; Glue; Feature Store writes | write `artifacts/`; run training jobs |
| `northstar-dev-ModelMonitor` | SageMaker | CloudWatch metrics and alarms; read processing jobs; read `artifacts/` | write anything to S3; invoke endpoints; start processing jobs |

**S3 lifecycle rules** on `northstar-dev-data-{account-id}`:

| Rule | Prefix | Action |
|---|---|---|
| `expire-raw-data` | `raw/` | delete current versions after 90 days |
| `expire-raw-versions` | `raw/` | delete noncurrent versions after 30 days |
| `expire-processed-versions` | `processed/` | delete noncurrent versions after 30 days |
| `expire-feature-versions` | `features/` | delete noncurrent versions after 60 days |
| `expire-datacapture` | `datacapture/` | delete current versions after 7 days (endpoint data capture, Lab 5) |

### New in Lab 2: `modules/glue/`

| Resource | Name | Purpose |
|---|---|---|
| `aws_glue_catalog_database` | `northstar_dev` | Holds the schema the crawler discovers |
| `aws_glue_crawler` | `northstar-dev-raw-crawler` | Scans `raw/customers/` on demand and registers the table `customers` |
| `aws_glue_connection` (NETWORK) | `northstar-dev-glue-vpc` | Places job workers in the private subnet, using the self-referencing security group `northstar-dev-glue-sg` from `modules/vpc` |
| `aws_s3_object` x2 | `artifacts/glue/*.py` | Uploads both job scripts on every `terraform apply` (re-uploaded when the file changes) |
| `aws_glue_job` | `northstar-dev-transform` | Glue 4.0 Spark: trims, casts, parses both date formats, drops null `customer_id`, median/`unknown` imputation, dedups on `transaction_id` |
| `aws_glue_job` | `northstar-dev-feature-engineer` | Splits history at `FEATURE_CUTOFF` (2026-04-01), computes 13 features + `churn_label`, writes Parquet, ingests to Feature Store |

All of them run as `northstar-dev-DataEngineer`. Every name is built from `var.project` and `var.environment`.

### New in Lab 2: `modules/feature_store/`

| Setting | Value |
|---|---|
| Feature Group | `northstar-dev-customer-features` |
| Record identifier / event time | `customer_id` / `event_time` (**Fractional**, epoch seconds) |
| Definitions | 16: 2 keys, 13 features, `churn_label` (**Integral**) |
| Online store | enabled |
| Offline store | `s3://northstar-dev-data-{account-id}/features/offline-store/`, kept apart from the job's `features/customers/` output |
| Execution role | `northstar-dev-DataEngineer` |

### Data flow

The lineage diagram is [docs/lab2-data-lineage.png](docs/lab2-data-lineage.png).

```
northstar-raw-sample.csv
  -> s3 raw/customers/            (CSV)
  -> crawler -> catalog table northstar_dev.customers
  -> transform job -> s3 processed/customers/      (Parquet, one row per transaction)
  -> feature-engineer job -> s3 features/customers/ (Parquet, one row per customer)
                          -> Feature Store PutRecord -> offline store features/offline-store/
```

The feature job builds features **only** from purchases on or before `FEATURE_CUTOFF` (2026-04-01). It
derives `churn_label` **only** from the outcome window (2026-04-01, 2026-06-30]. That way recency
cannot leak the label.

## Prerequisites

- AWS CLI v2, authenticated against the lab account
- Terraform >= 1.5
- Docker (for LocalStack)
- Python 3 with `pandas` and `pyarrow` (used by `verify-lab2.sh`)
- On Windows: run `make` and `bash scripts/*.sh` from **Git Bash**

## Deploy

```bash
bash scripts/bootstrap-state.sh          # once per account: remote state bucket + lock table
cd infrastructure/environments/dev
terraform init
terraform plan
terraform apply
```

The SageMaker domain takes about 10 minutes to create. **The NAT Gateway bills about $0.045/hour from
the moment it exists**, so tear down when you're done (see [Teardown](#teardown)).

## Run the data pipeline end-to-end

Run from the repo root after `terraform apply`. `northstar-raw-sample.csv` comes from the
[Lab 2 starter kit](https://github.com/byu-cs401r4-f26/cs401r-lab2-template). It is gitignored, so
copy it into the repo root first.

**1. Land the raw data in S3**

```bash
aws s3 cp northstar-raw-sample.csv s3://northstar-dev-data-$(aws sts get-caller-identity --query Account --output text)/raw/customers/northstar-raw-sample.csv
```

**2. Discover the schema.** Run the crawler, then repeat the second command until it reports `READY` / `SUCCEEDED`.

```bash
aws glue start-crawler --name northstar-dev-raw-crawler
aws glue get-crawler --name northstar-dev-raw-crawler --query 'Crawler.{State:State,LastCrawl:LastCrawl.Status}'
aws glue get-table --database-name northstar_dev --name customers --query 'Table.StorageDescriptor.Columns'
```

**3. Transform: raw CSV to processed Parquet.** Repeat the status check until it shows `SUCCEEDED`.

```bash
aws glue start-job-run --job-name northstar-dev-transform
aws glue get-job-runs --job-name northstar-dev-transform --query 'JobRuns[0].{State:JobRunState,Error:ErrorMessage}'
```

**4. Feature engineering: processed Parquet to features and Feature Store.** Run it only after step 3 has succeeded.

```bash
aws glue start-job-run --job-name northstar-dev-feature-engineer
aws glue get-job-runs --job-name northstar-dev-feature-engineer --query 'JobRuns[0].{State:JobRunState,Error:ErrorMessage}'
```

**5. Check the outputs**

```bash
aws s3 ls s3://northstar-dev-data-$(aws sts get-caller-identity --query Account --output text)/processed/customers/
aws s3 ls s3://northstar-dev-data-$(aws sts get-caller-identity --query Account --output text)/features/customers/
aws sagemaker describe-feature-group --feature-group-name northstar-dev-customer-features --query '{Status:FeatureGroupStatus,Features:length(FeatureDefinitions)}'
aws sagemaker-featurestore-runtime get-record --feature-group-name northstar-dev-customer-features --record-identifier-value-as-string CUST-10000776
```

The online store answers `get-record` as soon as the job finishes. The offline store copy under
`features/offline-store/` appears about 15 minutes later.

**If you edit a job script**, run `terraform apply` again to upload it, then start the job again.

### Expected results on the sample data

| Stage | Result |
|---|---|
| raw | 163,255 rows (dirty: null IDs, duplicates, mixed date formats, missing values) |
| processed | 157,627 rows, 9,999 customers, 0 nulls, 0 duplicate `transaction_id` |
| features | 9,999 rows (one per customer), `churn_label` rate 22.0%, all four loyalty tiers |

## Verify

```bash
bash scripts/verify-lab2.sh                                      # live AWS checks for Tasks 1-5
make local-validate LOCAL_OUT=docs/lab2-localstack-output.txt    # LocalStack: 3 roles, VPC, no NAT
bash scripts/check-secrets.sh                                    # no credentials in git history
```

## Teardown

```bash
bash scripts/teardown-lab2.sh
```

`terraform destroy` alone leaves six things behind:

- Glue network interfaces
- the Studio EFS filesystem, which keeps billing
- SageMaker NFS security groups
- S3 object versions
- the `sagemaker_featurestore` Glue database
- SageMaker lineage entities

The script removes all six in order, runs `terraform destroy` (writing `docs/lab2-destroy-output.txt`),
and finally checks the live API to confirm that nothing billable is left. It keeps the Terraform state bucket for Lab 3.

## Lab 2 documents

| File | Contents |
|---|---|
| [docs/lab2-extend-output.txt](docs/lab2-extend-output.txt) | `terraform apply` output for the Task 1 infrastructure changes |
| [docs/lab2-localstack-output.txt](docs/lab2-localstack-output.txt) | LocalStack validation: 3 IAM roles, VPC, no NAT Gateway |
| [docs/lab2-data-contract.md](docs/lab2-data-contract.md) | Data contract for `processed/customers/` |
| [docs/lab2-data-lineage.png](docs/lab2-data-lineage.png) | Lineage from source to Feature Store, with formats and IAM roles on each edge |
| [docs/lab2/](docs/lab2/) | Editable `.drawio` sources for the architecture and lineage diagrams |

## Lab 3 — Model Development

Two systems built on the platform: **Track A**, a churn prediction model trained on the Lab 2 Feature Store, and
**Track C**, NorthStar's customer service agent on Amazon Bedrock AgentCore. Results are in
[docs/lab3-evaluation-report.md](docs/lab3-evaluation-report.md) (churn),
[docs/lab3-evidence/track-c-failures.md](docs/lab3-evidence/track-c-failures.md) (agent) and
[docs/lab3-model-design.md](docs/lab3-model-design.md) (design justification).

### Prerequisites

- The Lab 2 platform deployed (`terraform apply` in `infrastructure/environments/dev`) and the data pipeline above run
  end to end. The Feature Group `northstar-dev-customer-features` holds 9,999 customers in its offline store.
- Python packages:
  ```bash
  pip install "sagemaker>=2.200.0,<3.0.0" xgboost scikit-learn pandas numpy matplotlib boto3 mlflow sagemaker-mlflow
  ```
  `sagemaker` must stay below 3.0, because 3.x removed `sagemaker.feature_store`. `sagemaker-mlflow` is the SigV4
  plugin that lets MLflow talk to an `arn:aws:sagemaker:...` tracking URI.
- A SageMaker MLflow **App** (serverless and free, not the $0.60/hr Tracking Server), created once and kept for Labs 4
  and 6. It uses the Lab 1 bucket and role, both read from Terraform outputs:
  ```bash
  aws sagemaker create-mlflow-app --name northstar-mlflow \
    --artifact-store-uri s3://$(terraform -chdir=infrastructure/environments/dev output -raw s3_bucket_name)/artifacts/mlflow/ \
    --role-arn $(terraform -chdir=infrastructure/environments/dev output -raw ml_engineer_role_arn) \
    --query Arn --output text
  export MLFLOW_APP_ARN=<the ARN printed above>
  ```
- Track C: Bedrock access to Claude Haiku 4.5 (`docs/bedrock-access-verification.txt`), boto3 ≥ 1.43.57,
  AWS CLI ≥ 2.36, Terraform ≥ 1.7.5.

### Train the churn model (Track A)

`churn_training_skeleton.py` runs locally under your own AWS credentials. The MLEngineer role has no Athena
permissions by design. Every name comes from an argument, and the defaults match the Terraform outputs:

```bash
python churn_training_skeleton.py \
  --feature-group-name "$(terraform -chdir=infrastructure/environments/dev output -raw feature_group_name)" \
  --artifacts-bucket   "$(terraform -chdir=infrastructure/environments/dev output -raw s3_bucket_name)" \
  --mlflow-arn "$MLFLOW_APP_ARN" \
  --max-depth 6 --eta 0.03 --num-round 600 \
  --run-name xgb-d6-eta0.03-r600-final \
  --register \
  --output-data-dir docs/lab3-evidence \
  2>&1 | tee docs/lab3-evidence/train-final.log
```

What one run does:

1. Queries the Feature Store offline store through Athena (latest record per customer, deleted rows excluded,
   `ORDER BY customer_id` for a reproducible split) and prints the `Athena QueryExecutionId`.
2. Splits the rows into a stratified 70/30 train/test split (6,999 / 3,000). Missing feature values stay NaN for
   XGBoost's native handling.
3. Trains XGBoost with `scale_pos_weight` computed from the training split, and early-stops on validation AUC.
4. Evaluates against the gates and **stops before registration if one fails**: precision@10% ≥ 0.50, recall@10% ≥ 0.25,
   and a 95% paired-bootstrap CI on the AUC lift over a recency-only baseline that excludes 0. AUC is reported only.
5. Runs the slice evaluation by `loyalty_tier`. Tiers with fewer than `--min-slice-positives` (30) churners are
   flagged too small to conclude from. Then it writes the confusion matrix (at the top-10% cutoff) and the
   gain-based feature importance.
6. Logs the run to MLflow experiment `northstar-churn` (params, the resolved `scale_pos_weight`, `xgboost_version`,
   every metric, and the plots and slice CSV as artifacts).
7. With `--register`, uploads `model.tar.gz` and registers a **`PendingManualApproval`** version in
   `northstar-churn-models`. The metrics and the MLflow run ID go in its metadata. Approval is a human step (Lab 5).

Other arguments: `--min-child-weight`, `--subsample`, `--colsample-bytree`, `--scale-pos-weight` (leave unset to
compute it), `--seed`, `--early-stopping-rounds`, `--model-package-group`, `--xgboost-container-version`,
`--model-dir`. `--local-data-path` is for development only. Omit `--mlflow-arn` or `--register` for trial runs.

### Deploy and evaluate the agent (Track C)

The agent stack has its **own Terraform root and state** (`infrastructure/environments/agent/`, AWS provider 6.x,
state key `agent/terraform.tfstate`). It never touches the Labs 1–2 root.

```bash
cd infrastructure/environments/agent
cp backend.tf.example backend.tf      # account ID filled in (already done in this repo)
terraform init && terraform apply     # 14 resources: harness, gateway (ENFORCE), Cedar policies, tools Lambda, IAM
cd ../../..

python agent/policy_tests.py              # $50 cap enforced at the gateway, no model -> policy-tests.json
python agent/run_agent_eval.py --runs 2   # 6 scenarios per run, each in its own session
```

`agent/harness_client.py` records every tool call in `docs/lab3-evidence/agent-traces.jsonl` and one cost row per
session in `agent-cost.csv`. `run_agent_eval.py` writes one CSV per run, with session IDs, to `evaluation_results/`.
The final run is copied to `docs/lab3-evidence/agent_eval.csv`. The end-to-end demo is
[notebooks/lab3-demo.ipynb](notebooks/lab3-demo.ipynb), committed with the outputs of one clean Restart & Run All.

### Where artifacts land

| Artifact | Location |
|---|---|
| Training log, metrics, slice table, plots | `docs/lab3-evidence/` (`train-final.log`, `evaluation_metrics.json`, `slice-evaluation.csv`, `confusion-matrix.png`, `feature-importance.png`) |
| Athena query results | `s3://<bucket>/artifacts/athena-results/` |
| MLflow runs and their artifacts | MLflow App `northstar-mlflow`, experiment `northstar-churn`; files under `s3://<bucket>/artifacts/mlflow/` |
| Registered model | Model Registry group `northstar-churn-models`; `model.tar.gz` under `s3://<bucket>/artifacts/models/churn/<run-name>-<timestamp>/` |
| Local model copy | `--model-dir` (default `./model/`) |
| Agent evidence | `docs/lab3-evidence/` (`policy-tests.json`, `agent-traces.jsonl`, `agent-cost.csv`, `agent_eval.csv`, `agent_eval_all_runs.csv`) |
| Raw evaluation runs | `evaluation_results/` |
| Exported AWS evidence | `docs/lab3-evidence/` (`account.json`, `athena-query.json`, `mlflow-app.json`, `mlflow-runs.csv`, `model-registry.json`, `agentcore-config.json`, `collect-output.txt`) |

### Collect evidence, then tear down

Run these from Git Bash, in this order: **collect the evidence before teardown**, because the AgentCore config no
longer exists afterwards.

```bash
bash scripts/collect-lab3-evidence.sh --track C   # exports AWS-only evidence and checks the chain of numbers
bash scripts/teardown-lab3.sh                     # endpoints, jobs, Tracking Server check, agent stack destroy
bash scripts/teardown-lab2.sh                     # the Lab 2 platform, including the NAT Gateway
```

The teardown deliberately keeps the free MLflow App (Labs 4 and 6 use it) and the Model Registry entries.

### Lab 3 documents

| File | Contents |
|---|---|
| [docs/lab3-evaluation-report.md](docs/lab3-evaluation-report.md) | Churn metrics, baseline comparison with CI, confusion matrix, feature importance, slice evaluation, provenance |
| [docs/lab3-model-design.md](docs/lab3-model-design.md) | Design justification (Task 3) |
| [docs/lab3-evidence/track-c-failures.md](docs/lab3-evidence/track-c-failures.md) | Track C failure cases with fixes |
| [notebooks/lab3-demo.ipynb](notebooks/lab3-demo.ipynb) | Track C end-to-end demo |
| [docs/bedrock-access-verification.txt](docs/bedrock-access-verification.txt) | Pre-Lab 3 Bedrock access check |
| `docs/lab3-teardown-output.txt` | Teardown verification |
