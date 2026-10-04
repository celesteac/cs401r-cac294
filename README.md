# NorthStar Retail AI Platform — cs401r-cac294

CS 401R (MLOps) lab repository. The NorthStar platform is built in AWS with Terraform, and each lab
extends the same codebase.

| Lab | What it adds | Status |
|---|---|---|
| Lab 1 — Platform Foundation | VPC, S3 data bucket, MLEngineer IAM role, SageMaker Studio domain, remote state, LocalStack validation | Done |
| Lab 2 — Data & Feature Engineering | Private subnet + NAT Gateway, DataEngineer and ModelMonitor roles, S3 lifecycle rules, Glue ingestion pipeline, SageMaker Feature Store | This lab |

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
glue-scripts/
  transform.py         raw/customers/ CSV -> processed/customers/ Parquet
  feature_engineer.py  processed/customers/ -> features/customers/ + Feature Store
scripts/
  bootstrap-state.sh   one-time: Terraform state bucket + lock table
  verify-lab1.sh       Lab 1 rubric checks
  verify-lab2.sh       Lab 2 rubric checks (the same assertions the TA runs)
  teardown-lab2.sh     full Lab 2 teardown, including resources Terraform does not own
  check-secrets.sh     scans every revision for committed AWS credentials
docs/
  lab1/                Lab 1 evidence, ADR, cost estimate, architecture diagram
  lab2/                Lab 2 diagram sources (.drawio)
  lab2-*               Lab 2 deliverables (see "Lab 2 documents" below)
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
