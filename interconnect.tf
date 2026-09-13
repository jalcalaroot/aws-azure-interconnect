# ---------------------------------------------------------------------------
# Neither "AWS Interconnect" (multicloud, preview) nor "Azure Multicloud
# Interconnect" have a Terraform resource yet - confirmed live on 2026-09-13
# against hashicorp/aws v6.64.0 and hashicorp/azurerm v5.5.0 via the
# Terraform MCP registry search (no `interconnect`/`multicloud_interconnect`
# resource on either provider). Those two resources - and the activation-key
# exchange between them - have to be created by hand (console or CLI). See
# README.md "Manual activation steps" for the exact commands.
#
# What IS ordinary Terraform-managed infrastructure is each cloud's local
# "attach point" that the manual Interconnect resource plugs into once it
# exists. That's what's declared below.
# ---------------------------------------------------------------------------

# --- AWS side: Direct Connect Gateway + VPN Gateway ------------------------
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

# --- Azure side: ExpressRoute Virtual Network Gateway -----------------------
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
  sku                 = "Standard" # cheapest ExpressRoute-capable SKU; confirm exact hourly rate before applying

  ip_configuration {
    name      = "default"
    subnet_id = azurerm_subnet.gateway.id
  }

  tags = local.tags
}
