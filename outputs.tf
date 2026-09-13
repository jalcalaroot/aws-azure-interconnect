output "aws_vpc_id" {
  value = module.aws_vpc.vpc_id
}

output "aws_dx_gateway_id" {
  value = aws_dx_gateway.poc.id
}

output "aws_interconnect_connection_state" {
  description = "State of the awscc_interconnect_connection resource (requested/pending/available/down/...) - poll this instead of the AWS console to confirm the handshake completed."
  value       = awscc_interconnect_connection.poc.state
}

output "aws_instance_private_ip" {
  value = aws_instance.poc.private_ip
}

output "azure_vnet_id" {
  value = module.azure_vnet.vnet_id
}

output "azure_expressroute_gateway_id" {
  value = azurerm_virtual_network_gateway.poc.id
}

output "azure_vm_private_ip" {
  value = azurerm_network_interface.poc_vm.private_ip_address
}
