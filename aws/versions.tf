terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Default provider: follows the customer's chosen region (S3 bucket, IAM).
provider "aws" {
  region = var.aws_region
}

# Pinned provider: the Data Exports API only exists in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
