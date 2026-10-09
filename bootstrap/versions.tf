terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state on purpose: bootstrap is applied once by hand and never destroyed.
  # The state file holds no secrets, but keep it somewhere safe (it is gitignored).
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
