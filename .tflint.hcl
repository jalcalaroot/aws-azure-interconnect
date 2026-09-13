plugin "aws" {
  enabled = true
  version = "0.35.0" # mismo valor que aws-vpc/.tflint.hcl - mantener en sync
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "azurerm" {
  enabled = true
  version = "0.32.0" # mismo valor que azure-virtual-network/.tflint.hcl - mantener en sync
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
