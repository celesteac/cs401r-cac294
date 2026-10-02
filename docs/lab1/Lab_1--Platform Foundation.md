# Lab 1: Platform Foundation

**Assigned:** Thu Sep 3 | **Due:** Sat Sep 19, midnight
**Chapter:** *AI Platform & Cloud Architecture*
**Builds on:** Nothing — this is the foundation
**Structure:** Two parts, one submission, 100 points total

## Objective

Build the NorthStar Retail AI platform skeleton on AWS — twice. First by hand in the console (Part A), then as Terraform code (Part B). The sequence is deliberate: you cannot write good Infrastructure as Code for a system you do not understand at the API level. Part A forces you to understand every resource and why it exists. Part B teaches you what IaC is actually automating.

By the end of this lab, you will have: a mental model of the platform architecture, evidence that you built it manually, and a Terraform codebase that rebuilds it from scratch with a single command.

> **Scope note:** This lab uses a single public subnet to keep the networking simple. Lab 2 adds private subnets, a NAT Gateway, and the data engineer and model monitor IAM roles — once you have context for why each of those components exists.

---

## Architecture Reference

Before touching any tool — console, CLI, or Terraform — read this specification. Every resource you create in Parts A and B corresponds to a component here.

### What the Platform Needs to Do

NorthStar's three AI systems (churn prediction, offer generation, customer service agent) all share one platform. In Lab 1, you are building the base layer that every subsequent lab depends on:

1. **A network boundary** — a VPC that isolates NorthStar's cloud resources from other AWS tenants and controls what traffic can enter and exit
2. **A storage structure** — an S3 bucket organized by data stage so different roles can only access the data they are responsible for
3. **An identity model** — IAM roles that enforce who (which AWS service) can do what (which actions) on which data
4. **A development environment** — SageMaker Studio as the IDE for all ML work in this course

### Component Specification

Use this specification to build your architecture diagram (Task A1).

---

#### Boundary: AWS Region `us-east-1`

---

##### Boundary: VPC — `northstar-dev-vpc`

- **CIDR:** `10.0.0.0/16`
- **DNS hostnames:** enabled
- **DNS resolution:** enabled

---

###### Boundary: Availability Zone `us-east-1a`

**Public Subnet — `northstar-dev-public-1`**

- CIDR: `10.0.100.0/24`
- Public IP on launch: yes
- Contains: SageMaker Studio, Internet Gateway route

---

###### VPC-Level Network Resources

**Internet Gateway — `northstar-dev-igw`**

- Attached to: `northstar-dev-vpc`
- Purpose: enables the public subnet to reach the internet (Studio needs to pull container images, reach S3, and serve the Studio UI)

**Route Table — `northstar-dev-public-rt`**

- Associated subnet: `northstar-dev-public-1`
- Routes: `0.0.0.0/0` → Internet Gateway

**Security Group — `northstar-dev-sagemaker-sg`**

- Attached to: SageMaker Domain
- Inbound: all traffic from within `10.0.0.0/16` (VPC CIDR only — no public internet inbound)
- Outbound: all traffic

---

##### Regional Service: Amazon S3

**Bucket — `northstar-dev-data-{account-id}`**

- Public access: fully blocked
- Encryption: SSE-S3 (AES-256)
- Versioning: enabled

Logical prefixes (S3 folders):

| Prefix | Purpose | Responsible Role |
|---|---|---|
| `raw/` | Source data as ingested | DataEngineer (added Lab 2) |
| `processed/` | Cleaned, transformed data | DataEngineer (added Lab 2) |
| `features/` | Engineered feature sets | DataEngineer (added Lab 2) |
| `artifacts/` | Trained models, evaluation outputs | MLEngineer |

Create all four prefixes now. They will be used starting in Lab 2.

---

##### Global Service: AWS IAM

**Role — `northstar-dev-MLEngineer`**

- Trust: `sagemaker.amazonaws.com`
- Allowed:
  - SageMaker: training jobs, endpoints, MLflow App (experiment tracking), model registry, and Studio self-service (describe the Domain and profile; create, list, and delete its own apps and spaces)
  - S3: read/write `artifacts/` and `features/` prefixes
  - CloudWatch Logs: write
  - ECR: read (pull training container images)
- Denied by omission: cannot write to `raw/` or `processed/`

> **Note:** `northstar-dev-DataEngineer` and `northstar-dev-ModelMonitor` roles are added in Lab 2, when the services those roles govern (Glue, Lambda, CloudWatch) are introduced.

---

##### Regional Service: Amazon SageMaker

**Domain — `northstar-dev-domain`**

- Auth mode: IAM
- VPC: `northstar-dev-vpc`
- Subnet: `northstar-dev-public-1`
- Security group: `northstar-dev-sagemaker-sg`
- Default execution role: `northstar-dev-MLEngineer`
- Notebook output sharing: disabled
- Default kernel instance: `ml.t3.medium`

**User Profile — `MLEngineer`**

- Execution role: `northstar-dev-MLEngineer`

> **Note:** Studio is placed in the public subnet in Lab 1 for simplicity. Lab 2 moves it to a private subnet with a NAT gateway for egress —the production-appropriate configuration.

---

### Connection Map (Arrows for Your Diagram)

| From | To | Direction | Label |
|---|---|---|---|
| Internet | Internet Gateway | ↔ | public traffic |
| Internet Gateway | Public Route Table | → | routes |
| Public Route Table | Public Subnet | → | `0.0.0.0/0` |
| SageMaker Domain | Public Subnet | ↔ | runs in |
| SageMaker Domain | SageMaker Security Group | → | enforces |
| SageMaker Studio (MLEngineer) | MLEngineer Role | → | assumes |
| MLEngineer Role | S3 `artifacts/` | ↔ | read/write |
| MLEngineer Role | S3 `features/` | ↔ | read/write |
| MLEngineer Role | ECR | → | pull images |

---

## Starter Kit (Canvas: Lab 1)

- `northstar-scenario-overview.md` — NorthStar Retail case description
- `NorthStar_Retail_AI_Platform.pptx` — the case briefing deck
- `scripts/check-secrets.sh` — the exact credential scan the grader runs on your git history. Run it before every tag.
- `infrastructure/` — skeleton module structure for Part B: four empty modules (vpc, storage, iam, sagemaker) plus `dev` and `local` environments, every variable declared and documented, every resource left as a TODO. `dev/` also ships `backend.tf.example` (Task B3) and `terraform.tfvars.example` (Task B4). Keep this folder name; `scripts/verify-lab1.sh` and the rubric depend on it. It ships passing `terraform fmt -check -recursive` and `terraform validate`, so you start green — keep it that way, it is 5 of the 15 points in Task B1.
- `docker-compose.yml`, `Makefile` — LocalStack setup for Task B5
- `aws-account-setup.md` — AWS account setup, credit budget, and cost controls
- `northstar-data-schema.md` — data source schemas

> **New Account Bootstrap:** SageMaker Studio requires the service-linked role `AWSServiceRoleForAmazonSageMakerNotebooks`. On a brand-new AWS account, `terraform apply` may fail on the SageMaker Domain with a service-linked role error. Fix it once: **IAM → Roles → Create Role → AWS Service → SageMaker → SageMaker Studio**, then re-run `terraform apply`. This is a one-time account bootstrap, not a code error.

---

## Getting Your Repository

You will build the NorthStar platform in **one repository for the whole course**.
Every lab extends the previous one — Lab 2 modifies your Lab 1 Terraform rather than
replacing it — so create this repository once, now, and keep working in it all
semester.

1. **Sign in to GitHub first.** The **Use this template** button does not appear
   to signed-out visitors — the page loads, the button simply is not there, which
   looks like a broken link. If you do not have an account, create one now.
2. Go to <https://github.com/byu-cs401r4-f26/cs401r-lab1-template>
3. Click **Use this template** → **Create a new repository**
4. Name it `cs401r-<your-netid>` — no lab number, it is your repository for all seven
   labs — and leave it **Public**
5. Clone it locally and work there

The template holds the same files as the Canvas starter kit zip; use either one.

### Submitting Lab 1

**Before you tag, confirm these are committed.** Everything here is evidence the
grader reads; several of them cannot be recreated after `terraform destroy`, so a
missing file means that work is graded on whatever else you submitted.

| File | Produced in |
|---|---|
| `docs/lab1-verify-output.txt` | Task B2 — run `bash scripts/verify-lab1.sh` **while the stack is up** |
| `docs/lab1b-apply-output.txt` | Task B2 — `terraform apply` output |
| `docs/lab1b-localstack-output.txt` | Task B5 — `make local-validate` |
| `docs/lab1-studio-shutdown.png` | Lab 1a — Studio shut down |
| `docs/lab1-adr.md` | Architecture decision record |
| `docs/lab1-cost-estimate.md` | Cost estimate |

`scripts/verify-lab1.sh` checks for five of the six (it cannot check for its own
output) and reports anything missing, so run it before you destroy and fix what it flags.

When you are ready to submit, tag the commit you want graded and push the tag:

```bash
git tag lab1-submit
git push origin lab1-submit
```

Then submit **your repository URL** in Canvas. You do not submit the tag name —
it is always `lab1-submit` for this lab, and the TA looks for it.

The TA grades `git checkout lab1-submit`, so anything you push afterwards while
starting the next lab does not change this lab's grade. **If you forget the tag, you
are graded at your last commit before the Canvas deadline** — which, if you have already
started the next lab, may not be the work you meant to submit. Tag it.

> **Public repositories, deliberately.** You may read how other students approached
> the problem. Copying their work is plagiarism and is handled under the BYU Honor
> Code — commit your own. And because these are public: never commit credentials.
> No `.env`, no `terraform.tfvars`, no AWS keys. Committed secrets are an automatic
> zero. The provided `.gitignore` already excludes them; do not remove those lines.

---

## Lab 1a: Manual Provisioning (35 points)

**Goal:** Build the platform using the AWS Console — no scripts, no IaC. This forces you to understand every resource at the API level before abstracting it.

### Task A1 — Architecture Diagram (10 points)

Draw the diagram **before** touching the console. Use it as your build plan.

**Requirements:**

- Official AWS icons (Cloudcraft, draw.io, or aws.amazon.com/architecture/icons)
- Show VPC boundary containing the public subnet in `us-east-1a`
- Show all resources with their exact names
- Show MLEngineer role with arrows to the S3 prefixes it accesses
- Show Internet Gateway connecting the public subnet to the internet
- Legend identifying each icon type

**Deliverables:** `docs/lab1-architecture-diagram.png` and source file (`docs/lab1-architecture-diagram-source.*`)

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| VPC, public subnet, and AZ boundary correct | 3 | Matches spec — CIDR `10.0.0.0/16`, subnet `10.0.100.0/24`, `us-east-1a` |
| All resources shown with correct names | 3 | `northstar-dev-*` naming, resource types match spec |
| MLEngineer role with access arrows to S3 prefixes | 2 | Role shown; arrows to `artifacts/` and `features/` labeled correctly |
| Internet Gateway and route visible | 2 | IGW shown attached to VPC; arrow from public subnet to internet |

---

### Task A2 — Network Layer (10 points)

**Steps:**

1. **Create VPC** — Name: `northstar-dev-vpc`, CIDR: `10.0.0.0/16`, enable DNS hostnames and DNS resolution
2. **Create Public Subnet** — `northstar-dev-public-1`, AZ: `us-east-1a`, CIDR: `10.0.100.0/24`, enable auto-assign public IP
3. **Create Internet Gateway** — `northstar-dev-igw`, then attach it to `northstar-dev-vpc`
4. **Update the main route table** — add route `0.0.0.0/0` → `northstar-dev-igw`; associate `northstar-dev-public-1`
5. **Create Security Group** — `northstar-dev-sagemaker-sg`, VPC: `northstar-dev-vpc`
   - Inbound: All traffic, Source: `10.0.0.0/16` (VPC CIDR — no inbound from internet)
   - Outbound: All traffic, Destination: `0.0.0.0/0`

**Rubric:**

| Item | Points | Screenshot Required |
|---|---|---|
| VPC with correct CIDR and DNS settings | 3 | VPC console: `northstar-dev-vpc`, CIDR `10.0.0.0/16`, DNS hostnames: Enabled |
| Public subnet with correct CIDR in `us-east-1a` | 3 | Subnets list: `northstar-dev-public-1`, CIDR, AZ |
| Internet Gateway attached to VPC | 2 | IGW console: state Attached, VPC ID shown |
| Route table with IGW route associated to public subnet | 2 | Route Tables: `0.0.0.0/0 → igw-*`; subnet associations tab showing `northstar-dev-public-1` |

---

### Task A3 — Storage and IAM (10 points)

**S3 Bucket:**

1. **Create bucket** — name: `northstar-dev-data-YOUR_ACCOUNT_ID`, region: `us-east-1`
2. **Block all public access** — all four boxes checked
3. **Enable versioning**
4. **Enable SSE-S3 encryption** (AES-256)
5. **Create four folder prefixes:** `raw/`, `processed/`, `features/`, `artifacts/`

**IAM Role — `northstar-dev-MLEngineer`**

- Go to IAM → Roles → Create Role → AWS Service → SageMaker
- Role name: `northstar-dev-MLEngineer`
- Create an inline policy (name it `NorthStarMLEngineerPolicy`) with this JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SageMakerCore",
      "Effect": "Allow",
      "Action": [
        "sagemaker:CreateTrainingJob", "sagemaker:DescribeTrainingJob", "sagemaker:StopTrainingJob",
        "sagemaker:CreateEndpoint", "sagemaker:DescribeEndpoint", "sagemaker:DeleteEndpoint",
        "sagemaker:CreateEndpointConfig", "sagemaker:DeleteEndpointConfig",
        "sagemaker:CreateMlflowApp", "sagemaker:DescribeMlflowApp", "sagemaker:ListMlflowApps",
        "sagemaker:CreatePresignedMlflowAppUrl",
        "sagemaker:RegisterModel", "sagemaker:DescribeModelPackage", "sagemaker:ListModelPackages"
      ],
      "Resource": "*"
    },
    {
      "Sid": "StudioSelfService",
      "Effect": "Allow",
      "Action": [
        "sagemaker:DescribeDomain", "sagemaker:ListDomains",
        "sagemaker:DescribeUserProfile", "sagemaker:ListUserProfiles",
        "sagemaker:DescribeSpace", "sagemaker:ListSpaces", "sagemaker:CreateSpace",
        "sagemaker:UpdateSpace", "sagemaker:DeleteSpace",
        "sagemaker:DescribeApp", "sagemaker:ListApps", "sagemaker:CreateApp", "sagemaker:DeleteApp",
        "sagemaker:CreatePresignedDomainUrl"
      ],
      "Resource": [
        "arn:aws:sagemaker:*:*:domain/*", "arn:aws:sagemaker:*:*:user-profile/*",
        "arn:aws:sagemaker:*:*:space/*", "arn:aws:sagemaker:*:*:app/*"
      ]
    },
    {
      "Sid": "S3ArtifactsAndFeatures",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::northstar-dev-data-*/artifacts/*",
        "arn:aws:s3:::northstar-dev-data-*/features/*"
      ]
    },
    {
      "Sid": "S3BucketList",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::northstar-dev-data-*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/sagemaker/*"
    },
    {
      "Sid": "ECRRead",
      "Effect": "Allow",
      "Action": ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:GetAuthorizationToken"],
      "Resource": "*"
    }
  ]
}
```

> **Why `StudioSelfService` exists.** Studio runs *as this role*. Opening Studio makes the UI call `DescribeDomain`, `ListApps`, `DescribeUserProfile` and friends under the execution role, and launching or shutting down JupyterLab is `CreateApp` / `DeleteApp` plus `CreatePresignedDomainUrl`. Without the statement Studio loads a blank page reading "Permissions not configured correctly", and Task A4's "open Studio once, then shut it down" cannot be done. It is scoped to Studio resource types (`domain`, `user-profile`, `space`, `app`), so it grants nothing over training jobs or endpoints. (Found 2026-09-14 by opening Studio with the role as previously specified.)
>
> **Why the S3 statements are split.** Object actions (`GetObject`, `PutObject`, `DeleteObject`) are granted only on the `artifacts/` and `features/` prefixes. `ListBucket` is granted on the bucket ARN. Do not add `arn:aws:s3:::northstar-dev-data-*` to the object-action statement: a trailing `*` in an ARN also matches `/raw/anything`, which silently grants the write access this role is supposed to lack. `scripts/verify-lab1.sh` simulates `s3:PutObject` on `raw/` and expects a deny.

**Rubric:**

| Item | Points | Screenshot Required |
|---|---|---|
| S3 bucket: correct name, versioning enabled, SSE-S3, all public access blocked | 4 | Bucket Properties tab: Versioning Enabled, Encryption SSE-S3, Public Access all Blocked |
| All 4 prefixes visible in bucket | 3 | S3 Objects panel showing `raw/`, `processed/`, `features/`, `artifacts/` |
| `northstar-dev-MLEngineer` role with SageMaker trust and inline policy | 3 | IAM Role detail: Trust Relationships tab (sagemaker.amazonaws.com), Permissions tab (inline policy) |

---

### Task A4 — SageMaker Domain (5 points)

Start this task before finishing A2/A3 — the domain takes 8–12 minutes to provision. Let it run while you complete other steps.

**Steps:**

1. SageMaker → Domains → Create Domain → **Standard setup**
2. Name: `northstar-dev-domain` | Auth: IAM
3. Execution role: `northstar-dev-MLEngineer`
4. VPC: `northstar-dev-vpc` | Subnet: `northstar-dev-public-1` | Security group: `northstar-dev-sagemaker-sg`
5. Sharing: Notebook output sharing → Disabled
6. Submit and wait for status: **InService** (8–12 min)
7. Add user profile `MLEngineer` with execution role `northstar-dev-MLEngineer` → **Launch → Studio**
8. In Studio: **Applications → JupyterLab → Create JupyterLab space** (any name, instance `ml.t3.medium`) → **Run space** → **Open JupyterLab**
9. Verify JupyterLab opens → immediately shut down

> ⚠️ **Shutdown required every session.** Stopping the browser tab does not stop the instance. Two steps:
>
> 1. In JupyterLab: **File → Shut Down** (stops the space). Or from the Studio home page: **Applications → JupyterLab** → your space → **Stop**.
> 2. In the Studio left nav: **Running instances** → confirm the list is empty; **Stop** anything still listed. Screenshot this page and save as `docs/lab1-studio-shutdown.png`.
>
> Cross-check from outside Studio: SageMaker AI console → Domains → `northstar-dev-domain` → **User profiles** → `MLEngineer` → **Apps** tab — nothing should show **InService**. This tab is also an acceptable screenshot. Running app at submission = **−3 points, no exceptions.**

**Rubric:**

| Item | Points | Screenshot Required |
|---|---|---|
| Domain InService with correct VPC, subnet, and security group | 2 | Domain details: InService, VPC ID, subnet ID, SG ID |
| Studio opens (gates the shutdown screenshot — not graded) | — | JupyterLab UI visible |
| JupyterServer stopped; screenshot submitted | 3 | `docs/lab1-studio-shutdown.png`: Studio **Running instances** page empty, or console user-profile **Apps** tab with no app InService |

---

## Lab 1b: Infrastructure as Code (45 points)

**Goal:** Recreate Part A exactly using Terraform. Same CIDRs, same names, same policies. This codebase is your foundation for all remaining labs.

### Repo Structure

```
northstar-ai-platform/
├── infrastructure/
│   ├── modules/
│   │   ├── vpc/            # main.tf  variables.tf  outputs.tf
│   │   ├── iam/            # main.tf  variables.tf  outputs.tf
│   │   ├── storage/        # main.tf  variables.tf  outputs.tf
│   │   └── sagemaker/      # main.tf  variables.tf  outputs.tf
│   └── environments/
│       ├── dev/            # main.tf  variables.tf  tfvars.example  backend.tf  outputs.tf
│       └── local/          # main.tf  outputs.tf
├── scripts/
│   ├── bootstrap-state.sh
│   └── verify-lab1.sh
├── docs/
├── Makefile
├── docker-compose.yml
├── .gitignore
└── README.md
```

> **Security:** Never commit credentials or `.tfvars` with real values. Grader runs `bash scripts/check-secrets.sh` (shipped in the starter kit; it scans every revision for real key shapes and ignores AWS's documented placeholder `AKIAIOSFODNN7EXAMPLE`, which LocalStack prints). Run it yourself before you tag. Automatic 0 if it finds a credential in git history.

---

### Task B1 — Module Structure and Code Quality (15 points)

**`modules/vpc/`** — `aws_vpc`, `aws_subnet` (public only), `aws_internet_gateway`, `aws_route_table`, `aws_route_table_association`, `aws_security_group`

**`modules/storage/`** — `aws_s3_bucket`, `aws_s3_bucket_public_access_block`, `aws_s3_bucket_versioning`, `aws_s3_bucket_server_side_encryption_configuration`, `aws_s3_object` ×4

**`modules/iam/`** — one `aws_iam_role` (MLEngineer trust), one `aws_iam_policy`, one `aws_iam_role_policy_attachment`

**`modules/sagemaker/`** — `aws_sagemaker_domain`, `aws_sagemaker_user_profile`

> **Set `retention_policy { home_efs_file_system = "Delete" }` on the Domain.** Studio creates an EFS filesystem for home directories that Terraform never sees. With the default (`Retain`) it survives `DeleteDomain`, its mount target pins your subnet, and `terraform destroy` hangs on the subnet and security group for ten minutes before failing, which costs you the Task B2 destroy points and leaves a billing filesystem behind. With `Delete`, destroy finishes in about a minute with nothing left over (measured 2026-09-14: 19 resources destroyed in 69 s). Nothing of value lives in a Studio home directory in this course.

Code quality: all names use variables, all variables have descriptions, all modules expose needed outputs, `terraform fmt -check` and `terraform validate` both pass clean.

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| All 4 modules present with correct resource placement | 5 | Each module contains only its designated resources |
| All names parameterized — no hardcoded literals | 5 | `grep -rn '"northstar-dev"' infrastructure/modules/` returns nothing |
| `terraform fmt` and `terraform validate` pass clean | 5 | No output from `terraform fmt -check -recursive`; validate exits 0 |

---

### Task B2 — Apply and Destroy (15 points)

> **Delete your Part A resources before you apply.** Terraform creates resources with the same names, and two of them are unique keys: the IAM role `northstar-dev-MLEngineer` fails with `EntityAlreadyExists`, and the S3 bucket fails with `BucketAlreadyOwnedByYou`. Take your Part A screenshots first, then delete in this order: SageMaker apps and spaces → user profile → domain (choose to delete the EFS volume) → empty and delete the bucket (it is versioned, so use **Empty** in the console) → IAM role → VPC (the console removes the subnet, route table, IGW, and security group with it). The VPC delete will refuse until the domain is fully gone.

```bash
# Bootstrap remote state (one-time)
bash scripts/bootstrap-state.sh

# Deploy
cd infrastructure/environments/dev
terraform init
terraform plan
terraform apply 2>&1 | tee ../../../docs/lab1b-apply-output.txt
```

Verify in the console: Domain InService, S3 bucket with 4 prefixes, VPC with public subnet, MLEngineer role. Open Studio once to confirm, then shut it down.

**Run the verification script BEFORE you destroy.** It reads your Terraform
outputs and checks your live resources, so once `terraform destroy` has run
there is nothing left for it to look at. Commit the output — it is the evidence
your infrastructure was actually built and correct, which the graded console
screenshots only partly show.

```bash
# From the repo root, while the stack is still up
bash scripts/verify-lab1.sh 2>&1 | tee docs/lab1-verify-output.txt
```

Fix anything it reports and re-run until it is clean. Then, and only then:

```bash
terraform destroy
```

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| `terraform apply` completes with 0 errors | 8 | `docs/lab1b-apply-output.txt` ends with `Apply complete! Resources: N added, 0 changed, 0 destroyed` |
| All resources visible in console post-apply | 4 | Screenshots: Domain InService, S3 bucket, VPC subnet, IAM role |
| `terraform destroy` completes cleanly | 3 | `terraform show` returns empty state after destroy |

`docs/lab1-verify-output.txt` is a required artifact. It carries no points of its
own — it is the evidence used to award the Part A and B items above, so a
missing file means those checks fall back to manual review of your screenshots.

---

### Task B3 — Remote State (8 points)

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "northstar-tfstate-YOUR_ACCOUNT_ID"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "northstar-tfstate-lock"
    encrypt        = true
  }
}
```

`scripts/bootstrap-state.sh` must create the state bucket (versioning, SSE-S3, public access blocked) and DynamoDB lock table, patch `backend.tf` with the real account ID, and be idempotent.

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| State bucket with versioning, encryption, public access blocked | 4 | `aws s3api get-bucket-versioning / get-bucket-encryption / get-public-access-block` all correct |
| DynamoDB lock table with `LockID` hash key | 2 | `aws dynamodb describe-table` returns Active |
| `bootstrap-state.sh` idempotent | 2 | Second run exits 0 with "already exists" messages |

---

### Task B4 — Parameterization (4 points)

**Required variables in `environments/dev/variables.tf`:**

| Variable | Type |
|---|---|
| `project` | string |
| `environment` | string |
| `aws_region` | string |
| `vpc_cidr` | string |
| `public_subnet_cidr` | string |
| `availability_zone` | string |
| `sagemaker_instance_type` | string |

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| All 7 variables defined with descriptions | 2 | `terraform validate` passes; each has non-empty description |
| `terraform.tfvars.example` committed; `terraform.tfvars` absent from git | 2 | `git ls-files *.tfvars.example` returns file; `git ls-files *.tfvars` returns nothing |

---

### Task B5 — LocalStack Validation (3 points)

All vpc, storage, and iam resources are supported in LocalStack Community. The local environment skips only the sagemaker module.

The starter kit ships everything this task needs: `docker-compose.yml` (LocalStack), `infrastructure/environments/local/` (the same three modules pointed at `localhost:4566`), and a `Makefile` with the `local-validate` target. You need Docker running and `awslocal` installed (`pip install awscli-local`). Then, from the repo root:

```bash
make local-validate
```

`local-validate` starts LocalStack, runs `terraform init` and `apply` in `environments/local`, then runs `awslocal sts get-caller-identity`, `awslocal s3 ls`, `awslocal iam list-roles`, `awslocal ec2 describe-vpcs`, and `awslocal ec2 describe-subnets`, and saves all output to `docs/lab1b-localstack-output.txt`. Commit that file. `make local-clean` tears it all down. Read `infrastructure/environments/local/README.md` before you run it; it explains what each command verifies and what the output means, and later labs assume you can read this output unaided.

> LocalStack emulates AWS's default VPC (`172.31.0.0/16`, six subnets). Those are not yours. The rubric looks for the `10.0.0.0/16` VPC and `10.0.100.0/24` subnet your module created.

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| `make local-validate` exits 0; output shows S3 bucket, IAM role, VPC | 3 | All three `awslocal` commands return expected resources |

---

## Shared Deliverables (20 points)

### Task S1 — Architecture Decision Record (12 points)

Write `docs/lab1-adr.md` (700–1000 words):

```markdown
## ADR-001: NorthStar Platform Foundation

### Status
Accepted

### Context
[What is NorthStar building? Why does a shared AI platform need an identity model
and a storage tier structure from day one?]

### Decision
[Describe the VPC topology, S3 prefix design, and IAM role model you built.
Every rationale must tie to a NorthStar requirement — not "best practice."]

### Consequences
#### What this makes easy
#### What this makes harder
#### What would cause you to revisit this decision

### Alternative Considered
[One genuinely different approach and why you rejected it]

### AWS Service Selection
- Networking isolation model
- Storage design
- Identity model
- ML development environment
```

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| Decision references NorthStar-specific requirements | 4 | Mentions churn scoring, LLM serving, or three-system platform — not generic reasoning |
| Consequences section is concrete | 4 | Each consequence cites a number, names a constraint, or identifies a failure mode |
| Alternative is meaningful, not a strawman | 2 | Could plausibly work; rejection reason is specific |
| AWS Service Selection covers all 4 components | 2 | One sentence per component with the deciding reason |

---

### Task S2 — Monthly Cost Estimate (8 points)

Estimate steady-state monthly cost using [AWS Pricing Calculator](https://calculator.aws):

| Component | Monthly Estimate | Key Assumptions | One Optimization |
|---|---|---|---|
| SageMaker Studio | $X.XX | X hrs/day at $Y/hr | |
| S3 storage | $X.XX | X GB at $0.023/GB | |
| Internet Gateway | $X.XX | $0.01/GB data transfer | |
| DynamoDB (state lock) | $X.XX | On-demand, near-zero reads | |
| S3 state bucket | $X.XX | Minimal storage | |
| **Total** | **$X.XX** | | |

**Rubric:**

| Item | Points | Pass Criteria |
|---|---|---|
| All 5 components estimated | 3 | Table complete, no "TBD" |
| All assumptions explicit and plausible | 3 | Each estimate traces to a stated assumption |
| One optimization quantified | 2 | Specific change with estimated savings |
