variable "aws_region" {
  description = "AWS region for this PoC. Must be one of the 4 AWS Interconnect preview regions: us-east-1, us-west-1, ap-southeast-2, eu-central-1."
  type        = string
  default     = "us-east-1"
}

variable "azure_location" {
  description = "Azure region paired with aws_region for Multicloud Interconnect. us-east-1 pairs with eastus (the only valid pairing among the 4 preview regions)."
  type        = string
  default     = "eastus"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
}

variable "azure_resource_group_name" {
  description = "Resource group for the Azure side of this PoC."
  type        = string
  default     = "rg-aws-azure-interconnect-poc"
}

variable "environment" {
  type    = string
  default = "poc"
}

variable "owner" {
  type    = string
  default = "johan"
}

variable "azure_vm_ssh_public_key" {
  description = "SSH public key for the Azure PoC VM. Required by azurerm_linux_virtual_machine even though real access is via `az vm run-command` (Run Command), not SSH - the NSG never opens port 22."
  type        = string
}
