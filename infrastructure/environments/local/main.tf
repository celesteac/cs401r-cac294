# ── environments/local ───────────────────────────────────────────────────────
# Calls the same modules as environments/dev. The sagemaker module is omitted
# on purpose: SageMaker is not in LocalStack Community.
#
# Lab 2: the NAT Gateway and the S3 lifecycle rules are switched off here, and
# the iam module now creates all three roles (MLEngineer, DataEngineer,
# ModelMonitor). `make local-validate` checks that no NAT Gateway was created.

module "vpc" {
  source             = "../../modules/vpc"
  project            = var.project
  environment        = var.environment
  enable_nat_gateway = false
}

module "storage" {
  source                 = "../../modules/storage"
  project                = var.project
  environment            = var.environment
  enable_lifecycle_rules = false
}

module "iam" {
  source      = "../../modules/iam"
  project     = var.project
  environment = var.environment
}
