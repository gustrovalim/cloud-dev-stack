terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket is passed at init time (-backend-config="bucket=...") so it is not hardcoded here.
  backend "s3" {
    key          = "infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # native S3 locking, no DynamoDB
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
