# ── modules/feature_store ────────────────────────────────────────────────────
# The customer Feature Group: one record per customer, written by the feature
# engineering Glue job (PutRecord, as DataEngineer) and read for training by
# MLEngineer from Lab 3 on.
#
# Two things here fail silently or misleadingly if they are wrong:
#   * event_time is Fractional (epoch seconds). If the declared type and the
#     value sent disagree, PutRecord returns success and the record never
#     lands in either store.
#   * the execution role must trust sagemaker.amazonaws.com and hold
#     s3:GetBucketAcl / s3:PutObjectAcl, or CreateFeatureGroup reports an
#     "invalid" role ARN or S3 URI. Both are granted in modules/iam.

locals {
  name_prefix = "${var.project}-${var.environment}"

  # The offline store builds its own <account>/sagemaker/<region>/offline-store/
  # tree under this prefix. It must not be the prefix the Glue job writes its
  # Parquet to, or the two layouts interleave.
  offline_store_uri = "s3://${var.bucket_name}/${var.offline_store_prefix}/"

  # 16 definitions: 2 keys, 13 features, 1 label.
  feature_definitions = [
    { name = "customer_id", type = "String" },
    { name = "event_time", type = "Fractional" },
    { name = "days_since_last_purchase", type = "Fractional" },
    { name = "customer_tenure_days", type = "Fractional" },
    { name = "purchase_frequency_30d", type = "Fractional" },
    { name = "purchase_frequency_90d", type = "Fractional" },
    { name = "purchase_frequency_180d", type = "Fractional" },
    { name = "avg_order_value", type = "Fractional" },
    { name = "total_spend_90d", type = "Fractional" },
    { name = "total_lifetime_value", type = "Fractional" },
    { name = "avg_basket_size_6m", type = "Fractional" },
    { name = "category_diversity_score", type = "Fractional" },
    { name = "online_to_store_ratio", type = "Fractional" },
    { name = "loyalty_tier", type = "String" },
    { name = "churn_risk_score", type = "Fractional" },
    { name = "churn_label", type = "Integral" },
  ]
}

resource "aws_sagemaker_feature_group" "customers" {
  feature_group_name             = "${local.name_prefix}-${var.feature_group_basename}"
  description                    = "Customer churn features from the observation window, labelled from the outcome window"
  record_identifier_feature_name = "customer_id"
  event_time_feature_name        = "event_time"
  role_arn                       = var.execution_role_arn

  dynamic "feature_definition" {
    for_each = local.feature_definitions
    content {
      feature_name = feature_definition.value.name
      feature_type = feature_definition.value.type
    }
  }

  online_store_config {
    enable_online_store = true
  }

  offline_store_config {
    s3_storage_config {
      s3_uri = local.offline_store_uri
    }
  }

  tags = { Name = "${local.name_prefix}-${var.feature_group_basename}" }
}
