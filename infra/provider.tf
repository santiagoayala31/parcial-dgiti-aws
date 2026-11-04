###############################################################################
# provider.tf - Versiones, backend remoto y proveedor AWS
###############################################################################
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Estado remoto en S3 con bloqueo nativo (use_lockfile, Terraform >= 1.10).
  # El bucket se crea con scripts/bootstrap-backend.sh y se pasa en el init:
  #   terraform init -backend-config="bucket=dgiti-tfstate-<ACCOUNT_ID>"
  # Así la consola (CloudShell) y el pipeline de GitHub Actions comparten el estado.
  backend "s3" {
    key          = "dgiti/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "Terraform"
      Course      = "DGITI-UPB"
    }
  }
}
