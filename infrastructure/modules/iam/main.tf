# ── modules/iam ──────────────────────────────────────────────────────────────
# Three identities, each scoped to its own S3 prefixes:
#   MLEngineer   - SageMaker work; reads/writes features/ and artifacts/ only,
#                  so it cannot write to raw/ or processed/
#   DataEngineer - Glue/Lambda data plane; writes raw/, processed/, features/
#                  but never artifacts/ (it may only read artifacts/glue/)
#   ModelMonitor - observes drift: CloudWatch metrics, read-only artifacts/

locals {
  name_prefix = "${var.project}-${var.environment}"
  bucket_arn  = "arn:aws:s3:::${var.project}-${var.environment}-data-*"
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "SageMakerAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ml_engineer" {
  statement {
    sid    = "SageMakerCore"
    effect = "Allow"
    actions = [
      "sagemaker:CreateTrainingJob",
      "sagemaker:DescribeTrainingJob",
      "sagemaker:StopTrainingJob",
      "sagemaker:CreateEndpoint",
      "sagemaker:DescribeEndpoint",
      "sagemaker:DeleteEndpoint",
      "sagemaker:CreateEndpointConfig",
      "sagemaker:DeleteEndpointConfig",
      "sagemaker:CreateMlflowApp",
      "sagemaker:DescribeMlflowApp",
      "sagemaker:ListMlflowApps",
      "sagemaker:CreatePresignedMlflowAppUrl",
      "sagemaker:CreateModelPackage",
      "sagemaker:CreateModelPackageGroup",
      "sagemaker:UpdateModelPackage",
      "sagemaker:DescribeModelPackage",
      "sagemaker:ListModelPackages",
    ]
    resources = ["*"]
  }

  # Studio runs as this role: opening it calls DescribeDomain/ListApps, and
  # starting or stopping JupyterLab is CreateApp/DeleteApp. Without this the
  # UI loads a "Permissions not configured correctly" page.
  statement {
    sid    = "StudioSelfService"
    effect = "Allow"
    actions = [
      "sagemaker:DescribeDomain",
      "sagemaker:ListDomains",
      "sagemaker:DescribeUserProfile",
      "sagemaker:ListUserProfiles",
      "sagemaker:DescribeSpace",
      "sagemaker:ListSpaces",
      "sagemaker:CreateSpace",
      "sagemaker:UpdateSpace",
      "sagemaker:DeleteSpace",
      "sagemaker:DescribeApp",
      "sagemaker:ListApps",
      "sagemaker:CreateApp",
      "sagemaker:DeleteApp",
      "sagemaker:CreatePresignedDomainUrl",
    ]
    resources = [
      "arn:aws:sagemaker:*:*:domain/*",
      "arn:aws:sagemaker:*:*:user-profile/*",
      "arn:aws:sagemaker:*:*:space/*",
      "arn:aws:sagemaker:*:*:app/*",
    ]
  }

  # Object actions are scoped to two prefixes. A bare bucket ARN with a
  # trailing wildcard here would also match raw/, granting write access this
  # role is meant to lack; scripts/verify-lab1.sh checks for that deny.
  statement {
    sid       = "S3ArtifactsAndFeatures"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/artifacts/*", "${local.bucket_arn}/features/*"]
  }

  statement {
    sid       = "S3BucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "CloudWatchLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:log-group:/aws/sagemaker/*"]
  }

  statement {
    sid       = "ECRRead"
    effect    = "Allow"
    actions   = ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ml_engineer" {
  name               = "${local.name_prefix}-MLEngineer"
  description        = "Execution role for SageMaker Studio and training jobs"
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = { Name = "${local.name_prefix}-MLEngineer" }
}

resource "aws_iam_policy" "ml_engineer" {
  name        = "${local.name_prefix}-MLEngineerPolicy"
  description = "SageMaker, scoped S3 prefix, CloudWatch Logs, and ECR read access"
  policy      = data.aws_iam_policy_document.ml_engineer.json
}

resource "aws_iam_role_policy_attachment" "ml_engineer" {
  role       = aws_iam_role.ml_engineer.name
  policy_arn = aws_iam_policy.ml_engineer.arn
}

# ── DataEngineer (Lab 2) ─────────────────────────────────────────────────────

data "aws_iam_policy_document" "data_engineer_trust" {
  statement {
    sid     = "DataPlaneAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    # sagemaker.amazonaws.com is required by Task 3: CreateFeatureGroup rejects
    # an execution role that does not trust SageMaker, and reports it as
    # "The execution role ARN is invalid".
    principals {
      type = "Service"
      identifiers = [
        "glue.amazonaws.com",
        "lambda.amazonaws.com",
        "sagemaker.amazonaws.com",
      ]
    }
  }
}

data "aws_iam_policy_document" "data_engineer" {
  # glue:* already covers glue:GetConnection. It is listed on its own as well
  # because a VPC Glue job resolves its NETWORK connection before the script
  # runs, and fails with "DataCatalog Connection issue" without it.
  statement {
    sid       = "GlueFullAccess"
    effect    = "Allow"
    actions   = ["glue:*", "glue:GetConnection"]
    resources = ["*"]
  }

  # Glue workers in the private subnet attach ENIs to the VPC.
  statement {
    sid    = "GlueVpcNetworkInterfaces"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:Describe*",
    ]
    resources = ["*"]
  }

  # Glue tags every ENI it creates; without this the job fails to provision.
  statement {
    sid       = "GlueTagNetworkInterfaces"
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:aws:ec2:*:*:network-interface/*"]
  }

  statement {
    sid     = "S3DataPrefixesReadWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${local.bucket_arn}/raw/*",
      "${local.bucket_arn}/processed/*",
      "${local.bucket_arn}/features/*",
    ]
  }

  # Glue fetches its own job scripts. Read-only, and only artifacts/glue/:
  # this role must never write artifacts/.
  statement {
    sid       = "S3GlueScriptsReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/artifacts/glue/*"]
  }

  statement {
    sid       = "S3BucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }

  # Required by Task 3. Feature Store checks the bucket ACL before accepting it
  # as an offline store ("Invalid S3Uri provided" without it), and writes its
  # objects with an ACL, which plain PutObject does not cover.
  statement {
    sid       = "FeatureStoreOfflineStoreBucketAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "FeatureStoreOfflineStoreObjectAcl"
    effect    = "Allow"
    actions   = ["s3:PutObjectAcl"]
    resources = ["${local.bucket_arn}/features/*"]
  }

  statement {
    sid    = "FeatureStoreWrite"
    effect = "Allow"
    actions = [
      "sagemaker:PutRecord",
      "sagemaker:CreateFeatureGroup",
      "sagemaker:DescribeFeatureGroup",
    ]
    resources = ["arn:aws:sagemaker:*:*:feature-group/${local.name_prefix}-*"]
  }

  statement {
    sid     = "CloudWatchLogs"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws-glue/*",
      "arn:aws:logs:*:*:log-group:/aws/lambda/*",
    ]
  }
}

resource "aws_iam_role" "data_engineer" {
  name               = "${local.name_prefix}-DataEngineer"
  description        = "Execution role for Glue crawlers and jobs, Lambda, and Feature Store ingestion"
  assume_role_policy = data.aws_iam_policy_document.data_engineer_trust.json

  tags = { Name = "${local.name_prefix}-DataEngineer" }
}

resource "aws_iam_policy" "data_engineer" {
  name        = "${local.name_prefix}-DataEngineerPolicy"
  description = "Glue, VPC ENIs, raw/processed/features read-write, artifacts/glue read-only, Feature Store write, CloudWatch Logs"
  policy      = data.aws_iam_policy_document.data_engineer.json
}

resource "aws_iam_role_policy_attachment" "data_engineer" {
  role       = aws_iam_role.data_engineer.name
  policy_arn = aws_iam_policy.data_engineer.arn
}

# ── ModelMonitor (Lab 2) ─────────────────────────────────────────────────────
# This role observes; it does not act. It cannot invoke endpoints, write to
# S3, modify models, or start a processing job (that is ModelMonitorExecution
# in Lab 6). It shares the SageMaker trust policy with MLEngineer.

data "aws_iam_policy_document" "model_monitor" {
  statement {
    sid    = "CloudWatchMetricsAndAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DriftRunVisibility"
    effect = "Allow"
    actions = [
      "sagemaker:ListProcessingJobs",
      "sagemaker:DescribeProcessingJob",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "S3ArtifactsReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/artifacts/*"]
  }

  statement {
    sid       = "S3BucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "CloudWatchLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:log-group:/aws/sagemaker/*"]
  }
}

resource "aws_iam_role" "model_monitor" {
  name               = "${local.name_prefix}-ModelMonitor"
  description        = "Read-only observer of drift runs; publishes CloudWatch metrics and alarms"
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = { Name = "${local.name_prefix}-ModelMonitor" }
}

resource "aws_iam_policy" "model_monitor" {
  name        = "${local.name_prefix}-ModelMonitorPolicy"
  description = "CloudWatch metrics and alarms, processing job read-only, artifacts read-only, CloudWatch Logs"
  policy      = data.aws_iam_policy_document.model_monitor.json
}

resource "aws_iam_role_policy_attachment" "model_monitor" {
  role       = aws_iam_role.model_monitor.name
  policy_arn = aws_iam_policy.model_monitor.arn
}
