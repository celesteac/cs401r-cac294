# Same state bucket and lock table as Labs 1-2, but a DIFFERENT key, so this
# stack has its own state and never touches the Labs 1-2 root.
terraform {
  backend "s3" {
    bucket         = "northstar-tfstate-493155413162"
    key            = "agent/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "northstar-tfstate-lock" # same lock table as Labs 1-2
    encrypt        = true
  }
}
