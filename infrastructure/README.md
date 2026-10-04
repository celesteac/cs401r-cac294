# infrastructure/ — NorthStar platform Terraform

This started as the Lab 1 Part B skeleton and now holds the Lab 1 and Lab 2
platform.

Check that it's clean before you commit:

```bash
cd environments/dev
terraform init
terraform fmt -check -recursive ../..   # no output = pass
terraform validate                      # exits 0
```

Both must still pass when you submit — that is 5 of the 15 points in B1.

## Layout

As of Lab 2. See the repo root `README.md` for the architecture and how to run
the data pipeline.

```
modules/vpc/            aws_vpc, aws_subnet x2 (public + private), aws_internet_gateway,
                        aws_eip + aws_nat_gateway (enable_nat_gateway),
                        aws_route_table x2, aws_route_table_association x2,
                        aws_security_group x2 (SageMaker; Glue self-referencing)
modules/storage/        aws_s3_bucket + public_access_block, versioning,
                        server_side_encryption_configuration, aws_s3_object x4,
                        aws_s3_bucket_lifecycle_configuration (enable_lifecycle_rules)
modules/iam/            aws_iam_role x3 (MLEngineer, DataEngineer, ModelMonitor),
                        aws_iam_policy x3, aws_iam_role_policy_attachment x3
modules/sagemaker/      aws_sagemaker_domain (private subnet, VpcOnly),
                        aws_sagemaker_user_profile
modules/glue/           aws_glue_catalog_database, aws_glue_crawler, aws_glue_connection,
                        aws_s3_object x2 (job scripts), aws_glue_job x2
                        (transform, feature-engineer)
modules/feature_store/  aws_sagemaker_feature_group
```

`environments/dev` wires all six modules. `environments/local` (LocalStack)
wires only vpc, storage, and iam, with the NAT Gateway and lifecycle rules
turned off.

Each module contains **only** its designated resources — that is graded.

## The rule that catches people

**No hardcoded names.** The rubric runs:

```bash
grep -rn '"northstar-dev"' infrastructure/modules/
```

and expects nothing. Build names from `var.project` and `var.environment`
(`"${var.project}-${var.environment}-data"`), and give every variable a
`description` — that is also graded.
