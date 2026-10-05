# ---------------------------------------------------------------------------
# AWS routing for the Azure CIDR. Security groups alone are not enough:
#
# 1. The `compute` route table (from aws-vpc) only has 0.0.0.0/0 -> NAT.
#    Without a route for 10.200.0.0/16 via the VGW, Azure-bound traffic
#    would leave through the NAT instead of the interconnect.
# 2. The `private` NACL only allows intra-VPC traffic (10.100.0.0/16) and
#    has no ephemeral-port egress. NACLs are stateless and evaluated before
#    security groups, so traffic to/from 10.200.0.0/16 is dropped, and
#    replies to connections started from Azure (e.g. SYN-ACK from :80)
#    cannot leave.
#
# Azure needs nothing extra: its app route table propagates BGP routes, and
# the `VirtualNetwork` service tag in the subnet NSG includes networks
# connected through ExpressRoute.
# ---------------------------------------------------------------------------

data "aws_route_table" "compute" {
  subnet_id = module.aws_vpc.compute_subnet_ids[0]

  # compute_subnet_ids only depends on the subnet, not on its route-table
  # association - without this the lookup ran before the association
  # existed and failed with "no matching Route Table found" (apply of
  # 2026-10-05).
  depends_on = [module.aws_vpc]
}

resource "aws_route" "compute_to_azure" {
  route_table_id         = data.aws_route_table.compute.id
  destination_cidr_block = local.azure_vnet_cidr
  gateway_id             = aws_vpn_gateway.poc.id
}

# --- NACL: allow the Azure CIDR without touching the module's own rules ----

resource "aws_network_acl_rule" "private_in_icmp_from_azure" {
  #checkov:skip=CKV_AWS_352:false positive - ICMP has no ports; Checkov treats unset from_port/to_port as "all ports" (same skip as aws-vpc/nacl.tf)
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 200
  egress         = false
  protocol       = "icmp"
  icmp_type      = -1
  icmp_code      = -1
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
}

resource "aws_network_acl_rule" "private_out_icmp_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 200
  egress         = true
  protocol       = "icmp"
  icmp_type      = -1
  icmp_code      = -1
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
}

resource "aws_network_acl_rule" "private_in_ssh_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 195 # inbound rule numbers are their own sequence, separate from egress - keep below 200 (icmp) to avoid colliding with it
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "private_in_http_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 201
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "private_in_https_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 202
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "private_in_8080_from_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 203
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 8080
  to_port        = 8080
}

resource "aws_network_acl_rule" "private_out_ssh_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 205 # separate sequence from inbound - just needs to not collide with the other egress rule_numbers on this NACL (200, 211-213, 220)
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "private_out_http_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 211
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "private_out_https_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 212
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "private_out_8080_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 213
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 8080
  to_port        = 8080
}

# Missing in the module: without ephemeral-port egress the NACL drops replies
# (SYN-ACK, etc.) to connections initiated from Azure.
resource "aws_network_acl_rule" "private_out_ephemeral_to_azure" {
  network_acl_id = module.aws_vpc.private_network_acl_id
  rule_number    = 220
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.azure_vnet_cidr
  from_port      = 1024
  to_port        = 65535
}
