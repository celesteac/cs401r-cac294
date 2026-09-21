# ADR-001: NorthStar Platform Foundation

## Status

Accepted

## Context

NorthStar Retail loses about 18% of its 2.1M active customers a year. At roughly $340 in lost lifetime value each, that is a $128.5M annual problem, and the CDO has funded three AI systems against it: a churn model scoring every active customer weekly for 90-day risk, an LLM/RAG system personalizing offers for the top 10% highest-risk customers, and an agentic assistant absorbing part of the 14,000 daily service contacts.

Those systems are not independent products. They read the same customer history, they are built by the same small team, and they run in the same account, which makes this a platform problem rather than three modeling problems. The churn model's weekly run reads engineered features and writes scored output; the offer system reads those scores. If those paths are invented per project, every later change to who may read what becomes a data migration rather than a policy edit, because the paths are already baked into training code, scheduled jobs and model artifacts. Prefixes and roles are cheap to define on an empty bucket and expensive to impose on a populated one, which is why the identity model and storage layout come first.

## Decision

### Network topology

A single VPC, `northstar-dev-vpc` (`10.0.0.0/16`), with one public subnet, `northstar-dev-public-1` (`10.0.100.0/24`), in `us-east-1a`. An Internet Gateway provides egress, a route table sends `0.0.0.0/0` to it, and `northstar-dev-sagemaker-sg` permits inbound traffic only from `10.0.0.0/16` while allowing unrestricted egress.

This is the smallest network supporting today's only workload: Studio, which must pull container images from ECR, reach S3 and serve its own UI. Nothing here accepts inbound connections, so the security group refuses them all.

### S3 prefix design

One bucket, `northstar-dev-data-<account-id>`, with four prefixes mirroring the data's lifecycle: `raw/`, `processed/`, `features/`, `artifacts/`. Public access is fully blocked, SSE-S3 encrypts every object, and versioning is enabled.

The stage boundary matches how responsibility splits at NorthStar. Nightly POS exports and the Shopify order stream land in `raw/` as they arrived, owned by data engineering; feature engineering produces `features/`, which the churn model trains and scores against; `artifacts/` holds trained models and evaluation output. Versioning matters because the weekly scoring job overwrites its own outputs: if a bad feature build ships, the previous week's objects are recoverable rather than gone.

### IAM role model

`northstar-dev-MLEngineer` is trusted only by `sagemaker.amazonaws.com`. It may run training jobs and endpoints, use MLflow and the model registry, manage its own Studio spaces and apps, write CloudWatch Logs and pull ECR images. On S3 it reads and writes only under `artifacts/` and `features/`, and lists the bucket.

The role is denied `raw/` and `processed/` by omission: an ML engineer debugging a model should not be able to rewrite the source data that model's lineage depends on. That guarantee rests on one detail. The object-action statement lists `…/artifacts/*` and `…/features/*`, while `ListBucket` sits in a separate statement on the bucket ARN. Merging them would be an easy simplification and a silent failure, because a trailing `*` on the bucket ARN also matches `raw/anything`, restoring exactly the write access this design excludes. The verification script simulates `s3:PutObject` against `raw/` and expects a deny, so the property is tested rather than assumed.

## Consequences

### What this makes easy

- Access changes are policy edits, not data migrations. Adding the DataEngineer and ModelMonitor roles in Lab 2 means writing policies against prefixes that already exist, with no objects to move.
- The platform rebuilds from one `terraform apply`, so dev can be destroyed nightly to stop paying for it and restored in minutes.

### What this makes harder

- Studio runs in a public subnet with unrestricted egress. That is acceptable for a course account holding no customer data and unacceptable once real POS records land in `raw/`. Fixing it costs a NAT gateway at roughly $32/month plus data processing charges.
- Prefix-scoped IAM cannot express row-level or customer-level restrictions. If NorthStar's Canadian or Mexican operations later require data residency separation, the layout needs partitioning or separate buckets.
- A single account shares one blast radius: a misapplied policy or an accidental `terraform destroy` has nothing between it and every resource in the platform.

### What would cause you to revisit this decision

- Real customer data entering `raw/`, which turns the public subnet from a simplification into a compliance finding.
- A second team needing the same bucket under different rules, where stage prefixes stop being the only useful axis of control.
- State locking changing underneath us: S3 now locks natively via `use_lockfile`, the `dynamodb_table` backend parameter is deprecated, and it is scheduled for removal in AWS provider v6.

## Alternative Considered

Keeping engineered features in Snowflake instead of building an S3 feature tier. NorthStar already runs Snowflake, fed by nightly ETL, and the features the churn model needs are aggregations over transaction history that Snowflake computes well. That would remove `processed/` and `features/` entirely and let the model train against warehouse queries.

It was rejected because it moves the access boundary outside AWS IAM. SageMaker reads natively from S3 under an execution role; reading from Snowflake requires credentials inside the training job — a secret to store, rotate and audit — and answers "can this role see raw data?" in Snowflake's grant model rather than the one the other two systems use. It also bills per query against a warehouse sized for BI, while weekly scoring over 2.1M customers is a batch job whose natural home is object storage.

## AWS Service Selection

- **Networking isolation model:** A VPC with one public subnet, because Studio is the only workload and it needs outbound internet but no inbound access, making a NAT gateway an unjustified $32/month until Lab 2 moves Studio private.
- **Storage design:** S3 with stage prefixes, because it is the storage SageMaker reads natively under an IAM role, and prefixes let one bucket carry the role boundary all three systems share.
- **Identity model:** IAM roles assumed by services rather than long-lived user keys, so access is scoped by the role a workload runs as and can be narrowed per prefix without redistributing credentials.
- **ML development environment:** SageMaker Studio, because it runs as the execution role inside our VPC, putting the notebook environment under the same prefix boundary as the training jobs it launches.
