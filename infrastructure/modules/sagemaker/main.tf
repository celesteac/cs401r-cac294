# ── modules/sagemaker ────────────────────────────────────────────────────────
# The ML development environment: a Studio Domain inside the VPC, and one
# user profile that runs as the MLEngineer role.
#
# A brand-new AWS account has no service-linked role for Studio and the Domain
# fails to create with a service-linked role error. Fix it once in the console
# (IAM -> Roles -> Create Role -> AWS Service -> SageMaker -> SageMaker Studio)
# and re-apply.

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_sagemaker_domain" "this" {
  domain_name = "${local.name_prefix}-domain"
  auth_mode   = "IAM"
  vpc_id      = var.vpc_id
  subnet_ids  = var.subnet_ids

  # Studio reaches the internet through the public subnet's Internet Gateway.
  app_network_access_type = "PublicInternetOnly"

  default_user_settings {
    execution_role  = var.execution_role_arn
    security_groups = var.security_group_ids

    sharing_settings {
      notebook_output_option = "Disabled"
    }

    kernel_gateway_app_settings {
      default_resource_spec {
        instance_type = var.instance_type
      }
    }
  }

  # Studio creates an EFS filesystem for home directories that Terraform never
  # sees. Left on the default (Retain) it survives DeleteDomain, its mount
  # target pins the subnet, and terraform destroy hangs for ten minutes before
  # failing on the subnet and security group.
  retention_policy {
    home_efs_file_system = "Delete"
  }

  tags = { Name = "${local.name_prefix}-domain" }
}

resource "aws_sagemaker_user_profile" "ml_engineer" {
  domain_id         = aws_sagemaker_domain.this.id
  user_profile_name = "MLEngineer"

  user_settings {
    execution_role = var.execution_role_arn
  }

  tags = { Name = "${local.name_prefix}-MLEngineer" }
}
