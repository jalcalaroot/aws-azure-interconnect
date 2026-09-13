output "aws_vpc_id" {
  value = module.aws_vpc.vpc_id
}

output "aws_dx_gateway_id" {
  description = "The DX Gateway to select as the attach point when creating the AWS Interconnect (console, or the AWS CLI command for this preview - check `aws help` for the exact current subcommand, not guessed here)."
  value       = aws_dx_gateway.poc.id
}

output "aws_instance_private_ip" {
  value = aws_instance.poc.private_ip
}

output "azure_vnet_id" {
  value = module.azure_vnet.vnet_id
}

output "azure_expressroute_gateway_id" {
  description = "The ExpressRoute gateway to select as the attach point when creating the Azure Multicloud Interconnect resource (Portal, or `az` - check `az networking --help` for the exact current command, not guessed here)."
  value       = azurerm_virtual_network_gateway.poc.id
}

output "azure_vm_private_ip" {
  value = azurerm_network_interface.poc_vm.private_ip_address
}
