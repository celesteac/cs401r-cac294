# ── modules/iam ──────────────────────────────────────────────────────────────
# The MLEngineer identity: what SageMaker may do on this account's behalf.
# Object access is granted only on the artifacts/ and features/ prefixes, so
# the role cannot write to raw/ or processed/.

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
