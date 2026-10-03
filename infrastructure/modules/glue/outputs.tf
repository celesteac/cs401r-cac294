output "database_name" {
  description = "Glue catalog database name"
  value       = aws_glue_catalog_database.this.name
}

output "table_name" {
  description = "Catalog table the crawler registers"
  value       = local.table_name
}

output "crawler_name" {
  description = "Name of the raw-data crawler"
  value       = aws_glue_crawler.raw.name
}

output "transform_job_name" {
  description = "Name of the transform ETL job"
  value       = aws_glue_job.transform.name
}

output "connection_name" {
  description = "Glue NETWORK connection that places jobs in the private subnet"
  value       = aws_glue_connection.vpc.name
}
