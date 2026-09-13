# ---------------------------------------------------------------------------
# Fully Terraform-automated as of 2026-09-13 - no manual Portal/console step
# left. Investigated in this order:
#
# AWS side: `hashicorp/aws` has no `aws_interconnect*` resource (confirmed).
# `hashicorp/awscc` - generated directly from the same Cloud Control API
# schema CloudFormation uses - already ships `awscc_interconnect_connection`
# (AWS Interconnect went GA in April 2026, CloudFormation got day-1 support,
# awscc inherited it).
#
# Azure side: `azurerm` has no dedicated "Multicloud Interconnect" resource,
# and the official guide (learn.microsoft.com/.../create-interconnect) only
# documents Portal clicks. BUT: `az network express-route
# list-service-providers` already lists "AWS" as a registered classic
# ExpressRoute Service Provider, with peeringLocations
# (australiaeast/germanywc/useast/uswest) matching the 4 Multicloud
# Interconnect preview regions exactly - too specific to be a coincidence.
# The "Multicloud Interconnect" Portal wizard is almost certainly a friendly
# wrapper around this same classic mechanism. That means the circuit is just
# an ordinary `azurerm_express_route_circuit` (long-supported, no gap) with
# `service_provider_name = "AWS"` - and its `service_key` output is the
# activation key AWS redeems below.
#
# Caveat, in the interest of not overclaiming: this is strong circumstantial
# evidence (exact region-list match), not an executed end-to-end test - this
# session was instructed not to touch real cloud accounts. Verify with a real
# apply before trusting it blindly; if the classic-provider circuit turns out
# NOT to carry the CSP-account verification the Multicloud Interconnect FAQ
# describes, fall back to creating the circuit by hand in the Portal instead
# (its resource ID would replace `azurerm_express_route_circuit.poc.id`
# below) - see CLAUDE.md for that fallback path kept on record.
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

# Redeems the Azure circuit's service_key (see azurerm_express_route_circuit
# below) - the actual cross-cloud handshake, via the awscc (Cloud Control)
# provider since hashicorp/aws doesn't have this resource yet.
resource "awscc_interconnect_connection" "poc" {
  attach_point = {
    direct_connect_gateway = aws_dx_gateway.poc.id
  }
  bandwidth      = "500Mbps" # free tier
  activation_key = azurerm_express_route_circuit.poc.service_key
}

# --- Azure side: ExpressRoute Circuit + Gateway + Connection --------------
# `service_provider_name = "AWS"` / `peering_location = "useast"` - see the
# top-of-file comment for why this classic-provider circuit is believed to
# be the same object the Multicloud Interconnect Portal wizard creates.
# `useast` (not `us-east-1`/`eastus`) is the peering-location spelling Azure
# uses internally for this provider - confirmed via
# `az network express-route list-service-providers`.

resource "azurerm_express_route_circuit" "poc" {
  name                  = "erc-aws-azure-interconnect-poc"
  resource_group_name   = var.azure_resource_group_name
  location              = var.azure_location
  service_provider_name = "AWS"
  peering_location      = "useast"
  bandwidth_in_mbps     = 1000 # only offer listed for this provider - see caveat above on the 500Mbps free tier being AWS-side only

  sku {
    tier   = "Standard"
    family = "MeteredData"
  }

  tags = local.tags
}

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

resource "azurerm_virtual_network_gateway_connection" "poc" {
  name                       = "conn-aws-azure-interconnect-poc"
  location                   = var.azure_location
  resource_group_name        = var.azure_resource_group_name
  type                       = "ExpressRoute"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.poc.id
  express_route_circuit_id   = azurerm_express_route_circuit.poc.id

  tags = local.tags
}
