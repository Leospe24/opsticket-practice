terraform {
  required_version = ">= 1.16.0"

  # S3 backend terraform state
  backend "s3" {
    bucket       = "opsticket-tf-state-patrick-lab"
    key          = "opsticket/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}