locals {
  tags = {
    Project     = "jalcalaroot"
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
    resource    = "aws-azure-interconnect"
  }

  # CIDRs deliberately non-overlapping - unlike the other jalcalaroot repos,
  # these two networks get directly connected over the Interconnect, so an
  # overlap here would actually break routing instead of just being unused.
  aws_vpc_cidr    = "10.100.0.0/16"
  azure_vnet_cidr = "10.200.0.0/16"

  # Passed explicitly to the azure_vnet module and reused below for the
  # GatewaySubnet - the module only outputs vnet_id, not a name, and
  # azurerm_subnet needs virtual_network_name (still true as of azurerm 5.5.0).
  azure_vnet_name = "vnet-aws-azure-interconnect-poc"
}

resource "azurerm_resource_group" "this" {
  name     = var.azure_resource_group_name
  location = var.azure_location
  tags     = local.tags
}

module "aws_vpc" {
  #checkov:skip=CKV_TF_1:Workspace convention - modules are versioned via git tags (v0.1.0, ...), not pinned commit hashes; see aws-vpc's own CLAUDE.md
  source = "git::https://github.com/jalcalaroot/aws-vpc.git?ref=v0.6.3"

  name     = "jalcalaroot-interconnect-poc"
  vpc_cidr = local.aws_vpc_cidr
  az_count = 1 # 1 AZ on purpose: the regional NAT Gateway bills per AZ served, and this PoC only needs to prove connectivity, not HA
}

module "azure_vnet" {
  #checkov:skip=CKV_TF_1:Same workspace convention as aws-vpc above - git tags, not commit hashes
  source = "git::https://github.com/jalcalaroot/azure-virtual-network.git?ref=v0.4.0"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.azure_location
  vnet_name           = local.azure_vnet_name
  vnet_address_space  = [local.azure_vnet_cidr]
  tags                = local.tags

  # The module's own subnet CIDR defaults (public/app/data/aks/appgw/
  # privatelink) all fall inside 10.0.0.0/16 - the module's *own* default
  # vnet_address_space. Since this VNet uses 10.200.0.0/16 instead, every
  # subnet needs an explicit CIDR inside that range or Azure rejects it
  # with NetcfgSubnetRangeOutsideVnet (found on the first real apply -
  # nothing before this caught it, `terraform plan` doesn't validate
  # subnet-vs-VNet CIDR containment). Same relative layout as the module's
  # own defaults, just re-based onto 10.200.0.0/16.
  public_subnet_cidr      = "10.200.0.0/22"
  app_subnet_cidr         = "10.200.8.0/22"
  data_subnet_cidr        = "10.200.20.0/22"
  appgw_subnet_cidr       = "10.200.40.0/24"
  aks_subnet_cidr         = "10.200.60.0/24"
  privatelink_subnet_cidr = "10.200.30.0/24"
}

# ExpressRoute gateways require a subnet literally named "GatewaySubnet" -
# this is a hard Azure platform requirement, not a naming convention. It's
# not something the reusable azure-virtual-network module provisions (it's
# specific to ExpressRoute/VPN, not a general workload tier), so it's added
# here at the consumer level instead.
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = local.azure_vnet_name
  address_prefixes     = ["10.200.255.0/27"]

  depends_on = [module.azure_vnet]
}
