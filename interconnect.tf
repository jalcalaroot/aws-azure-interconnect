# ---------------------------------------------------------------------------
# Investigated on 2026-09-13 how much of this can actually be automated
# (not just "is there a Terraform resource"):
#
# AWS side: fully automatable, just not through `hashicorp/aws` (confirmed
# no `aws_interconnect*` resource there). `hashicorp/awscc` - generated
# directly from the same Cloud Control API schema CloudFormation uses -
# already ships `awscc_interconnect_connection` (AWS Interconnect went GA
# in April 2026, CloudFormation got day-1 support, awscc inherited it).
# That's what redeems the activation key below.
#
# Azure side: genuinely has NO automation surface yet, confirmed by actually
# trying, not just searching docs - no `az` parameters for it on
# `az network express-route create`, the only 2 CLI extensions with
# "interconnect"/"multicloud" in the name are unrelated Azure products
# (HPC "Interconnect Group" node placement, and Arc's "Public Cloud
# Connector"), no ARM/Bicep example found, no REST API spec located. The
# Azure Multicloud Interconnect circuit itself has to be created by hand,
# once, in the Portal (see README's manual step) - that's also where the
# activation key gets generated. Everything downstream of that one circuit
# ID is Terraform: connecting it to the VNet gateway (`
# azurerm_virtual_network_gateway_connection` below) is an ordinary,
# long-supported resource.
# ---------------------------------------------------------------------------

# --- AWS side: Direct Connect Gateway + VPN Gateway + Interconnect ---------
# A DX Gateway is the attach point AWS Interconnect uses on this side. It's
# a free, logical construct (no hourly cost by itself - see README pricing
# table). Associated to a VPN Gateway rather than a Transit Gateway since
# this PoC is a single VPC - no need to pay for a TGW just for this test.

resource "aws_dx_gateway" "poc" {
  name            = "dxgw-aws-azure-interconnect-poc"
  amazon_side_asn = 64512
}

resource "aws_vpn_gateway" "poc" {
  vpc_id = module.aws_vpc.vpc_id

  tags = merge(local.tags, { Name = "vgw-aws-azure-interconnect-poc" })
}

resource "aws_dx_gateway_association" "poc" {
  dx_gateway_id         = aws_dx_gateway.poc.id
  associated_gateway_id = aws_vpn_gateway.poc.id
  allowed_prefixes      = [local.aws_vpc_cidr]
}

# Redeems the activation key Azure generated during its one manual Portal
# step (see variables.tf) - this is the actual cross-cloud handshake,
# entirely Terraform-managed via the awscc (Cloud Control) provider.
resource "awscc_interconnect_connection" "poc" {
  attach_point = {
    direct_connect_gateway = aws_dx_gateway.poc.id
  }
  bandwidth      = "500Mbps" # free tier
  activation_key = var.aws_interconnect_activation_key
}

# --- Azure side: ExpressRoute Virtual Network Gateway + Connection --------
# Azure Multicloud Interconnect's own FAQ: "Do I need an ExpressRoute
# gateway? Yes." - traffic entering the VNet over the interconnect arrives
# through this gateway. `type = "ExpressRoute"` gateways don't take a public
# IP (the provider explicitly rejects one), unlike a Vpn-type gateway.
#
# This is the single most expensive and slowest-to-provision resource in
# this whole PoC (create time 30-60 min per Terraform's own provider notes,
# plus an hourly SKU cost that keeps running until it's destroyed) - see
# README for the cost callout and teardown reminder.

resource "azurerm_virtual_network_gateway" "poc" {
  name                = "ergw-aws-azure-interconnect-poc"
  location            = var.azure_location
  resource_group_name = var.azure_resource_group_name
  type                = "ExpressRoute"
  sku                 = "Standard" # cheapest ExpressRoute-capable SKU; $0.19/hour confirmed via the Azure Retail Prices API

  ip_configuration {
    name      = "default"
    subnet_id = azurerm_subnet.gateway.id
  }

  tags = local.tags
}

# Links the gateway above to the circuit created by hand in the Portal
# (var.azure_multicloud_interconnect_circuit_id) - this half of "connect the
# circuit to a VNet" is ordinary, long-supported Terraform, no gap here.
resource "azurerm_virtual_network_gateway_connection" "poc" {
  name                       = "conn-aws-azure-interconnect-poc"
  location                   = var.azure_location
  resource_group_name        = var.azure_resource_group_name
  type                       = "ExpressRoute"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.poc.id
  express_route_circuit_id   = var.azure_multicloud_interconnect_circuit_id

  tags = local.tags
}
