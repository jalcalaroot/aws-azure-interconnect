terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0" # Cloud Control API provider - generated from the same schema as CloudFormation, has awscc_interconnect_connection before hashicorp/aws does
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

provider "azurerm" {
  subscription_id = var.azure_subscription_id
  features {}
}

provider "awscc" {
  region = var.aws_region
}
