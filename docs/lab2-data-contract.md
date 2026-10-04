## Data Contract: processed/customers

| | |
|---|---|
| **Dataset** | `s3://northstar-dev-data-{account-id}/processed/customers/` |
| **Format** | Parquet (Snappy-compressed), written in full on every run (overwrite) |
| **Contract version** | 1.0 |
| **Last reviewed** | 2026-10-03 |

### Producer
Team / process: Glue ETL job `northstar-dev-transform` (`glue-scripts/transform.py`), running as IAM role `northstar-dev-DataEngineer`.

Source: Glue Data Catalog table `northstar_dev.customers`, registered by crawler `northstar-dev-raw-crawler` over `raw/customers/` (CSV).

### Consumers
- Feature engineering job `northstar-dev-feature-engineer`
- (Future) Direct model training in Lab 3

### Grain
One row per transaction. A customer appears on many rows.

`transaction_id` is the unique key. The transform removes duplicate transactions (the same `transaction_id` landing more than once from an ingestion retry), but never collapses a customer's history to one row. Aggregating to one row per customer is the feature engineering job's responsibility, not this dataset's.

### Schema
| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| `transaction_id` | string | No | Unique transaction key, format `TXN-` + 12 uppercase alphanumeric characters. Primary key of this dataset. |
| `customer_id` | string | No | Customer key, format `CUST-` + 8 digits. Repeats across rows by design. Rows with no customer are dropped by the producer. |
| `purchase_date` | date | No | Calendar date of the purchase. Normalized from the raw data's mixed `yyyy-MM-dd` / `MM/dd/yyyy` strings to a Parquet `date` (ISO 8601). |
| `order_value` | double | No | Gross order value in USD. Missing raw values are imputed with the column median. |
| `num_items` | int | No | Number of line items in the order. Missing raw values are imputed with the rounded column median. |
| `payment_method` | string | No | One of `credit_card`, `debit_card`, `gift_card`, `cash` (or `unknown` if missing in raw). |
| `channel` | string | No | `online` or `store` (or `unknown` if missing in raw). |
| `store_id` | string | No | `STORE-` + 3 digits for in-store orders, `ONLINE` for online orders (or `unknown` if missing in raw). |
| `product_category` | string | No | Primary category of the order: `Apparel`, `Beauty`, `Electronics`, `Footwear`, `Grocery`, `Home`, `Outdoor`, `Toys`, or `unknown` when missing in raw. Consumers counting categories must exclude `unknown`. |

All string values are trimmed of leading and trailing whitespace. No column contains empty strings.

### Quality Guarantees
Each guarantee is a measurable assertion. "Enforced by" says where a violation is caught.

| # | Guarantee | Measure | Enforced by |
|---|-----------|---------|-------------|
| 1 | `customer_id` is never null | count of null `customer_id` = 0 | Producer assertion (job fails) + `verify-lab2.sh` |
| 2 | No duplicate `transaction_id` rows (a `customer_id` repeating across rows is expected, not a defect) | count(`transaction_id`) = count(distinct `transaction_id`) | Producer assertion (job fails) + `verify-lab2.sh` |
| 3 | `purchase_date` is a valid ISO 8601 date | count of null `purchase_date` = 0, stored as Parquet `date` | Producer assertion (job fails) + `verify-lab2.sh` |
| 4 | No nulls in any column | null count = 0 in all 9 columns | Producer (median / `unknown` imputation) |
| 5 | Transaction-level grain is preserved | row count > count(distinct `customer_id`) | `verify-lab2.sh` |
| 6 | `order_value` is within bounds | 1.00 ≤ `order_value` ≤ 1,000.00 USD | Consumer-side check (not enforced by the producer) |
| 7 | `num_items` is within bounds | 1 ≤ `num_items` ≤ 20 | Consumer-side check (not enforced by the producer) |
| 8 | `purchase_date` is within the dataset window | 2025-04-01 ≤ `purchase_date` ≤ 2026-06-30 | Consumer-side check (not enforced by the producer) |
| 9 | Categorical columns use only their allowed values | `payment_method`, `channel`, `product_category` values ⊆ the sets in the Schema table | Consumer-side check (not enforced by the producer) |
| 10 | `channel` and `store_id` agree | `channel = 'online'` ⇔ `store_id = 'ONLINE'`; 0 mismatched rows | Consumer-side check (not enforced by the producer) |
| 11 | Imputed category rate stays low | rows with `product_category = 'unknown'` ≤ 5% of rows | Consumer-side check (not enforced by the producer) |
| 12 | Schema matches this contract exactly | the 9 columns above, with these types, and no others | Producer (selects and casts exactly these columns) |

**Baseline observed on 2026-10-03** (first full run on the Lab 2 sample):

| Metric | Value |
|---|---|
| Rows | 157,627 |
| Distinct customers | 9,999 |
| Null values (all columns) | 0 |
| Duplicate `transaction_id` | 0 |
| `order_value` range | 15.00 – 620.00 USD (median 141.75) |
| `num_items` range | 1 – 9 |
| `purchase_date` range | 2025-04-01 – 2026-06-30 |
| `product_category = 'unknown'` | 3,147 rows (2.0%) |
| `channel` / `store_id` mismatches | 0 |

The bounds in guarantees 6 and 7 are set wider than this baseline. A breach means a real data problem (a unit error or a corrupt row), not normal variation.

### SLA
- Data is available in `processed/customers/` within 2 hours of landing in `raw/customers/`.
- Freshness depends on the pipeline being triggered. In Lab 2, the crawler and the transform job run on demand (`aws glue start-crawler`, `aws glue start-job-run`); they aren't scheduled. A transform run takes minutes, well inside the 2-hour window once it starts.
- A run either writes the complete dataset or fails without writing: the producer assertions run before the write, so a failing run leaves the previous version in place.
- Retention: the bucket is versioned, and noncurrent versions under `processed/` expire after 30 days (S3 lifecycle rule `expire-processed-versions`). Consumers can recover the previous run's output for 30 days.

### Versioning
- Schema changes require a new S3 prefix (e.g., `processed/customers/v2/`).
- Breaking changes require consumer notification 5 business days in advance.
- Breaking changes include removing or renaming a column, changing a column's type, making a non-null column nullable, changing the grain, or narrowing a guarantee above.
- The current prefix `processed/customers/` is contract version 1.0. When a `v2/` prefix is introduced, `v1` keeps being written until every consumer has migrated.
