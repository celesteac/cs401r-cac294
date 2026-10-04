# Every variable needs a description.

variable "project" {
  description = "Project name, used as the first element of every resource name"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "bucket_name" {
  description = "Data bucket holding raw/, processed/, and the job scripts under artifacts/glue/"
  type        = string
}

variable "dataset" {
  description = "Dataset folder under raw/ and processed/; also the name of the crawler's catalog table"
  type        = string
  default     = "customers"
}

variable "data_engineer_role_arn" {
  description = "IAM role the crawler and jobs run as (the DataEngineer role)"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet the Glue job workers run in"
  type        = string
}

variable "availability_zone" {
  description = "Availability Zone of subnet_id; the Glue NETWORK connection requires it"
  type        = string
}

variable "security_group_id" {
  description = "Security group with a self-referencing all-ports ingress rule, attached to the Glue connection"
  type        = string
}

variable "transform_script_path" {
  description = "Local path to glue-scripts/transform.py, uploaded to artifacts/glue/ on apply"
  type        = string
}

variable "feature_engineer_script_path" {
  description = "Local path to glue-scripts/feature_engineer.py, uploaded to artifacts/glue/ on apply"
  type        = string
}

variable "feature_group_name" {
  description = "SageMaker Feature Group the feature engineering job ingests into"
  type        = string
}

variable "region" {
  description = "AWS region for the Feature Store runtime client in the feature engineering job"
  type        = string
}

variable "worker_type" {
  description = "Glue worker type for the ETL jobs"
  type        = string
  default     = "G.1X"
}

variable "number_of_workers" {
  description = "Number of Glue workers per job run (2 is the minimum for a Spark job)"
  type        = number
  default     = 2
}

variable "job_timeout_minutes" {
  description = "Minutes before a job run is stopped, so a hung run cannot bill indefinitely"
  type        = number
  default     = 30
}
