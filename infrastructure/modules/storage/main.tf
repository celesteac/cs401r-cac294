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

# ── Lifecycle rules (Lab 2) ──────────────────────────────────────────────────
# raw/ is the only prefix whose current data expires; everywhere else only old
# versions are pruned. datacapture/ has no writer until endpoint data capture
# in Lab 5, but it grows for as long as an endpoint is left running, so its
# retention is in place before the writer is.
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  count  = var.enable_lifecycle_rules ? 1 : 0
  bucket = aws_s3_bucket.data.id

  # Noncurrent-version rules only mean something once versioning is on.
  depends_on = [aws_s3_bucket_versioning.data]

  rule {
    id     = "expire-raw-data"
    status = "Enabled"
    filter {
      prefix = "raw/"
    }
    expiration {
      days = 90
    }
  }

  rule {
    id     = "expire-raw-versions"
    status = "Enabled"
    filter {
      prefix = "raw/"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "expire-processed-versions"
    status = "Enabled"
    filter {
      prefix = "processed/"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "expire-feature-versions"
    status = "Enabled"
    filter {
      prefix = "features/"
    }
    noncurrent_version_expiration {
      noncurrent_days = 60
    }
  }

  rule {
    id     = "expire-datacapture"
    status = "Enabled"
    filter {
      prefix = "datacapture/"
    }
    expiration {
      days = 7
    }
  }
}
