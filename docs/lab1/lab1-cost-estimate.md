# Lab 1 — Monthly Cost Estimate

**Environment:** `northstar-dev` | **Region:** us-east-1 | **Priced with:** [AWS Pricing Calculator](https://calculator.aws)
**Date priced:** 2026-09-21 | **Basis:** on-demand list price, excluding free-tier credits (noted per line where the free tier would apply)

## Steady-State Monthly Cost

| Component | Monthly Estimate | Key Assumptions | One Optimization |
|---|---|---|---|
| SageMaker Studio | $2.50 | 2 hrs/day × 20 weekdays = 40 hrs at $0.05/hr on `ml.t3.medium` ($2.00), plus a 5 GB space EBS volume at $0.10/GB ($0.50) billed whether or not the space runs | Shut the space down at the end of every session instead of leaving it running (quantified below) |
| S3 storage | $0.12 | 5 GB in S3 Standard at $0.023/GB, the volume expected once Lab 2 lands POS and Shopify extracts in `raw/`; the Lab 1 bucket holds only four empty prefix objects, so today's actual figure is $0.00. Requests (~2,000 PUT, ~10,000 GET) add under $0.02 | Lifecycle `raw/` to Glacier Instant Retrieval after 90 days, cutting that tier's rate from $0.023 to $0.004/GB |
| Internet Gateway | $0.18 | No hourly charge for the gateway itself. ~2 GB/month of data transfer out at $0.09/GB. Container image pulls are inbound and free. The first 100 GB/month out is free-tier covered, so the billed figure today is $0.00 | An S3 VPC endpoint keeps Studio↔S3 traffic off the internet path entirely, which matters once feature files are moving daily |
| DynamoDB (state lock) | $0.01 | On-demand billing. Each Terraform run takes and releases one lock (~3 writes); ~50 runs/month is ~150 writes and ~150 reads against rates of $1.25/M writes and $0.25/M reads. Table holds one item | Drop the table and use S3 native locking (`use_lockfile`), removing the resource entirely |
| S3 state bucket | $0.01 | One ~49 KB state file, versioned; ~50 applies/month retaining ~100 noncurrent versions ≈ 5 MB total at $0.023/GB | Lifecycle rule expiring noncurrent versions after 30 days |
| **Total** | **$2.82** | List price. With free-tier data transfer applied, the effective bill is ~$2.64 | |

## Assumptions

- **Usage pattern:** 2 hrs/day, 20 weekdays a month. This course is worked in bursts around lab deadlines rather than continuously, and Task A4 requires shutting Studio down at the end of every session, so idle instance time is assumed to be zero.
- **Data volume:** The Lab 1 bucket holds four empty prefix objects (0 GB). The 5 GB figure prices the near-term state once Lab 2 ingests POS and Shopify extracts, so the estimate is not misleadingly zero.
- **Terraform activity:** ~50 `apply`/`destroy` runs per month during active lab work, which drives both the state-bucket writes and the lock-table requests.
- **Not included:** training jobs, inference endpoints, and the NAT gateway Lab 2 adds (~$32/month plus $0.045/GB processed) — that single resource will be more than ten times this entire table.
- **Not included:** the two buckets SageMaker created on its own (`sagemaker-studio-*`, `sagemaker-us-east-1-*`), which hold a few KB and round to $0.00.

## Quantified Optimization

**Shut the Studio space down after each session.**

- Left running continuously: 730 hrs/month × $0.05/hr = **$36.50/month**
- Shut down after each session (40 hrs/month): 40 × $0.05 = **$2.00/month**
- **Saving: $34.50/month, a 95% reduction** in the compute line and about 92% of this environment's total bill.

The space's 5 GB EBS volume ($0.50/month) persists either way, so it is excluded from the saving. This is also why the lab penalizes a running app at submission: the difference between disciplined shutdown and forgetting once is larger than every other cost in this table combined.

## Notes

- **Rate discrepancy:** the lab's template suggests $0.01/GB for Internet Gateway data transfer. The current us-east-1 rate for data transfer out to the internet is $0.09/GB, with the first 100 GB/month free. The higher rate is used here.
- **Scale caveat:** these are dev-environment figures. NorthStar's production platform — 2.1M customers scored weekly, plus LLM serving and an agentic service system — would be several orders of magnitude larger, and its cost driver would be training and inference compute, not storage or networking.
- **Free tier:** a new account's 12-month free tier covers the S3 and data transfer lines entirely, so the realistic near-term bill is the SageMaker Studio line alone.
