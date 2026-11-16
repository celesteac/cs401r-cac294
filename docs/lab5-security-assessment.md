# Lab 5 — Security, Privacy & Compliance Assessment: NorthStar Churn Model

Scope: the churn prediction system as built in Labs 1–5: the `northstar-dev-data-<account>`
bucket (`raw/`, `processed/`, `features/`, `artifacts/`, `datacapture/`), the Glue jobs, the
`northstar-dev-customer-features` Feature Group (online and offline store), the
`northstar-churn-models` Model Registry group, the `northstar-churn-prod` real-time endpoint, and
the CodeBuild pipeline. The platform's least-privilege boundary is the three Lab 2 IAM roles:

| Role | What it may do (from `infrastructure/modules/iam/main.tf`) |
|---|---|
| `MLEngineer` | SageMaker training and serving; S3 read/write on `artifacts/*` and `features/*`, write-only on `datacapture/*`; no Athena, no Glue; endpoint execution role |
| `DataEngineer` | Glue jobs; S3 read/write on `raw/*`, `processed/*`, `features/*`; read-only on `artifacts/glue/*`; Feature Store `PutRecord` |
| `ModelMonitor` | CloudWatch metrics and alarms; read-only on `artifacts/*` |

Current state that matters below: the data bucket is versioned and encrypted with **SSE-S3
(`AES256`)**; no KMS key is defined anywhere in the Terraform; the Feature Group has no KMS key
set; no CloudTrail trail is defined (only the default 90-day management event history); the
endpoint is called through the public SageMaker runtime API with IAM SigV4 authentication.

---

## STRIDE Threat Model

| # | Threat | STRIDE Category | Likelihood (H/M/L) | Impact (H/M/L) | Mitigation | AWS Control |
|---|---|---|---|---|---|---|
| 1 | An attacker with endpoint access sends many crafted feature vectors to `northstar-churn-prod` to run membership inference (was customer X in the training set?) or to extract a copy of the model from its scores | Information Disclosure | M | H | Only the offer service's role may call the endpoint; return a rounded score, not raw margins; rate-limit callers; alert on invocation spikes from one principal | IAM identity policy granting `sagemaker:InvokeEndpoint` only on `arn:aws:sagemaker:us-east-1:<acct>:endpoint/northstar-churn-prod` to the offer-service role; Amazon API Gateway usage plan (throttle + quota) in front of the endpoint; CloudWatch alarm on `Invocations` per variant |
| 2 | A compromised or buggy training job (or a stolen MLEngineer session) overwrites `raw/` or `processed/` to poison the next retrain | Tampering | L | H | **Blast radius contained by the `MLEngineer` role:** it has no write on `raw/*` or `processed/*`, only on `features/*` and `artifacts/*`, so it cannot rewrite the source of truth. Versioning allows restoring anything it can write | IAM (`S3ArtifactsAndFeatures` statement scoped to two prefixes, checked by `scripts/verify-lab1.sh`); S3 Versioning on the data bucket to roll back `features/` |
| 3 | A tampered `model.tar.gz` under `artifacts/` (MLEngineer can write there) is deployed as the champion | Tampering | L | H | Deploy only Model Registry versions in `Approved` status, created from the package (not a hand-typed S3 URI); lock released artifacts so they can't be overwritten after approval | SageMaker Model Registry `ModelApprovalStatus` + `create-model --primary-container ModelPackageName=…`; S3 Object Lock (governance mode) on `artifacts/models/`; bandit scan and test gates in AWS CodeBuild |
| 4 | Someone approves a model version or shifts endpoint weights and later denies it; with no trail there is no record of who did it | Repudiation | M | M | Log every control-plane change with the caller's identity in tamper-evident storage, kept longer than the 90-day default | AWS CloudTrail trail (management events: `UpdateModelPackage`, `CreateEndpoint`, `UpdateEndpointWeightsAndCapacities`) delivering to a separate S3 bucket with log file validation enabled and Object Lock |
| 5 | **Gap the roles do not close:** the endpoint is invoked, the Lab 3 Athena query is run, and Terraform is applied by the personal IAM user `cs401r-lab`, which is not one of the three roles and has broad access. A leaked key for that user (this is a public repo) can read every prefix, including `datacapture/` inputs and scores | Spoofing | L | H | Stop using long-lived keys for human work: short-lived credentials with MFA; humans assume one of the scoped roles instead of acting as an admin user; keep secret scanning in CI | AWS IAM Identity Center (or STS `AssumeRole` with an `aws:MultiFactorAuthPresent` condition); `scripts/check-secrets.sh` and the bandit step in CodeBuild `pre_build` |
| 6 | **Gap the roles do not close:** IAM works at the prefix level, not the row level. `MLEngineer` can read every customer's features, and SSE-S3 decrypts for anyone who has `s3:GetObject`, so encryption adds no second check on `features/` or `datacapture/` | Information Disclosure | M | M | Encrypt the personal-data prefixes with a customer-managed KMS key whose key policy lists only the roles that need it, so reading needs `kms:Decrypt` as well as `s3:GetObject`, and every decrypt is logged | AWS KMS customer-managed key + S3 default bucket encryption SSE-KMS (Bucket Keys on); Feature Group `OfflineStoreConfig.S3StorageConfig.KmsKeyId` and `OnlineStoreConfig.SecurityConfig.KmsKeyId` |
| 7 | A flood of invocations (a misbehaving client or abuse) scales the endpoint out and runs up cost, or starves the weekly Monday 6 AM scoring run | Denial of Service | M | M | Cap how far it can scale; throttle at the edge; alert on spend | Application Auto Scaling `MaxCapacity = 2` (`deployment/configs/scalable-target.json`); API Gateway throttling; AWS Budgets alert on SageMaker spend |
| 8 | A principal that can edit IAM attaches a broad policy (e.g. `AmazonS3FullAccess`) to `MLEngineer`, silently erasing the least-privilege boundary | Elevation of Privilege | L | H | No workload role may modify IAM; put a ceiling on what the three roles can ever be granted; validate policies before apply | IAM permissions boundary on the three Lab 2 roles; IAM Access Analyzer policy validation (`aws accessanalyzer validate-policy`) as a CodeBuild step |

Categories covered: Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service,
Elevation of Privilege. Row 2 is the threat a Lab 2 role contains; rows 5 and 6 are gaps those
roles do not close.

---

## Data Classification

Tiers: **Public** (may be published), **Internal** (employees, no personal data),
**Confidential** (business-sensitive or pseudonymous personal data), **Restricted**
(directly identifying personal data or regulated data; GDPR/CCPA scope). The encryption choice
follows one rule: **SSE-KMS wherever personal data lives**, because KMS adds an independent
`kms:Decrypt` permission, a per-use CloudTrail record, and the ability to disable the key.
**SSE-S3** (S3-managed keys) is used where none of that buys anything, since SSE-KMS costs a
request charge and adds a dependency on the key policy.

| Asset | Where it lives | Tier | Encryption | IAM access policy | Share with a third-party vendor? | Reason for the encryption choice |
|---|---|---|---|---|---|---|
| Customer PII (customer master: `customer_id`, SHA-256 `email`, `age_band`, `state`, `zip_code`, loyalty data) | CRM export; `raw/` | Restricted | SSE-KMS (customer-managed key) | DataEngineer read/write on `raw/*`; MLEngineer and ModelMonitor no access; KMS key policy lists DataEngineer only | No. Only under a data processing agreement (GDPR Art. 28) for a named processing purpose; the hashed email is still personal data | Directly identifies people and is in GDPR/CCPA scope. KMS adds a second permission, logs each decrypt, and the key can be disabled in an incident. SSE-S3 would let any `s3:GetObject` holder read it |
| Transaction history (`transaction_id`, `customer_id`, `purchase_date`, `order_value`, `payment_method`, `store_id`, `product_category`) | `raw/customers/`, `processed/customers/` | Restricted | SSE-KMS (customer-managed key) | DataEngineer read/write on `raw/*` and `processed/*`; MLEngineer no access (it reads only `features/`) | No raw rows. Aggregates with no `customer_id` (e.g. category sales by week) are fine | Linked to a person by `customer_id` and reveals purchasing behavior and payment method. Same reasoning as PII: second permission plus an audit trail |
| Behavioral clickstream (Segment events, `search_query`) | Streaming source (not ingested in these labs) | Confidential (Restricted until `search_query` is masked) | SSE-KMS | DataEngineer only; not used by the churn model | Only aggregated and after masking; never raw `search_query` | Pseudonymous behavior data, and the schema warns that `search_query` sometimes contains emails, so it has to be treated as personal data |
| Product catalog (12,000 SKUs, descriptions, prices, inventory) | PIM export | Internal (descriptions and list prices are Public) | SSE-S3 | Read for all three roles; write for DataEngineer | Yes (suppliers, marketplaces, ad partners) | No personal data. A KMS key would add cost and a key-policy dependency without protecting anyone. SSE-S3 still encrypts at rest |
| Model weights (`model.tar.gz`, `xgboost-model`) | `artifacts/models/`, `artifacts/training/` | Confidential | SSE-KMS | MLEngineer read/write; ModelMonitor read-only; DataEngineer none | No. It is NorthStar IP, and access to the weights makes membership-inference and extraction attacks easier | No rows inside, but the weights were learned from personal data and can leak about it (threat 1). KMS lets access be revoked separately from bucket access. SSE-S3 is the current state, which is a gap |
| Inference logs (endpoint data capture: request features + churn score, `.jsonl`) | `datacapture/` | Restricted | SSE-KMS | MLEngineer write-only (the endpoint's execution role); ModelMonitor read for Lab 6 drift analysis; DataEngineer none | No | A per-customer churn score is personal data about that customer. It is kept 7 days, then permanently deleted 1 day later (lifecycle rule `expire-datacapture` with `noncurrent_version_expiration`). KMS gives the audit trail during that window |
| Feature Store records (11 behavioral features, `loyalty_tier`, `churn_label` per `customer_id`) | Online store (DynamoDB-backed) + offline store (Parquet in `features/`) | Confidential | SSE-KMS on both stores (`KmsKeyId` in the Feature Group config) | DataEngineer `PutRecord`; MLEngineer read via `features/*`; ModelMonitor none | No. Derived features count as personal data while they are keyed by `customer_id` | Pseudonymous profile keyed by `customer_id`. The offline store is an append-only history (see the erasure workflow), so who can decrypt it matters for longer |

---

## Privacy Impact Assessment

### 1. Personal data inventory

The only identifier the pipeline carries is `customer_id` (`CUST-########`). Everything below is
personal data because it is linked to that identifier.

| Pipeline stage | Location | Personal data processed |
|---|---|---|
| Ingest | `s3://…/raw/customers/northstar-raw-sample.csv` | Transaction rows: `transaction_id`, `customer_id`, `purchase_date`, `order_value`, `num_items`, `payment_method`, `channel`, `store_id`, `product_category` |
| Transform (Glue `northstar-dev-transform`) | `processed/customers/` (Parquet) | The same rows, typed, de-duplicated, imputed |
| Feature engineering (Glue `northstar-dev-feature-engineer`) | `features/customers/` and the Feature Group's online and offline stores | One row per customer: 11 behavioral aggregates, `loyalty_tier` (bucketed from lifetime value), `churn_label` (from the holdout window), `event_time` |
| Training | Athena results / training input under `artifacts/`; local training run | Those feature rows, read in full |
| Model | `artifacts/…/model.tar.gz` | No rows, but tree splits learned from them |
| Serving | `northstar-churn-prod` requests and responses | 11 feature values in, one churn probability out |
| Inference logging | `datacapture/` (`.jsonl`) | The request features and the returned score, kept 7 + 1 days |
| Monitoring | CloudWatch metrics | Aggregate latency and invocation counts only; no personal data |

The customer master in `northstar-data-schema.md` (hashed `email`, `age_band`, `state`,
`zip_code`) is not ingested into this pipeline.

### 2. Lawful basis

**Legitimate interests (GDPR Art. 6(1)(f)).**

- **Purpose.** NorthStar wants to keep existing loyalty customers by identifying the top 10%
  most likely to lapse and sending them a retention offer before the weekly campaign. Keeping
  existing customers is a recognized legitimate commercial interest. Customers in a loyalty
  program reasonably expect the retailer to use their purchase history to send them offers.
- **Necessity.** Churn risk cannot be estimated without purchase history. The model uses
  aggregates (recency, frequency, spend, basket size, category diversity), not baskets or items,
  which is the least data that still predicts.
- **Balancing test.** The effect on the customer is an offer, not a refusal of service or a
  price increase, so there is no legal or similarly significant effect (Art. 22). No special
  category data is used. People can object at any time and are then excluded from scoring, and
  marketing contact still follows CRM contact preferences.

Why not the others: **contractual necessity** does not apply, because NorthStar can run the
loyalty program without predicting churn, so scoring is not necessary to perform the contract.
**Consent** is a poor fit: it must be specific and freely given, it was not collected for this
purpose, and every withdrawal would trigger the retrain problem in section 4. CCPA (California
customers) does not need a lawful basis but gives the same right to delete, handled below.

### 3. Data minimization

Considered and excluded from training:

| Data | Decision | Why |
|---|---|---|
| `loyalty_tier` | Loaded, **not** a model input; used only for per-tier fairness evaluation | It is bucketed from lifetime value, so it duplicates `total_lifetime_value` and would make the per-tier fairness check circular (`SLICE_COLUMN`, kept out of `FEATURE_COLUMNS`) |
| `churn_risk_score` | Excluded | A rule-based score derived from the same inputs; it adds no new information and hides what the model learns |
| `age_band`, `state`, `zip_code`, hashed `email` | Never ingested | Not needed to predict lapse, and they are protected-characteristic proxies (age, location) that raise fairness risk |
| `payment_method`, `store_id`, `transaction_id`, raw `purchase_date` and line items | Reduced to aggregates | Only recency, frequency and spend matter for churn; card type and store-level detail are unnecessary |
| Clickstream, including `search_query` | Not used | Not needed for a weekly purchase-based churn model, and `search_query` can contain emails |
| Inference payloads | Kept 7 days, then permanently deleted 1 day later | Only long enough for Lab 6 drift monitoring |

### 4. Right to erasure workflow — `customer_id = C00123456`

(Real IDs in this dataset have the form `CUST-########`. The steps are the same for any ID.)
GDPR requires completion within one month. Run every step, record it, and confirm to the customer.

**(a) Raw S3 data.** `raw/customers/` holds one CSV for all customers, so there is no
per-customer object to delete.

1. Rewrite the file without the customer's rows (a Glue job or Athena CTAS with
   `WHERE customer_id <> 'C00123456'`), and write it back to the same key.
2. The bucket is versioned, so the old object is still a noncurrent version. List the versions
   with `aws s3api list-object-versions --prefix raw/customers/` and delete them with
   `delete-object --version-id`.
3. Do the same for the `processed/customers/` Parquet files that contain the customer.

**(b) Feature Store.**

- *Online store.* Run
  `aws sagemaker-featurestore-runtime delete-record --feature-group-name northstar-dev-customer-features --record-identifier-value-as-string C00123456 --event-time <now ISO-8601> --deletion-mode HardDelete`.
  The record disappears from the online store, and `get-record` returns nothing.
- *Offline store.* `DeleteRecord` does **not** remove anything here. The offline store is an
  append-only Parquet history in S3, and the delete only appends a new row marked `is_deleted`.
  Every earlier row for the customer is still there and still returns in an Athena query. Real
  erasure means:
  1. Find the partitions with the customer (Athena on the offline-store table).
  2. Rewrite those Parquet files without the customer's rows.
  3. Replace them and delete their noncurrent versions.
  4. Do the same for the `features/customers/` copy the Glue job writes.

**(c) Model training data and the model.**

1. Delete the customer's rows from every training input: the Athena result sets and training
   channels under `artifacts/`.
2. The trained model has no row to delete. The customer's data is spread through the tree splits
   and leaf weights.
3. The only remedy is to **retrain on the cleaned data**, register a new version, approve it, and
   roll it out through the Lab 5 canary process.
4. Then delete the endpoint's model and the artifacts of every registry version trained with the
   customer's data.
5. NorthStar can run this in the next scheduled weekly retrain (the Lab 4 trigger), which stays
   inside the one-month deadline, rather than retraining once per request.

**(d) Inference logs.** Data capture stores the request features and the score, not
`customer_id`.

1. Find the customer's records by their feature vector or the request's `InferenceId`, delete
   those `.jsonl` objects and their versions.
2. Alternatively, record that the lifecycle rule removes all capture permanently within 8 days.
3. CloudWatch metrics are aggregates and need no action.

**Hardest step: the trained model (c).** Erasure there is not a delete operation. The data is
not stored in the model as a record. It changed the parameters, so the only clean way to remove
its influence is to retrain without it and redeploy, which costs a full training run, a new
approval, and a controlled rollout. Every earlier model version is also "contaminated" until it
is retired. The offline Feature Store (b) is the close second for the same reason: it is
append-only by design, so its "delete" adds a row rather than removing history, and true erasure
means rewriting partitioned Parquet history and purging S3 versions.
