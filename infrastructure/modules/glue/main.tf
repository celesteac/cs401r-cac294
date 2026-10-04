# ── modules/glue ─────────────────────────────────────────────────────────────
# The data pipeline:
#
#   s3 raw/<dataset>/ --crawler--> catalog table <dataset> --transform job-->
#   s3 processed/<dataset>/ (Parquet) --feature-engineer job-->
#   s3 features/<dataset>/ (Parquet) + Feature Store PutRecord
#
# Everything runs as the DataEngineer role. Both jobs run inside the private
# subnet through a NETWORK connection, so they reach S3, the Glue APIs, and the
# Feature Store runtime through the NAT Gateway.

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Glue database names use underscores, not hyphens: <project>_<environment>.
  database_name = replace("${var.project}_${var.environment}", "-", "_")

  # The crawler names its table after the last folder of the S3 target and no
  # table prefix is set, so raw/customers/ becomes the table "customers".
  table_name = var.dataset

  raw_path        = "s3://${var.bucket_name}/raw/${var.dataset}/"
  processed_path  = "s3://${var.bucket_name}/processed/${var.dataset}/"
  features_path   = "s3://${var.bucket_name}/features/${var.dataset}/"
  scripts_prefix  = "artifacts/glue"
  transform_key   = "${local.scripts_prefix}/transform.py"
  transform_s3uri = "s3://${var.bucket_name}/${local.transform_key}"
  features_key    = "${local.scripts_prefix}/feature_engineer.py"
  features_s3uri  = "s3://${var.bucket_name}/${local.features_key}"
}

resource "aws_glue_catalog_database" "this" {
  name        = local.database_name
  description = "NorthStar ${var.environment} data catalog: tables discovered by the raw crawler"
}

resource "aws_glue_crawler" "raw" {
  name          = "${local.name_prefix}-raw-crawler"
  description   = "Discovers the schema of raw/${var.dataset}/ and registers it in the catalog"
  role          = var.data_engineer_role_arn
  database_name = aws_glue_catalog_database.this.name

  # No schedule: the crawler runs on demand (aws glue start-crawler).
  s3_target {
    path = local.raw_path
  }

  tags = { Name = "${local.name_prefix}-raw-crawler" }
}

# Lets Glue workers run in the private subnet. Glue resolves this connection
# before the job script starts, which is why the role needs glue:GetConnection.
resource "aws_glue_connection" "vpc" {
  name            = "${local.name_prefix}-glue-vpc"
  description     = "Places Glue job workers in the private subnet"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = var.availability_zone
    subnet_id              = var.subnet_id
    security_group_id_list = [var.security_group_id]
  }

  tags = { Name = "${local.name_prefix}-glue-vpc" }
}

# The job script ships with terraform apply; the etag re-uploads it whenever
# glue-scripts/transform.py changes.
resource "aws_s3_object" "transform_script" {
  bucket = var.bucket_name
  key    = local.transform_key
  source = var.transform_script_path
  etag   = filemd5(var.transform_script_path)
}

resource "aws_glue_job" "transform" {
  name         = "${local.name_prefix}-transform"
  description  = "Casts types, imputes nulls, and deduplicates raw ${var.dataset} into processed Parquet"
  role_arn     = var.data_engineer_role_arn
  glue_version = "4.0"
  connections  = [aws_glue_connection.vpc.name]

  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.job_timeout_minutes
  max_retries       = 0

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = local.transform_s3uri
  }

  # Read by getResolvedOptions in glue-scripts/transform.py.
  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--database_name"                    = aws_glue_catalog_database.this.name
    "--table_name"                       = local.table_name
    "--output_path"                      = local.processed_path
  }

  depends_on = [aws_s3_object.transform_script]

  tags = { Name = "${local.name_prefix}-transform" }
}

# ── Feature engineering (Lab 2 Task 3) ───────────────────────────────────────

resource "aws_s3_object" "feature_engineer_script" {
  bucket = var.bucket_name
  key    = local.features_key
  source = var.feature_engineer_script_path
  etag   = filemd5(var.feature_engineer_script_path)
}

resource "aws_glue_job" "feature_engineer" {
  name         = "${local.name_prefix}-feature-engineer"
  description  = "Splits ${var.dataset} history at the feature cutoff, computes one labelled feature row per customer, and ingests to Feature Store"
  role_arn     = var.data_engineer_role_arn
  glue_version = "4.0"
  connections  = [aws_glue_connection.vpc.name]

  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.job_timeout_minutes
  max_retries       = 0

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = local.features_s3uri
  }

  # Read by getResolvedOptions in glue-scripts/feature_engineer.py. The job
  # writes features/<dataset>/; the Feature Group's offline store has its own
  # prefix, so the two writers never share a directory tree.
  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--input_path"                       = local.processed_path
    "--output_path"                      = local.features_path
    "--feature_group_name"               = var.feature_group_name
    "--region"                           = var.region
  }

  depends_on = [aws_s3_object.feature_engineer_script]

  tags = { Name = "${local.name_prefix}-feature-engineer" }
}
