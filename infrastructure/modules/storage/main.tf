# ── modules/storage ──────────────────────────────────────────────────────────
# One data bucket, organised by data stage. Public access is blocked, every
# object is encrypted at rest, and versioning protects against overwrites.

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  bucket_name = "${var.project}-${var.environment}-data-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "data" {
  bucket = local.bucket_name

  tags = { Name = "${local.name_prefix}-data" }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 has no real directories. An empty object whose key ends in "/" is how a
# prefix is made to exist before any data is written to it.
resource "aws_s3_object" "prefixes" {
  for_each = toset(var.prefixes)

  bucket = aws_s3_bucket.data.id
  key    = each.value
}
