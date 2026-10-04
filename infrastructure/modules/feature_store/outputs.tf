output "feature_group_name" {
  description = "Name of the customer Feature Group"
  value       = aws_sagemaker_feature_group.customers.feature_group_name
}

output "feature_group_arn" {
  description = "ARN of the customer Feature Group"
  value       = aws_sagemaker_feature_group.customers.arn
}

output "offline_store_uri" {
  description = "S3 URI the offline store writes under"
  value       = local.offline_store_uri
}
