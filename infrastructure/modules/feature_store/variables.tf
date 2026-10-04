# Every variable needs a description.

variable "project" {
  description = "Project name, used as the first element of every resource name"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "feature_group_basename" {
  description = "Feature Group name after the <project>-<environment>- prefix"
  type        = string
  default     = "customer-features"
}

variable "bucket_name" {
  description = "Data bucket that backs the offline store"
  type        = string
}

variable "offline_store_prefix" {
  description = "Prefix in bucket_name for the offline store; must differ from the Glue job's features output prefix"
  type        = string
  default     = "features/offline-store"
}

variable "execution_role_arn" {
  description = "Role Feature Store uses to write the offline store (the DataEngineer role)"
  type        = string
}
